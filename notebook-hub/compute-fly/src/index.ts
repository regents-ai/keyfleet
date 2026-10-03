/**
 * marimohub compute library that runs each notebook sandbox as one private Fly
 * Machine in the fleet's runner app. Adapted from marimohub's compute-fargate:
 * every file and command call goes to a small helper inside the machine over
 * Fly's private network, and the hub forwards notebook traffic itself
 * (MARIMOHUB_SANDBOX_EXPOSURE=proxy).
 */
import {
	buildFindFilesCommand,
	buildGitCloneCommand,
	classifyListFilesFailure,
	launchWithProcess,
	mapWithConcurrency,
	parseFindFilesOutput,
	readBoundedFile,
	readBoundedStream,
	validateOutputBudget,
	WRITE_CONCURRENCY,
} from '@marimo-hub/compute-commons';
import { MARIMO_PORT } from '@marimo-hub/core/constants';
import type { SandboxId } from '@marimo-hub/core/ids';
import type { ComputeAdapterModule } from '@marimo-hub/core/ports/external-adapter';
import type {
	ActiveSandbox,
	BoundedReadOptions,
	ComputeResources,
	CreateSandboxOptions,
	ExecOptions,
	ExecResult,
	ExecStreamOptions,
	ExposePortOptions,
	ExposePortResult,
	GitCheckoutOptions,
	LaunchProcessOptions,
	ListFilesOptions,
	ListFilesResult,
	MountBucketOptions,
	ReadFileResult,
	SandboxFileWrite,
	SandboxInstance,
	SandboxLaunchResult,
	SandboxProcess,
	SandboxProvider,
	SetEnvVarsOptions,
	StartProcessOptions,
	WaitForPortOptions,
} from '@marimo-hub/core/ports/sandbox';
import { execResult, listFilesFailure, readFileFailure } from '@marimo-hub/core/ports/sandbox';
import { deriveHelperToken, parseFlyComputeConfig } from './config';
import type { FlyComputeConfig, FlyComputeContext } from './config';
import { createFlyMachinesClient, FlyApiError } from './machines';
import type { FlyGuest, FlyMachine, FlyMachinesClient } from './machines';

export { deriveHelperToken, parseFlyComputeConfig } from './config';
export type { FlyComputeConfig, FlyComputeContext } from './config';
export { createFlyMachinesClient, FlyApiError } from './machines';
export type * from './machines';

export const HELPER_PROTOCOL_VERSION = 1;
export const HELPER_PORT = 2717;
export const OWNER_KEY = 'marimohub_owner';
export const SANDBOX_ID_KEY = 'marimohub_sandbox_id';
export const READY_TIMEOUT_MS = 120_000;
export const HELPER_HEALTH_TIMEOUT_MS = 2_000;
export const HELPER_TRANSPORT_GRACE_MS = 1_000;
export const MAX_HELPER_BODY_BYTES = 40 * 1024 * 1024;
export const MAX_FILE_BYTES = 25 * 1024 * 1024;
export const MAX_WRITE_BATCH_BYTES = 8 * 1024 * 1024;

const SANDBOX_ID_PATTERN = /^sb-[0-9a-z]{16}$/;
/** Machine states in which the machine exists and is (or is becoming) usable. */
const LIVE_STATES = new Set(['created', 'starting', 'started']);
/** A machine in one of these states will never serve its sandbox again. */
const DEAD_STATES = new Set([
	'stopping',
	'stopped',
	'suspended',
	'destroying',
	'destroyed',
	'failed',
]);
const SHARED_CPUS = [1, 2, 4, 8];
const PERFORMANCE_CPUS = [1, 2, 4, 8, 16];

const POLL_BASE_INTERVAL_MS = 100;
const POLL_MAX_INTERVAL_MS = 2_000;

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => {
		setTimeout(resolve, ms);
	});
}

function pollDelay(attempt: number): number {
	const ceiling = Math.min(POLL_MAX_INTERVAL_MS, POLL_BASE_INTERVAL_MS * 2 ** attempt);
	return Math.max(25, Math.floor(ceiling * (0.75 + Math.random() * 0.5)));
}

function errorMessage(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

class HelperHttpError extends Error {
	constructor(
		readonly status: number,
		message: string,
	) {
		super(message);
		this.name = 'HelperHttpError';
	}
}

class HelperProtocolError extends Error {
	constructor(message: string) {
		super(message);
		this.name = 'HelperProtocolError';
	}
}

class MachineGoneError extends Error {
	constructor(machineId: string, state: string) {
		super(`Fly machine ${machineId} is ${state} before its helper answered`);
		this.name = 'MachineGoneError';
	}
}

function asJsonRecord(value: unknown): Record<string, unknown> {
	if (typeof value !== 'object' || value === null || Array.isArray(value)) {
		throw new Error('Runner helper returned an invalid JSON object');
	}
	return value as Record<string, unknown>;
}

function stringField(body: Record<string, unknown>, key: string): string {
	if (typeof body[key] !== 'string') throw new Error(`Runner helper response is missing ${key}`);
	return body[key];
}

function textValue(value: unknown): string {
	return typeof value === 'string' ? value : '';
}

function helperJsonBody(value: unknown): string {
	const body = JSON.stringify(value);
	if (body === undefined) throw new Error('Runner helper request body is not JSON serializable');
	if (Buffer.byteLength(body, 'utf8') > MAX_HELPER_BODY_BYTES) {
		throw new Error('Runner helper request exceeds the body limit');
	}
	return body;
}

/** Fly guest for a compute profile: the smallest CPU count that fits, memory in 256 MB steps. */
export function flyGuest(base: FlyGuest, resources: ComputeResources | undefined): FlyGuest {
	if (resources?.gpu !== undefined) {
		throw new Error('GPU compute profiles are not supported by the Fly runner adapter');
	}
	const cpu = resources?.cpu ?? 0;
	const memoryBytes = resources?.memoryBytes ?? 0;
	if (!Number.isFinite(cpu + memoryBytes) || cpu < 0 || memoryBytes < 0) {
		throw new Error('Compute profile CPU and memory must be finite, non-negative values');
	}
	const allowed = base.cpu_kind === 'shared' ? SHARED_CPUS : PERFORMANCE_CPUS;
	const cpus = cpu === 0 ? base.cpus : allowed.find((count) => count >= cpu);
	if (cpus === undefined) {
		throw new Error(
			`Compute profile asks for ${cpu} CPUs; ${base.cpu_kind} Fly machines have at most ${allowed.at(-1)}`,
		);
	}
	const memoryMb =
		memoryBytes === 0 ? base.memory_mb : Math.ceil(memoryBytes / 1024 ** 2 / 256) * 256;
	return { cpu_kind: base.cpu_kind, cpus, memory_mb: memoryMb };
}

function machineHost(config: FlyComputeConfig, machineId: string): string {
	return `${machineId}.vm.${config.app}.internal`;
}

function ownedBy(machine: FlyMachine, config: FlyComputeConfig): boolean {
	return machine.config?.metadata?.[OWNER_KEY] === config.owner;
}

async function listOwnedMachines(
	client: FlyMachinesClient,
	config: FlyComputeConfig,
): Promise<FlyMachine[]> {
	const machines = await client.list({ [OWNER_KEY]: config.owner });
	return machines.filter((machine) => ownedBy(machine, config));
}

async function findSandboxMachines(
	client: FlyMachinesClient,
	config: FlyComputeConfig,
	id: SandboxId,
): Promise<FlyMachine[]> {
	return (await listOwnedMachines(client, config)).filter(
		(machine) =>
			machine.config?.metadata?.[SANDBOX_ID_KEY] === String(id) && LIVE_STATES.has(machine.state),
	);
}

interface MachineHandle {
	machineId: string;
	host: string;
}

type MachineCache = Map<string, MachineHandle>;

interface FlySandboxOptions {
	reuse: boolean;
	image: string;
	guest: FlyGuest;
}

class FlySandboxInstance implements SandboxInstance {
	readonly supportsBucketMount = false;
	private readonly env: Record<string, string> = {};
	private ensurePromise?: Promise<void>;
	private handle?: MachineHandle;
	private timings: { create?: number; boot?: number } = {};

	constructor(
		private readonly id: SandboxId,
		private readonly config: FlyComputeConfig,
		private readonly client: FlyMachinesClient,
		private readonly options: FlySandboxOptions,
		private readonly cache: MachineCache,
	) {}

	private async ensure(): Promise<void> {
		if (this.handle) return;
		this.ensurePromise ??= this.resolveMachine().finally(() => {
			this.ensurePromise = undefined;
		});
		await this.ensurePromise;
	}

	private async resolveMachine(): Promise<void> {
		const started = Date.now();
		if (this.options.reuse) {
			const cached = this.cache.get(String(this.id));
			if (cached) {
				try {
					await this.checkHelper(cached.host, HELPER_HEALTH_TIMEOUT_MS);
					this.handle = cached;
					this.timings = { create: Date.now() - started, boot: 0 };
					return;
				} catch (error) {
					if (error instanceof HelperProtocolError) throw error;
					this.cache.delete(String(this.id));
				}
			}
		}
		let machine: FlyMachine | undefined;
		if (this.options.reuse) {
			const matches = await findSandboxMachines(this.client, this.config, this.id);
			if (matches.length > 1) {
				throw new Error(
					`Multiple live Fly machines found for sandbox ${this.id}; refusing to choose one`,
				);
			}
			machine = matches[0];
		}
		machine ??= await this.client.create({
			name: String(this.id),
			region: this.config.region,
			config: {
				image: this.options.image,
				// The helper token is the only secret a runner machine ever receives.
				env: {
					MARIMOHUB_AGENT_TOKEN: deriveHelperToken(this.config.helperSecret, String(this.id)),
					MARIMOHUB_AGENT_PORT: String(HELPER_PORT),
					MARIMOHUB_RUNNER_MAX_LIFETIME_SECONDS: String(this.config.maxLifetimeSeconds),
				},
				guest: this.options.guest,
				auto_destroy: true,
				restart: { policy: 'no' },
				metadata: { [OWNER_KEY]: this.config.owner, [SANDBOX_ID_KEY]: String(this.id) },
			},
		});
		const createFinished = Date.now();
		const host = machineHost(this.config, machine.id);
		await this.waitForMachine(machine.id, host);
		this.handle = { machineId: machine.id, host };
		this.cache.set(String(this.id), this.handle);
		this.timings = { create: createFinished - started, boot: Date.now() - createFinished };
	}

	private async waitForMachine(machineId: string, host: string): Promise<void> {
		const deadline = Date.now() + READY_TIMEOUT_MS;
		let lastState = 'unknown';
		let lastFailure: string | undefined;
		let attempt = 0;
		while (Date.now() < deadline) {
			try {
				const machine = await this.client.get(machineId);
				lastState = machine.state;
				if (DEAD_STATES.has(machine.state)) throw new MachineGoneError(machineId, machine.state);
				if (machine.state === 'started') {
					const remaining = Math.max(1, deadline - Date.now());
					await this.checkHelper(host, Math.min(HELPER_HEALTH_TIMEOUT_MS, remaining));
					return;
				}
			} catch (error) {
				if (error instanceof HelperProtocolError || error instanceof MachineGoneError) throw error;
				if (error instanceof HelperHttpError && error.status >= 400 && error.status < 500)
					throw error;
				if (error instanceof FlyApiError && error.status === 404) {
					throw new MachineGoneError(machineId, 'gone');
				}
				lastFailure = errorMessage(error);
			}
			await sleep(Math.min(pollDelay(attempt++), Math.max(1, deadline - Date.now())));
		}
		throw new Error(
			`Timed out waiting for Fly machine ${machineId} and its helper after ${READY_TIMEOUT_MS}ms (state ${lastState}${lastFailure ? `; ${lastFailure}` : ''})`,
		);
	}

	private async checkHelper(host: string, timeoutMs: number): Promise<void> {
		const body = asJsonRecord(
			await this.requestAt(host, '/health', { method: 'GET' }, true, timeoutMs, 0),
		);
		if (body.protocolVersion !== HELPER_PROTOCOL_VERSION) {
			throw new HelperProtocolError(
				`Runner helper protocol ${String(body.protocolVersion)} is incompatible with adapter protocol ${HELPER_PROTOCOL_VERSION}`,
			);
		}
	}

	private async request<T>(
		path: string,
		init: RequestInit = {},
		parse = true,
		requestedTimeoutMs?: number,
		maxResponseBytes?: number,
	): Promise<T> {
		await this.ensure();
		return this.requestAt(
			this.handle!.host,
			path,
			init,
			parse,
			requestedTimeoutMs,
			HELPER_TRANSPORT_GRACE_MS,
			maxResponseBytes,
		) as Promise<T>;
	}

	private async requestAt<T>(
		host: string,
		path: string,
		init: RequestInit = {},
		parse = true,
		requestedTimeoutMs?: number,
		transportGraceMs = HELPER_TRANSPORT_GRACE_MS,
		maxResponseBytes?: number,
	): Promise<T> {
		const headers = new Headers(init.headers);
		headers.set(
			'authorization',
			`Bearer ${deriveHelperToken(this.config.helperSecret, String(this.id))}`,
		);
		if (init.body !== undefined && !headers.has('content-type'))
			headers.set('content-type', 'application/json');
		const transportTimeoutMs =
			requestedTimeoutMs === undefined
				? READY_TIMEOUT_MS
				: requestedTimeoutMs === 0 || requestedTimeoutMs === Infinity
					? 0
					: requestedTimeoutMs + transportGraceMs;
		const requestInit: RequestInit = { ...init, headers };
		if (transportTimeoutMs > 0 && Number.isFinite(transportTimeoutMs)) {
			requestInit.signal = AbortSignal.timeout(transportTimeoutMs);
		}
		const response = await fetch(`http://${host}:${HELPER_PORT}${path}`, requestInit);
		if (!response.ok)
			throw new HelperHttpError(response.status, `Runner helper returned HTTP ${response.status}`);
		if (!parse) return undefined as T;
		if (maxResponseBytes !== undefined) {
			if (!response.body) throw new Error('Missing runner helper response');
			return JSON.parse(
				await readBoundedStream(
					response.body,
					maxResponseBytes,
					requestInit.signal ?? new AbortController().signal,
				),
			) as T;
		}
		return (await response.json()) as T;
	}

	private commandEnv(extra?: Record<string, string | undefined>): Record<string, string> {
		const extras: Record<string, string> = {};
		for (const [key, value] of Object.entries(extra ?? {})) {
			if (value !== undefined) extras[key] = value;
		}
		return { ...this.env, ...extras };
	}

	async ready(): Promise<void> {
		await this.ensure();
	}

	async exec(cmd: string, options?: ExecOptions): Promise<ExecResult> {
		try {
			if (options?.maxOutputBytes !== undefined) validateOutputBudget(options.maxOutputBytes);
			const requestedTimeout = options?.timeout === Infinity ? 0 : options?.timeout;
			const body = asJsonRecord(
				await this.request(
					'/exec',
					{
						method: 'POST',
						body: helperJsonBody({
							command: cmd,
							cwd: '/workspace',
							env: this.commandEnv(),
							timeoutMs: requestedTimeout,
						}),
					},
					true,
					requestedTimeout,
					// A JSON-escaped control byte occupies six wire bytes.
					options?.maxOutputBytes === undefined ? undefined : options.maxOutputBytes * 6 + 4096,
				),
			);
			const stdout = textValue(body.stdout);
			const stderr = textValue(body.stderr);
			if (
				options?.maxOutputBytes !== undefined &&
				Buffer.byteLength(stdout) + Buffer.byteLength(stderr) > options.maxOutputBytes
			) {
				throw new Error('Sandbox output limit exceeded');
			}
			return execResult(body.success === true, stdout, stderr);
		} catch (error) {
			return execResult(false, '', errorMessage(error), 'BACKEND_ERROR');
		}
	}

	async execStream(cmd: string, options?: ExecStreamOptions): Promise<ReadableStream> {
		const result = await this.exec(cmd, options);
		const encoder = new TextEncoder();
		return new ReadableStream({
			start(controller) {
				controller.enqueue(encoder.encode(result.stdout));
				controller.close();
			},
		});
	}

	async readFileBounded(path: string, options: BoundedReadOptions): Promise<ReadFileResult> {
		return readBoundedFile(path, options, (command, limits) => this.exec(command, limits));
	}

	async readFile(path: string): Promise<ReadFileResult> {
		try {
			const body = asJsonRecord(
				await this.request(`/files/read?path=${encodeURIComponent(path)}`, { method: 'GET' }),
			);
			const encoded = body.contentBase64;
			if (typeof encoded !== 'string') return readFileFailure('READ_FAILED');
			const bytes = Buffer.from(encoded, 'base64');
			const text = bytes.toString('utf8');
			return Buffer.from(text, 'utf8').equals(bytes)
				? { success: true, content: text, encoding: 'utf-8' }
				: { success: true, content: encoded, encoding: 'base64' };
		} catch (error) {
			return readFileFailure(
				error instanceof HelperHttpError && error.status === 404 ? 'NOT_FOUND' : 'BACKEND_ERROR',
			);
		}
	}

	async writeFiles(files: readonly SandboxFileWrite[]): Promise<void> {
		if (files.length === 0) return;
		const batches: { path: string; content: Uint8Array }[][] = [];
		let batch: { path: string; content: Uint8Array }[] = [];
		let size = 0;
		for (const file of files) {
			const bytes =
				typeof file.content === 'string' ? new TextEncoder().encode(file.content) : file.content;
			if (bytes.byteLength > MAX_FILE_BYTES)
				throw new Error(`file ${file.path} exceeds the runner file limit`);
			if (batch.length > 0 && size + bytes.byteLength > MAX_WRITE_BATCH_BYTES) {
				batches.push(batch);
				batch = [];
				size = 0;
			}
			batch.push({ path: file.path, content: bytes });
			size += bytes.byteLength;
		}
		if (batch.length > 0) batches.push(batch);
		await mapWithConcurrency(batches, WRITE_CONCURRENCY, async (group) => {
			await this.request('/files/write', {
				method: 'POST',
				body: helperJsonBody({
					files: group.map((file) => ({
						path: file.path,
						contentBase64: Buffer.from(file.content).toString('base64'),
					})),
				}),
			});
		});
	}

	async listFiles(path: string, options?: ListFilesOptions): Promise<ListFilesResult> {
		try {
			const result = await this.exec(buildFindFilesCommand(path, options));
			if (!result.success) return listFilesFailure(classifyListFilesFailure(result));
			return { success: true, files: parseFindFilesOutput(result.stdout, path, options) };
		} catch {
			return listFilesFailure('BACKEND_ERROR');
		}
	}

	async gitCheckout(repo: string, options?: GitCheckoutOptions): Promise<void> {
		const result = await this.exec(buildGitCloneCommand(repo, options));
		if (!result.success) throw new Error(`git checkout failed: ${result.stderr}`);
	}

	async setEnvVars(vars: Record<string, string>, options?: SetEnvVarsOptions): Promise<void> {
		const defaults = options?.onlyIfUnset ? vars : {};
		const forced = options?.onlyIfUnset ? {} : vars;
		await this.request('/env', { method: 'POST', body: helperJsonBody({ forced, defaults }) });
		Object.assign(this.env, forced);
	}

	/** Kernels never get bucket keys: the hub copies files in instead (supportsBucketMount=false). */
	async mountBucket(_options: MountBucketOptions): Promise<void> {
		throw new Error('mountBucket is not supported by the Fly runner; the hub copies files in');
	}

	async unmountBucket(_mountPath: string): Promise<void> {}

	async startProcess(cmd: string, options?: StartProcessOptions): Promise<SandboxProcess> {
		const body = asJsonRecord(
			await this.request('/processes', {
				method: 'POST',
				body: helperJsonBody({
					command: cmd,
					processId: options?.processId,
					cwd: options?.cwd ?? '/workspace',
					env: this.commandEnv(options?.env),
					timeoutMs: options?.timeout === Infinity ? 0 : options?.timeout,
				}),
			}),
		);
		const processId = stringField(body, 'id');
		const path = `/processes/${encodeURIComponent(processId)}`;
		return {
			id: processId,
			command: cmd,
			kill: async (signal?: string) => {
				try {
					await this.request(
						`${path}?signal=${encodeURIComponent(signal ?? 'TERM')}`,
						{ method: 'DELETE' },
						false,
					);
				} catch (error) {
					if (!(error instanceof HelperHttpError && error.status === 404)) throw error;
				}
			},
			waitForPort: async (port: number, waitOptions?: WaitForPortOptions) => {
				const requestedTimeout = waitOptions?.timeout === Infinity ? 0 : waitOptions?.timeout;
				await this.request(
					`${path}/wait-port`,
					{
						method: 'POST',
						body: helperJsonBody({
							port,
							mode: waitOptions?.mode ?? 'tcp',
							path: waitOptions?.path,
							timeoutMs: requestedTimeout,
						}),
					},
					true,
					requestedTimeout,
				);
			},
			getLogs: async () => {
				const logs = asJsonRecord(await this.request(`${path}/logs`, { method: 'GET' }));
				return { stdout: textValue(logs.stdout), stderr: textValue(logs.stderr) };
			},
		};
	}

	async launchProcess(cmd: string, options: LaunchProcessOptions): Promise<SandboxLaunchResult> {
		return launchWithProcess({
			setup: options.setup,
			command: cmd,
			port: options.port,
			startupTimeout: options.startupTimeout,
			waitForPort: options.waitForPort,
			start: (command) =>
				this.startProcess(command, {
					cwd: options.cwd,
					env: options.env,
					processId: options.processId,
				}),
		});
	}

	/**
	 * The machine's private address. Only the kernel port is relayed onto Fly's
	 * IPv6 private network, so it is the only port this adapter exposes.
	 */
	async exposePort(port: number, _options: ExposePortOptions): Promise<ExposePortResult> {
		if (port !== MARIMO_PORT) {
			throw new Error(`The Fly runner exposes only the kernel port ${MARIMO_PORT}, not ${port}`);
		}
		await this.ensure();
		return { url: `http://${this.handle!.host}:${port}` };
	}

	async destroy(): Promise<void> {
		const cached = this.handle ?? this.cache.get(String(this.id));
		const machineIds = cached
			? [cached.machineId]
			: (await findSandboxMachines(this.client, this.config, this.id)).map((machine) => machine.id);
		try {
			for (const machineId of machineIds) {
				try {
					await this.client.destroy(machineId);
				} catch (error) {
					if (!(error instanceof FlyApiError && error.status === 404)) throw error;
				}
			}
		} finally {
			this.handle = undefined;
			this.cache.delete(String(this.id));
		}
	}

	drainTimings(): { create?: number; boot?: number } {
		const value = this.timings;
		this.timings = {};
		return value;
	}
}

export class FlyCompute implements SandboxProvider {
	readonly capabilities = { multiPort: false, computeProfiles: true } as const;
	private readonly cache: MachineCache = new Map();
	private readonly client: FlyMachinesClient;

	constructor(private readonly config: FlyComputeConfig) {
		this.client = createFlyMachinesClient({
			apiUrl: config.apiUrl,
			token: config.apiToken,
			app: config.app,
		});
	}

	create(id: SandboxId, options?: CreateSandboxOptions): SandboxInstance {
		return new FlySandboxInstance(
			id,
			this.config,
			this.client,
			{
				reuse: options?.reuse ?? true,
				// The hub picks the image from MARIMOHUB_COMPUTE_IMAGE; the first is its default.
				image: options?.image ?? this.config.images[0],
				guest: flyGuest(this.config.guest, options?.resources),
			},
			this.cache,
		);
	}

	async proxy(_request: Request): Promise<Response | null> {
		return null;
	}

	/** Started machines this hub owns, by the sandbox id stored on each session record. */
	async listActive(): Promise<ActiveSandbox[]> {
		const active: ActiveSandbox[] = [];
		const seen = new Set<string>();
		for (const machine of await listOwnedMachines(this.client, this.config)) {
			if (machine.state !== 'started') continue;
			const id = machine.config?.metadata?.[SANDBOX_ID_KEY];
			if (!id || !SANDBOX_ID_PATTERN.test(id)) continue;
			if (seen.has(id)) throw new Error(`Multiple live Fly machines found for sandbox ${id}`);
			seen.add(id);
			this.cache.set(id, { machineId: machine.id, host: machineHost(this.config, machine.id) });
			active.push({ id: id as SandboxId, createdAt: machine.created_at });
		}
		return active;
	}
}

const manifest: ComputeAdapterModule = {
	apiVersion: 1,
	kind: 'compute',
	create(context: FlyComputeContext) {
		return new FlyCompute(parseFlyComputeConfig(context));
	},
};

export default manifest;
