import { createHmac } from 'node:crypto';
import type { FlyGuest } from './machines';

/** Everything the runner adapter reads from the hub's environment. */
export interface FlyComputeConfig {
	/** Fly Machines API base, e.g. http://_api.internal:4280 from inside Fly. */
	apiUrl: string;
	/** Token that may manage machines in the runner app only. */
	apiToken: string;
	/** Runner app, `kf-nbk-<fleet>`. */
	app: string;
	region: string;
	guest: FlyGuest;
	/** Selectable runner images; the first is the default. */
	images: readonly string[];
	/** Master secret each sandbox's helper token is derived from. */
	helperSecret: string;
	/** Marks this hub's machines, so listActive never sees another hub's. */
	owner: string;
	/** Fly-side lifetime cap given to every machine, in seconds. */
	maxLifetimeSeconds: number;
}

export interface FlyComputeContext {
	env: Record<string, string | undefined>;
	compute?: { sessionMaxLifetimeSeconds?: number };
}

const OWNER_PATTERN = /^[a-z0-9][a-z0-9_-]{0,62}$/;

function required(env: FlyComputeContext['env'], name: string): string {
	const value = env[name]?.trim();
	if (!value) throw new Error(`${name} is required by the Fly runner adapter`);
	return value;
}

function positiveInteger(env: FlyComputeContext['env'], name: string): number {
	const raw = required(env, name);
	const value = Number(raw);
	if (!Number.isSafeInteger(value) || value <= 0) {
		throw new Error(`${name} must be a positive whole number`);
	}
	return value;
}

export function deriveHelperToken(masterSecret: string, sandboxId: string): string {
	return createHmac('sha256', masterSecret).update(sandboxId).digest('hex');
}

export function parseFlyComputeConfig(context: FlyComputeContext): FlyComputeConfig {
	const { env } = context;
	if (env.MARIMOHUB_SANDBOX_EXPOSURE !== 'proxy') {
		throw new Error(
			'The Fly runner adapter needs MARIMOHUB_SANDBOX_EXPOSURE=proxy: runner machines are private',
		);
	}
	const helperSecret = required(env, 'MARIMOHUB_COMPUTE_FLY_HELPER_SECRET');
	if (Buffer.byteLength(helperSecret, 'utf8') < 32) {
		throw new Error('MARIMOHUB_COMPUTE_FLY_HELPER_SECRET must be at least 32 bytes');
	}
	const owner = required(env, 'MARIMOHUB_COMPUTE_FLY_OWNER');
	if (!OWNER_PATTERN.test(owner)) {
		throw new Error(
			'MARIMOHUB_COMPUTE_FLY_OWNER must be 1-63 lowercase letters, digits, hyphens or underscores',
		);
	}
	const cpuKind = required(env, 'MARIMOHUB_COMPUTE_FLY_CPU_KIND');
	if (cpuKind !== 'shared' && cpuKind !== 'performance') {
		throw new Error('MARIMOHUB_COMPUTE_FLY_CPU_KIND must be shared or performance');
	}
	const images = required(env, 'MARIMOHUB_COMPUTE_IMAGE')
		.split(',')
		.map((image) => image.trim())
		.filter(Boolean);
	const sessionMaxLifetimeSeconds = context.compute?.sessionMaxLifetimeSeconds ?? 0;
	if (!(sessionMaxLifetimeSeconds > 0)) {
		throw new Error(
			'The Fly runner adapter needs a session lifetime (MARIMOHUB_SESSION_MAX_LIFETIME_SECONDS) to cap each machine',
		);
	}
	return {
		apiUrl: required(env, 'MARIMOHUB_COMPUTE_FLY_API_URL'),
		apiToken: required(env, 'FLY_API_TOKEN'),
		app: required(env, 'MARIMOHUB_COMPUTE_FLY_APP'),
		region: required(env, 'MARIMOHUB_COMPUTE_FLY_REGION'),
		guest: {
			cpu_kind: cpuKind,
			cpus: positiveInteger(env, 'MARIMOHUB_COMPUTE_FLY_CPUS'),
			memory_mb: positiveInteger(env, 'MARIMOHUB_COMPUTE_FLY_MEMORY_MB'),
		},
		images,
		helperSecret,
		owner,
		// Twice the session lifetime, as marimohub's own providers do: the cap only
		// ever stops a machine the hub has lost track of, never a live session.
		maxLifetimeSeconds: Math.ceil(sessionMaxLifetimeSeconds * 2),
	};
}
