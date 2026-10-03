/**
 * Stand-ins for the Fly Machines API and the in-machine helper, reached through
 * a stubbed global fetch exactly as the adapter reaches the real ones.
 */
import { spawn } from 'node:child_process';
import {
	isContractNonDirectoryFindCommand,
	scriptContractLaunch,
} from '@marimo-hub/core/testing/compute-contract';
import { deriveHelperToken } from '../src/config';
import type { FlyMachine, FlyMachineCreate } from '../src/machines';
import { HELPER_PORT, HELPER_PROTOCOL_VERSION } from '../src/index';

export const API_URL = 'http://fly-api.test';
export const APP = 'kf-nbk-test';
export const API_TOKEN = 'fly-api-token-value-for-tests';
export const HELPER_SECRET = 'helper-master-secret-'.repeat(3);
export const OWNER = 'kf-nb-test';

/** Environment the hub would hand the adapter, with every secret a hub holds. */
export function hubEnv(overrides: Record<string, string | undefined> = {}) {
	return {
		MARIMOHUB_SANDBOX_EXPOSURE: 'proxy',
		MARIMOHUB_COMPUTE_FLY_API_URL: API_URL,
		FLY_API_TOKEN: API_TOKEN,
		MARIMOHUB_COMPUTE_FLY_APP: APP,
		MARIMOHUB_COMPUTE_FLY_REGION: 'iad',
		MARIMOHUB_COMPUTE_FLY_CPU_KIND: 'shared',
		MARIMOHUB_COMPUTE_FLY_CPUS: '1',
		MARIMOHUB_COMPUTE_FLY_MEMORY_MB: '1024',
		MARIMOHUB_COMPUTE_IMAGE: 'registry.fly.io/kf-nbk-test:runner,contract-image-override',
		MARIMOHUB_COMPUTE_FLY_HELPER_SECRET: HELPER_SECRET,
		MARIMOHUB_COMPUTE_FLY_OWNER: OWNER,
		MARIMOHUB_SESSION_SECRET: 'hub-session-secret-value',
		MARIMOHUB_STORAGE_S3_ACCESS_KEY_ID: 'tigris-access-key-value',
		MARIMOHUB_STORAGE_S3_SECRET_ACCESS_KEY: 'tigris-secret-key-value',
		MARIMOHUB_DATABASE_URL: 'postgres://hub:db-password-value@db/hub',
		...overrides,
	};
}

export const COMPUTE_CONTEXT = { sessionMaxLifetimeSeconds: 14_400 };

/** The adapter sends every request body as JSON text. */
function bodyText(body: RequestInit['body']): string {
	if (typeof body !== 'string') throw new Error('expected a JSON text request body');
	return body;
}

export interface RecordedRequest {
	method: string;
	url: URL;
	headers: Headers;
	body?: string;
}

interface StoredMachine extends FlyMachine {
	sandboxId: string;
	env: Record<string, string>;
	helper: StubHelper;
	/** States the machine moves through, one per GET of that machine. */
	upcomingStates: string[];
}

type Runner = (command: string, env: Record<string, string>) => Promise<HelperExecResult>;

export interface HelperExecResult {
	success: boolean;
	exitCode: number;
	stdout: string;
	stderr: string;
}

/** The helper inside one runner machine: an in-memory workspace, or real local commands. */
export class StubHelper {
	readonly files = new Map<string, Uint8Array>();
	readonly environment = new Map<string, string>();
	private readonly processes = new Map<string, { stdout: string; portOpen: boolean }>();
	private sequence = 0;

	constructor(
		private readonly token: string,
		private readonly runner?: Runner,
	) {}

	async handle(url: URL, init: RequestInit): Promise<Response> {
		const method = init.method ?? 'GET';
		if (new Headers(init.headers).get('authorization') !== `Bearer ${this.token}`) {
			return Response.json({ error: 'unauthorized' }, { status: 401 });
		}
		const body = init.body === undefined ? {} : (JSON.parse(bodyText(init.body)) as never);
		if (method === 'GET' && url.pathname === '/health') {
			return Response.json({ ok: true, protocolVersion: HELPER_PROTOCOL_VERSION });
		}
		if (method === 'POST' && url.pathname === '/files/write') {
			const files = (body as { files: { path: string; contentBase64: string }[] }).files;
			for (const file of files) {
				this.files.set(file.path, Uint8Array.from(Buffer.from(file.contentBase64, 'base64')));
			}
			return Response.json({ written: files.length });
		}
		if (method === 'GET' && url.pathname === '/files/read') {
			const content = this.files.get(url.searchParams.get('path') ?? '');
			if (!content) return Response.json({ error: 'file not found' }, { status: 404 });
			return Response.json({ contentBase64: Buffer.from(content).toString('base64') });
		}
		if (method === 'POST' && url.pathname === '/env') {
			const { forced, defaults } = body as {
				forced: Record<string, string>;
				defaults: Record<string, string>;
			};
			for (const [key, value] of Object.entries(defaults)) {
				if (!this.environment.has(key)) this.environment.set(key, value);
			}
			for (const [key, value] of Object.entries(forced)) this.environment.set(key, value);
			return Response.json({ ok: true });
		}
		if (method === 'POST' && url.pathname === '/exec') {
			const { command, env } = body as { command: string; env: Record<string, string> };
			const merged = { ...Object.fromEntries(this.environment), ...env };
			return Response.json(
				this.runner ? await this.runner(command, merged) : this.fakeExec(command, merged),
			);
		}
		if (method === 'POST' && url.pathname === '/processes') {
			const script = scriptContractLaunch((body as { command: string }).command);
			const id = `process-${++this.sequence}`;
			this.processes.set(id, {
				stdout: script?.transcript ?? '',
				portOpen: script?.portOpen ?? false,
			});
			return Response.json({ id }, { status: 201 });
		}
		const match = url.pathname.match(/^\/processes\/([^/]+)(?:\/(.*))?$/);
		if (match) {
			const id = decodeURIComponent(match[1]);
			const process = this.processes.get(id);
			if (!process) return Response.json({ error: 'process not found' }, { status: 404 });
			if (method === 'POST' && match[2] === 'wait-port') {
				return process.portOpen
					? Response.json({ ready: true })
					: Response.json({ error: 'timed out waiting for port' }, { status: 408 });
			}
			if (method === 'GET' && match[2] === 'logs') {
				return Response.json({ stdout: process.stdout, stderr: '' });
			}
			if (method === 'DELETE' && !match[2]) {
				this.processes.delete(id);
				return new Response(null, { status: 204 });
			}
		}
		return Response.json({ error: 'route not found' }, { status: 404 });
	}

	private fakeExec(command: string, env: Record<string, string>): HelperExecResult {
		if (isContractNonDirectoryFindCommand(command)) {
			return { success: false, exitCode: 20, stdout: '', stderr: 'MARIMOHUB_NOT_A_DIRECTORY\n' };
		}
		if (command.includes('find ')) {
			const recursive = !command.includes('-maxdepth 1');
			const output: string[] = [];
			for (const [path, content] of this.files) {
				if (!path.startsWith('/workspace/')) continue;
				const relative = path.slice('/workspace/'.length);
				if (!recursive && relative.includes('/')) continue;
				output.push(`f\t${content.byteLength}\t${path}\0`);
			}
			return { success: true, exitCode: 0, stdout: output.join(''), stderr: '' };
		}
		if (command.includes('mh-contract-fail') || command.trim() === 'false') {
			return { success: false, exitCode: 1, stdout: '', stderr: 'failed' };
		}
		const probe = command.match(/\$\{?([A-Za-z_][A-Za-z0-9_]*)/);
		return {
			success: true,
			exitCode: 0,
			stdout: probe ? (env[probe[1]] ?? '') : '',
			stderr: '',
		};
	}
}

/** Runs helper commands for real on this computer, for the bounded-read tests. */
export const localRunner: Runner = (command, env) =>
	new Promise((resolve) => {
		const child = spawn('sh', ['-c', command], { env: { PATH: process.env.PATH ?? '', ...env } });
		const stdout: Buffer[] = [];
		const stderr: Buffer[] = [];
		child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk));
		child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk));
		child.on('close', (code) =>
			resolve({
				success: code === 0,
				exitCode: code ?? -1,
				stdout: Buffer.concat(stdout).toString('utf8'),
				stderr: Buffer.concat(stderr).toString('utf8'),
			}),
		);
	});

/** The Fly Machines API for one runner app, plus every runner machine's helper. */
export class FlyWorld {
	readonly requests: RecordedRequest[] = [];
	readonly machines = new Map<string, StoredMachine>();
	/** Fly's documented metadata filter; switch off to prove the adapter filters too. */
	honourMetadataFilter = true;
	/** States a new machine reports: the first on create, then one more per GET. */
	bootStates: string[] = ['started'];
	runner?: Runner;
	private sequence = 0;

	fetch = async (input: string, init: RequestInit = {}): Promise<Response> => {
		const url = new URL(input);
		const method = init.method ?? 'GET';
		this.requests.push({
			method,
			url,
			headers: new Headers(init.headers),
			body: init.body === undefined ? undefined : bodyText(init.body),
		});
		if (url.origin === API_URL) return this.api(url, method, init);
		const helperHost = url.hostname.match(/^([0-9a-f]+)\.vm\.([a-z0-9-]+)\.internal$/);
		if (helperHost?.[2] === APP && url.port === String(HELPER_PORT)) {
			const machine = this.machines.get(helperHost[1]);
			if (machine?.state !== 'started') throw new TypeError('fetch failed');
			return machine.helper.handle(url, init);
		}
		throw new TypeError(`fetch failed: no route to ${url.host}`);
	};

	/** A machine some other hub (another owner) runs in the same app. */
	addForeignMachine(owner: string, sandboxId: string): string {
		return this.store(owner, sandboxId, {}, ['started']).id;
	}

	machineFor(sandboxId: string): StoredMachine | undefined {
		return [...this.machines.values()].find((machine) => machine.sandboxId === sandboxId);
	}

	apiCalls(method: string, path = ''): RecordedRequest[] {
		return this.requests.filter(
			(request) =>
				request.url.origin === API_URL &&
				request.method === method &&
				request.url.pathname === `/v1/apps/${APP}/machines${path}`,
		);
	}

	private store(
		owner: string,
		sandboxId: string,
		env: Record<string, string>,
		states: string[],
	): StoredMachine {
		const id = (++this.sequence).toString(16).padStart(14, '0');
		const machine: StoredMachine = {
			id,
			name: sandboxId,
			state: states[0],
			upcomingStates: states.slice(1),
			region: 'iad',
			created_at: new Date(Date.UTC(2026, 9, 2, 0, 0, this.sequence)).toISOString(),
			config: { metadata: { marimohub_owner: owner, marimohub_sandbox_id: sandboxId } },
			sandboxId,
			env,
			helper: new StubHelper(env.MARIMOHUB_AGENT_TOKEN ?? '', this.runner),
		};
		this.machines.set(id, machine);
		return machine;
	}

	private view(machine: StoredMachine): FlyMachine {
		return {
			id: machine.id,
			name: machine.name,
			state: machine.state,
			region: machine.region,
			created_at: machine.created_at,
			config: machine.config,
		};
	}

	private api(url: URL, method: string, init: RequestInit): Response {
		if (new Headers(init.headers).get('authorization') !== `Bearer ${API_TOKEN}`) {
			return Response.json({ error: 'unauthorized' }, { status: 401 });
		}
		const base = `/v1/apps/${APP}/machines`;
		if (url.pathname === base && method === 'GET') {
			const filters = [...url.searchParams].filter(([key]) => key.startsWith('metadata.'));
			const machines = [...this.machines.values()].filter(
				(machine) =>
					!this.honourMetadataFilter ||
					filters.every(
						([key, value]) => machine.config?.metadata?.[key.slice('metadata.'.length)] === value,
					),
			);
			return Response.json(machines.map((machine) => this.view(machine)));
		}
		if (url.pathname === base && method === 'POST') {
			const input = JSON.parse(bodyText(init.body)) as FlyMachineCreate;
			const machine = this.store(
				input.config.metadata.marimohub_owner,
				input.config.metadata.marimohub_sandbox_id,
				input.config.env,
				this.bootStates,
			);
			return Response.json(this.view(machine));
		}
		const one = url.pathname.match(/^\/v1\/apps\/[^/]+\/machines\/([^/]+)$/);
		if (one) {
			const machine = this.machines.get(one[1]);
			if (!machine) return Response.json({ error: 'machine not found' }, { status: 404 });
			if (method === 'GET') {
				const view = this.view(machine);
				machine.state = machine.upcomingStates.shift() ?? machine.state;
				return Response.json(view);
			}
			if (method === 'DELETE') {
				if (url.searchParams.get('force') !== 'true') {
					return Response.json({ error: 'machine still active' }, { status: 412 });
				}
				this.machines.delete(machine.id);
				machine.state = 'destroyed';
				return Response.json({ ok: true });
			}
		}
		return Response.json({ error: 'route not found' }, { status: 404 });
	}
}

export function helperTokenFor(sandboxId: string): string {
	return deriveHelperToken(HELPER_SECRET, sandboxId);
}
