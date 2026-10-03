/**
 * The four Fly Machines API calls the runner adapter makes, against one app.
 * https://fly.io/docs/machines/api/machines-resource/
 */

export interface FlyGuest {
	cpu_kind: 'shared' | 'performance';
	cpus: number;
	memory_mb: number;
}

export interface FlyMachineConfig {
	image: string;
	env: Record<string, string>;
	guest: FlyGuest;
	auto_destroy: true;
	restart: { policy: 'no' };
	metadata: Record<string, string>;
}

export interface FlyMachineCreate {
	name: string;
	region: string;
	config: FlyMachineConfig;
}

export interface FlyMachine {
	id: string;
	name?: string;
	state: string;
	region?: string;
	private_ip?: string;
	created_at?: string;
	config?: { metadata?: Record<string, string> };
}

export interface FlyMachinesClient {
	/** Machines of the app whose metadata matches every given key. */
	list(metadata: Record<string, string>): Promise<FlyMachine[]>;
	get(id: string): Promise<FlyMachine>;
	create(input: FlyMachineCreate): Promise<FlyMachine>;
	/** Force-destroys a machine, whatever its state. */
	destroy(id: string): Promise<void>;
}

export class FlyApiError extends Error {
	constructor(
		readonly status: number,
		message: string,
	) {
		super(message);
		this.name = 'FlyApiError';
	}
}

const REQUEST_TIMEOUT_MS = 30_000;

export function createFlyMachinesClient(options: {
	apiUrl: string;
	token: string;
	app: string;
}): FlyMachinesClient {
	const base = `${options.apiUrl.replace(/\/+$/, '')}/v1/apps/${encodeURIComponent(options.app)}/machines`;

	async function call(method: string, path: string, body?: unknown): Promise<unknown> {
		const response = await fetch(`${base}${path}`, {
			method,
			headers: {
				authorization: `Bearer ${options.token}`,
				...(body === undefined ? {} : { 'content-type': 'application/json' }),
			},
			body: body === undefined ? undefined : JSON.stringify(body),
			signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
		});
		if (!response.ok) {
			// Fly error bodies are short JSON like {"error":"..."}; they never echo the token.
			const detail = (await response.text()).slice(0, 500);
			throw new FlyApiError(
				response.status,
				`Fly Machines API ${method} ${path || '/'} returned HTTP ${response.status}: ${detail}`,
			);
		}
		const text = await response.text();
		return text ? JSON.parse(text) : undefined;
	}

	return {
		async list(metadata) {
			const query = new URLSearchParams(
				Object.entries(metadata).map(([key, value]) => [`metadata.${key}`, value]),
			);
			const machines = await call('GET', `?${query}`);
			if (!Array.isArray(machines)) throw new Error('Fly Machines API list did not return a list');
			return machines as FlyMachine[];
		},
		async get(id) {
			return (await call('GET', `/${encodeURIComponent(id)}`)) as FlyMachine;
		},
		async create(input) {
			return (await call('POST', '', input)) as FlyMachine;
		},
		async destroy(id) {
			await call('DELETE', `/${encodeURIComponent(id)}?force=true`);
		},
	};
}
