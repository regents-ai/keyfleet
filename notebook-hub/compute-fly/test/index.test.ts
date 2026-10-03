import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { SandboxId } from '@marimo-hub/core/ids';
import {
	computeContract,
	CONTRACT_HIDDEN_FILE,
	CONTRACT_VISIBLE_FILE,
} from '@marimo-hub/core/testing/compute-contract';
import manifest, { FlyCompute, flyGuest, parseFlyComputeConfig } from '../src/index';
import type { FlyMachineCreate } from '../src/machines';
import {
	API_TOKEN,
	APP,
	COMPUTE_CONTEXT,
	FlyWorld,
	HELPER_SECRET,
	helperTokenFor,
	hubEnv,
	OWNER,
} from './world';

const ID = 'sb-aaaaaaaaaaaaaaaa' as SandboxId;
const SECOND_ID = 'sb-bbbbbbbbbbbbbbbb' as SandboxId;
const DEFAULT_IMAGE = 'registry.fly.io/kf-nbk-test:runner';

let world: FlyWorld;

function provider(env: Record<string, string | undefined> = {}): FlyCompute {
	return manifest.create({
		env: hubEnv(env),
		errors: { preconditionFailed: (message?: string) => new Error(message) },
		compute: { ...COMPUTE_CONTEXT, sessionIdleTimeoutMs: 1_800_000 },
	} as never) as FlyCompute;
}

function createBodies(): FlyMachineCreate[] {
	return world.apiCalls('POST').map((call) => JSON.parse(call.body!) as FlyMachineCreate);
}

beforeEach(() => {
	world = new FlyWorld();
	vi.stubGlobal('fetch', vi.fn(world.fetch));
});

afterEach(() => {
	vi.unstubAllGlobals();
});

describe('manifest', () => {
	it('is a compute adapter manifest for API version 1', () => {
		expect(manifest).toMatchObject({ apiVersion: 1, kind: 'compute' });
		expect(provider()).toBeInstanceOf(FlyCompute);
	});

	it('reads its settings from the hub environment', () => {
		expect(parseFlyComputeConfig({ env: hubEnv(), compute: COMPUTE_CONTEXT })).toEqual({
			apiUrl: 'http://fly-api.test',
			apiToken: API_TOKEN,
			app: APP,
			region: 'iad',
			guest: { cpu_kind: 'shared', cpus: 1, memory_mb: 1024 },
			images: [DEFAULT_IMAGE, 'contract-image-override'],
			helperSecret: HELPER_SECRET,
			owner: OWNER,
			maxLifetimeSeconds: 28_800,
		});
	});

	it.each([
		['MARIMOHUB_SANDBOX_EXPOSURE', 'direct', /EXPOSURE=proxy/],
		['MARIMOHUB_COMPUTE_FLY_HELPER_SECRET', 'too-short', /at least 32 bytes/],
		['MARIMOHUB_COMPUTE_FLY_OWNER', 'Not Valid', /OWNER must be/],
		['MARIMOHUB_COMPUTE_FLY_CPU_KIND', 'gpu', /shared or performance/],
		['MARIMOHUB_COMPUTE_FLY_MEMORY_MB', '1.5', /positive whole number/],
		['FLY_API_TOKEN', undefined, /FLY_API_TOKEN is required/],
		['MARIMOHUB_COMPUTE_FLY_APP', '', /MARIMOHUB_COMPUTE_FLY_APP is required/],
		['MARIMOHUB_COMPUTE_IMAGE', ' ', /MARIMOHUB_COMPUTE_IMAGE is required/],
	])('refuses %s=%s', (name, value, message) => {
		expect(() =>
			parseFlyComputeConfig({ env: hubEnv({ [name]: value }), compute: COMPUTE_CONTEXT }),
		).toThrow(message);
	});

	it('refuses to start without a session lifetime to cap machines with', () => {
		expect(() => parseFlyComputeConfig({ env: hubEnv() })).toThrow(/session lifetime/);
	});
});

describe('create and find-or-create', () => {
	it('creates one private, self-destroying machine on first use', async () => {
		const instance = provider().create(ID);
		expect((await instance.exec('true')).success).toBe(true);

		const [body, ...more] = createBodies();
		expect(more).toEqual([]);
		expect(body).toEqual({
			name: ID,
			region: 'iad',
			config: {
				image: DEFAULT_IMAGE,
				env: {
					MARIMOHUB_AGENT_TOKEN: helperTokenFor(ID),
					MARIMOHUB_AGENT_PORT: '2717',
					MARIMOHUB_RUNNER_MAX_LIFETIME_SECONDS: '28800',
				},
				guest: { cpu_kind: 'shared', cpus: 1, memory_mb: 1024 },
				auto_destroy: true,
				restart: { policy: 'no' },
				metadata: { marimohub_owner: OWNER, marimohub_sandbox_id: ID },
			},
		});
		// No services: nothing about the machine is reachable from the internet.
		expect(body.config).not.toHaveProperty('services');
		expect(world.apiCalls('POST')[0].headers.get('authorization')).toBe(`Bearer ${API_TOKEN}`);
	});

	it('finds the existing machine instead of creating a second one', async () => {
		await provider().create(ID).exec('true');
		// A fresh provider has an empty cache, as after a hub restart.
		const again = provider().create(ID);
		expect((await again.exec('true')).success).toBe(true);
		expect(world.apiCalls('POST')).toHaveLength(1);
		expect(world.machines.size).toBe(1);
		const listed = world.apiCalls('GET').find((call) => call.url.search !== '');
		expect(listed?.url.searchParams.get('metadata.marimohub_owner')).toBe(OWNER);
	});

	it('creates without looking first when the hub asks for a fresh sandbox', async () => {
		await provider().create(ID, { reuse: false }).exec('true');
		expect(world.apiCalls('GET').filter((call) => call.url.search !== '')).toEqual([]);
		expect(world.apiCalls('POST')).toHaveLength(1);
	});

	it('does not reuse a machine another owner runs for the same sandbox id', async () => {
		world.addForeignMachine('another-hub', ID);
		await provider().create(ID).exec('true');
		expect(world.apiCalls('POST')).toHaveLength(1);
	});

	it('refuses to choose between two live machines for one sandbox', async () => {
		await provider().create(ID, { reuse: false }).exec('true');
		await provider().create(ID, { reuse: false }).exec('true');
		const result = await provider().create(ID).exec('true');
		expect(result).toMatchObject({
			success: false,
			stderr: expect.stringMatching(/Multiple live/),
		});
	});

	it('waits for the machine to start before using it', async () => {
		world.bootStates = ['created', 'starting', 'started'];
		const instance = provider().create(ID);
		await instance.ready!();
		expect(world.apiCalls('GET', `/${world.machineFor(ID)!.id}`).length).toBeGreaterThanOrEqual(3);
		expect(instance.drainTimings!()).toMatchObject({
			create: expect.any(Number),
			boot: expect.any(Number),
		});
	});

	it('fails at once when a new machine stops before its helper answers', async () => {
		world.bootStates = ['created', 'stopped'];
		await expect(provider().create(ID).ready!()).rejects.toThrow(/is stopped before its helper/);
	});

	it('passes the chosen image and compute profile to Fly', async () => {
		await provider()
			.create(ID, {
				image: 'contract-image-override',
				resources: { cpu: 1.5, memoryBytes: 3 * 1024 ** 3 },
			})
			.exec('true');
		expect(createBodies()[0].config).toMatchObject({
			image: 'contract-image-override',
			guest: { cpu_kind: 'shared', cpus: 2, memory_mb: 3072 },
		});
	});

	it('maps compute profiles onto Fly guest sizes', () => {
		const base = { cpu_kind: 'shared' as const, cpus: 1, memory_mb: 1024 };
		expect(flyGuest(base, undefined)).toEqual(base);
		expect(flyGuest(base, { memoryBytes: 1 })).toEqual({ ...base, memory_mb: 256 });
		expect(flyGuest(base, { cpu: 8 })).toEqual({ ...base, cpus: 8 });
		expect(() => flyGuest(base, { cpu: 9 })).toThrow(/at most 8/);
		expect(() => flyGuest(base, { gpu: 'A100' })).toThrow(/GPU/);
	});
});

describe('helper access', () => {
	it('talks to the helper on the machine private address with a per-sandbox token', async () => {
		await provider().create(ID).exec('true');
		const machineId = world.machineFor(ID)!.id;
		const helperCalls = world.requests.filter((call) => call.url.port === '2717');
		expect(helperCalls.length).toBeGreaterThan(0);
		for (const call of helperCalls) {
			expect(call.url.hostname).toBe(`${machineId}.vm.${APP}.internal`);
			expect(call.headers.get('authorization')).toBe(`Bearer ${helperTokenFor(ID)}`);
		}
		expect(helperTokenFor(ID)).not.toBe(helperTokenFor(SECOND_ID));
	});

	it('exposes only the kernel port, at the machine private address', async () => {
		const instance = provider().create(ID);
		const { url } = await instance.exposePort(2718, { hostname: 'hub.example' });
		expect(url).toBe(`http://${world.machineFor(ID)!.id}.vm.${APP}.internal:2718`);
		await expect(instance.exposePort(8080, { hostname: 'hub.example' })).rejects.toThrow(
			/only the kernel port/,
		);
	});

	it('never mounts buckets and leaves file copying to the hub', async () => {
		const instance = provider().create(ID);
		expect(instance.supportsBucketMount).toBe(false);
		await expect(
			instance.mountBucket({ bucket: 'b', mountPath: '/workspace/data' } as never),
		).rejects.toThrow(/not supported/);
		await expect(instance.unmountBucket('/workspace/data')).resolves.toBeUndefined();
		expect(world.requests).toEqual([]);
	});

	it('returns null from proxy so the hub forwards notebook traffic itself', async () => {
		expect(await provider().proxy(new Request('http://hub.example/'))).toBeNull();
	});
});

describe('destroy', () => {
	it('force-deletes the machine', async () => {
		const instance = provider().create(ID);
		await instance.exec('true');
		const machineId = world.machineFor(ID)!.id;
		await instance.destroy();
		const [call] = world.apiCalls('DELETE', `/${machineId}`);
		expect(call.url.searchParams.get('force')).toBe('true');
		expect(world.machines.size).toBe(0);
	});

	it('succeeds when called twice', async () => {
		const instance = provider().create(ID);
		await instance.exec('true');
		await instance.destroy();
		await expect(instance.destroy()).resolves.toBeUndefined();
	});

	it('succeeds when the machine was already gone', async () => {
		const instance = provider().create(ID);
		await instance.exec('true');
		world.machines.clear();
		await expect(instance.destroy()).resolves.toBeUndefined();
	});

	it('succeeds for a sandbox that never had a machine, without creating one', async () => {
		await expect(provider().create(ID).destroy()).resolves.toBeUndefined();
		expect(world.apiCalls('POST')).toEqual([]);
		expect(world.apiCalls('DELETE')).toEqual([]);
	});

	it('finds the machine to delete after a hub restart', async () => {
		await provider().create(ID).exec('true');
		await provider().create(ID).destroy();
		expect(world.machines.size).toBe(0);
	});

	it('never deletes another owner machine', async () => {
		const foreign = world.addForeignMachine('another-hub', ID);
		await provider().create(ID).destroy();
		expect(world.machines.has(foreign)).toBe(true);
	});

	it('reports a real Fly failure', async () => {
		const instance = provider().create(ID);
		await instance.exec('true');
		vi.mocked(fetch).mockResolvedValueOnce(Response.json({ error: 'boom' }, { status: 500 }));
		await expect(instance.destroy()).rejects.toThrow(/HTTP 500/);
	});
});

describe('listActive', () => {
	it('lists only this owner started machines, by sandbox id', async () => {
		await provider().create(ID).exec('true');
		await provider().create(SECOND_ID).exec('true');
		world.addForeignMachine('another-hub', 'sb-cccccccccccccccc');
		world.machineFor(SECOND_ID)!.state = 'stopped';

		const active = await provider().listActive();
		expect(active).toEqual([{ id: ID, createdAt: world.machineFor(ID)!.created_at }]);
	});

	it('stays scoped to its owner even if Fly ignored the metadata filter', async () => {
		world.honourMetadataFilter = false;
		await provider().create(ID).exec('true');
		world.addForeignMachine('another-hub', 'sb-cccccccccccccccc');
		expect((await provider().listActive()).map((sandbox) => sandbox.id)).toEqual([ID]);
	});

	it('skips machines whose name is not a marimohub sandbox id', async () => {
		world.addForeignMachine(OWNER, 'not-a-sandbox');
		expect(await provider().listActive()).toEqual([]);
	});
});

describe('secrets', () => {
	it('gives a runner machine no hub, storage or Fly secret', async () => {
		const instance = provider().create(ID);
		await instance.setEnvVars({ MARIMO_TOKEN: 'kernel-token' });
		await instance.exec('true');
		await instance.startProcess('marimo edit', { env: { EXTRA: 'value' } });

		const secrets = Object.entries(hubEnv())
			.filter(([name]) => /SECRET|TOKEN|PASSWORD|KEY|DATABASE_URL/.test(name))
			.map(([, value]) => value);
		expect(secrets).toContain(API_TOKEN);
		expect(secrets).toContain(HELPER_SECRET);

		const toRunner = world.requests.filter(
			(call) => call.url.port === '2717' || call.method === 'POST',
		);
		expect(toRunner.length).toBeGreaterThan(3);
		for (const call of toRunner) {
			for (const secret of secrets) expect(call.body ?? '').not.toContain(secret);
		}
		expect(Object.keys(world.machineFor(ID)!.env).sort()).toEqual([
			'MARIMOHUB_AGENT_PORT',
			'MARIMOHUB_AGENT_TOKEN',
			'MARIMOHUB_RUNNER_MAX_LIFETIME_SECONDS',
		]);
	});
});

computeContract(
	'FlyCompute',
	() => {
		world = new FlyWorld();
		vi.stubGlobal('fetch', vi.fn(world.fetch));
		return provider();
	},
	{
		mountFallsBack: true,
		semantics: {
			failingCommand: 'mh-contract-fail',
			absentFile: { path: '/workspace/contract-absent.txt', code: 'NOT_FOUND' },
			envProbe: (name) => `printf '%s' "$${name}"`,
			hiddenFiles: {
				dir: '/workspace',
				seed: (instance) =>
					instance.writeFiles([
						{ path: `/workspace/${CONTRACT_VISIBLE_FILE}`, content: 'v' },
						{ path: `/workspace/${CONTRACT_HIDDEN_FILE}`, content: 'h' },
					]),
			},
			launch: {},
		},
	},
);
