// Local stand-in for the four Fly Machines API calls compute-fly makes. Each
// "machine" is a runner container on an IPv6-only Docker network, reachable as
// <machine_id>.vm.<app>.internal like a machine on Fly's private network.
// Runs inside a container with the Docker socket mounted; local proof only.
import { randomBytes } from 'node:crypto';
import http from 'node:http';

const TOKEN = required('FAKE_FLY_TOKEN');
const APP = required('FAKE_FLY_APP');
const NETWORK = required('FAKE_FLY_NETWORK');
const PORT = 4280;
const LABEL = 'keyfleet.local-fly';

function required(name) {
	const value = process.env[name];
	if (!value) throw new Error(`${name} is required`);
	return value;
}

function docker(method, path, body) {
	return new Promise((resolve, reject) => {
		const request = http.request(
			{
				socketPath: '/var/run/docker.sock',
				method,
				path,
				headers: body === undefined ? {} : { 'content-type': 'application/json' },
			},
			(response) => {
				const chunks = [];
				response.on('data', (chunk) => chunks.push(chunk));
				response.on('end', () => {
					const text = Buffer.concat(chunks).toString('utf8');
					resolve({ status: response.statusCode, body: text ? JSON.parse(text) : undefined });
				});
			},
		);
		request.on('error', reject);
		request.end(body === undefined ? undefined : JSON.stringify(body));
	});
}

const STATES = {
	created: 'created',
	running: 'started',
	restarting: 'starting',
	paused: 'suspended',
	removing: 'destroying',
	exited: 'stopped',
	dead: 'stopped',
};

function machineFrom(labels, status, created, ipv6) {
	const metadata = {};
	for (const [key, value] of Object.entries(labels)) {
		if (key.startsWith(`${LABEL}.metadata.`)) metadata[key.slice(`${LABEL}.metadata.`.length)] = value;
	}
	return {
		id: labels[`${LABEL}.id`],
		name: labels[`${LABEL}.name`],
		state: STATES[status] ?? status,
		region: labels[`${LABEL}.region`],
		private_ip: ipv6 || undefined,
		created_at: created,
		config: { metadata },
	};
}

async function list(query) {
	const labels = [`${LABEL}.app=${APP}`];
	for (const [key, value] of query) {
		if (key.startsWith('metadata.')) labels.push(`${LABEL}.metadata.${key.slice(9)}=${value}`);
	}
	const filters = encodeURIComponent(JSON.stringify({ label: labels }));
	const { body } = await docker('GET', `/containers/json?all=true&filters=${filters}`);
	return body.map((container) =>
		machineFrom(
			container.Labels,
			container.State,
			new Date(container.Created * 1000).toISOString(),
			container.NetworkSettings?.Networks?.[NETWORK]?.GlobalIPv6Address,
		),
	);
}

async function get(id) {
	const { status, body } = await docker('GET', `/containers/fly-${id}/json`);
	if (status === 404) return undefined;
	return machineFrom(
		body.Config.Labels,
		body.State.Status,
		body.Created,
		body.NetworkSettings?.Networks?.[NETWORK]?.GlobalIPv6Address,
	);
}

async function create(input) {
	const id = randomBytes(7).toString('hex');
	const { config } = input;
	const labels = {
		[LABEL]: 'true',
		[`${LABEL}.id`]: id,
		[`${LABEL}.app`]: APP,
		[`${LABEL}.name`]: input.name,
		[`${LABEL}.region`]: input.region,
	};
	for (const [key, value] of Object.entries(config.metadata ?? {})) {
		labels[`${LABEL}.metadata.${key}`] = value;
	}
	const created = await docker('POST', `/containers/create?name=fly-${id}`, {
		Image: config.image,
		Env: Object.entries(config.env ?? {}).map(([key, value]) => `${key}=${value}`),
		Labels: labels,
		HostConfig: {
			// auto_destroy: the container is removed as soon as it stops.
			AutoRemove: config.auto_destroy === true,
			// Fly machines run under Fly's own init as PID 1.
			Init: true,
			Memory: config.guest.memory_mb * 1024 * 1024,
			NanoCpus: config.guest.cpus * 1e9,
			NetworkMode: NETWORK,
			RestartPolicy: { Name: config.restart.policy },
		},
		NetworkingConfig: {
			EndpointsConfig: { [NETWORK]: { Aliases: [`${id}.vm.${APP}.internal`] } },
		},
	});
	if (created.status !== 201) return { status: 422, body: { error: created.body?.message } };
	await docker('POST', `/containers/fly-${id}/start`);
	return { status: 200, body: await get(id) };
}

async function destroy(id, force) {
	if (!force) return { status: 412, body: { error: 'machine is running; use force' } };
	const { status, body } = await docker('DELETE', `/containers/fly-${id}?force=true`);
	if (status === 404) return { status: 404, body: { error: 'machine not found' } };
	// 409: Docker is already removing it (auto_destroy), which is what was asked.
	if (status === 204 || status === 409) return { status: 200, body: { ok: true } };
	return { status: 500, body: { error: body?.message } };
}

async function route(request, url, input) {
	if (request.headers.authorization !== `Bearer ${TOKEN}`) {
		return { status: 401, body: { error: 'unauthorized' } };
	}
	const base = `/v1/apps/${APP}/machines`;
	if (url.pathname === base && request.method === 'GET') {
		return { status: 200, body: await list(url.searchParams) };
	}
	if (url.pathname === base && request.method === 'POST') return create(input);
	if (url.pathname.startsWith(`${base}/`)) {
		const id = url.pathname.slice(base.length + 1);
		if (request.method === 'GET') {
			const machine = await get(id);
			return machine
				? { status: 200, body: machine }
				: { status: 404, body: { error: 'machine not found' } };
		}
		if (request.method === 'DELETE') return destroy(id, url.searchParams.get('force') === 'true');
	}
	return { status: 404, body: { error: 'not found' } };
}

http
	.createServer((request, response) => {
		const chunks = [];
		request.on('data', (chunk) => chunks.push(chunk));
		request.on('end', async () => {
			let result;
			try {
				const text = Buffer.concat(chunks).toString('utf8');
				result = await route(request, new URL(request.url, 'http://local'), text ? JSON.parse(text) : undefined);
			} catch (error) {
				result = { status: 500, body: { error: String(error) } };
			}
			response.writeHead(result.status, { 'content-type': 'application/json' });
			response.end(JSON.stringify(result.body));
			console.log(`${request.method} ${request.url} -> ${result.status}`);
		});
	})
	.listen(PORT, '::');
