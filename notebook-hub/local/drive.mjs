// Drives one notebook session through the local hub and checks each step.
// Started by local/run.sh, which sets every variable read below.
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const { HUB_URL, DATA_DIR, NET6, APP, HUB_IMAGE, FLY_TOKEN, HELPER_SECRET } = process.env;
const MARKER = 'kf-relay-ok-42';
// What a member's request carries for the hub and must never reach notebook code:
// Keyfleet's signed note and a cookie, stood in for here by values 97 long.
const SIGN_IN_HEADERS = {
	'x-keyfleet-assertion': 'n'.repeat(97),
	cookie: `hub=${'c'.repeat(93)}`,
};
const LABEL = 'keyfleet.local-fly';

const NOTEBOOK = `import marimo

app = marimo.App()


@app.cell
def _():
    import os
    import pathlib
    import pwd

    pathlib.Path("result.txt").write_text("${MARKER}\\n")
    token_named = "MARIMOHUB_AGENT_TOKEN" in os.environ
    found = []
    for entry in pathlib.Path("/proc").glob("[0-9]*/environ"):
        try:
            if b"MARIMOHUB_AGENT_TOKEN" in entry.read_bytes():
                found.append(str(entry))
        except OSError:
            pass
    summary = (
        f"${MARKER} user={pwd.getpwuid(os.getuid()).pw_name} "
        f"token_in_env={token_named} token_readable_in_proc={found}"
    )
    summary
    return


@app.cell
def _():
    import marimo as mo

    request = mo.app_meta().request
    arrived = sorted(f"{name.lower()}:{len(value)}" for name, value in request.headers.items())
    f"${MARKER} headers={' '.join(arrived)}"
    return


if __name__ == "__main__":
    app.run()
`;

let step = 0;
function ok(message) {
	console.log(`  ${String(++step).padStart(2)}. ${message}`);
}
function check(condition, message) {
	if (!condition) throw new Error(`check failed: ${message}`);
}

async function api(method, path, body) {
	const response = await fetch(`${HUB_URL}/api/v1${path}`, {
		method,
		headers: body === undefined ? {} : { 'content-type': 'application/json' },
		body: body === undefined ? undefined : JSON.stringify(body),
	});
	const json = await response.json();
	if (!response.ok || !json.success) {
		throw new Error(`${method} ${path} -> ${response.status} ${JSON.stringify(json)}`);
	}
	return json.data;
}

function docker(...args) {
	return execFileSync('docker', args, { encoding: 'utf8' }).trim();
}

function runnerContainers(sandboxId) {
	const filter = `label=${LABEL}.metadata.marimohub_sandbox_id=${sandboxId}`;
	return docker('ps', '-a', '--filter', filter, '--format', '{{.ID}}').split('\n').filter(Boolean);
}

function listeners(container, file) {
	// /proc/net/tcp{,6}: local address column, state 0A = LISTEN.
	return readTable(docker('exec', container, 'cat', `/proc/net/${file}`))
		.filter((row) => row[3] === '0A')
		.map((row) => parseInt(row[1].split(':')[1], 16));
}
function readTable(text) {
	return text
		.split('\n')
		.slice(1)
		.map((line) => line.trim().split(/\s+/));
}

function findFile(root, name) {
	if (!existsSync(root)) return [];
	return readdirSync(root, { recursive: true })
		.map(String)
		.filter((path) => path.endsWith(name))
		.map((path) => join(root, path));
}

/** Runs the hub's shipped compute bundle in a container on the private network. */
function withBundle(script) {
	return docker(
		'run', '--rm', '--network', NET6,
		'-e', 'MARIMOHUB_SANDBOX_EXPOSURE=proxy',
		'-e', 'MARIMOHUB_COMPUTE_FLY_API_URL=http://_api.internal:4280',
		'-e', `FLY_API_TOKEN=${FLY_TOKEN}`,
		'-e', `MARIMOHUB_COMPUTE_FLY_APP=${APP}`,
		'-e', 'MARIMOHUB_COMPUTE_FLY_REGION=local',
		'-e', 'MARIMOHUB_COMPUTE_FLY_CPU_KIND=shared',
		'-e', 'MARIMOHUB_COMPUTE_FLY_CPUS=1',
		'-e', 'MARIMOHUB_COMPUTE_FLY_MEMORY_MB=1024',
		'-e', `MARIMOHUB_COMPUTE_IMAGE=${process.env.RUNNER_IMAGE}`,
		'-e', `MARIMOHUB_COMPUTE_FLY_HELPER_SECRET=${HELPER_SECRET}`,
		HUB_IMAGE, 'node', '--input-type=module', '-e', script,
	);
}

/** What another machine on the private network gets from `url`, asked with no password. */
function fromNeighbour(url) {
	return JSON.parse(
		docker(
			'run', '--rm', '--network', NET6, HUB_IMAGE, 'node', '--input-type=module', '-e',
			`const response = await fetch(${JSON.stringify(url)}, { redirect: 'manual' });
			const body = await response.text();
			console.log(JSON.stringify({
				status: response.status,
				location: response.headers.get('location'),
				page: body.includes('<marimo-server-token'),
			}));`,
		),
	);
}

async function runCells(sandboxUrl) {
	const page = await (await fetch(sandboxUrl)).text();
	const serverToken = page.match(/<marimo-server-token[^>]*data-token="([^"]*)"/)?.[1];
	check(serverToken !== undefined, 'the marimo page came back through the hub');
	ok('marimo page loaded through the hub proxy');

	const sessionId = randomUUID();
	const socket = new WebSocket(`${sandboxUrl.replace(/^http/, 'ws')}ws?session_id=${sessionId}`, {
		headers: SIGN_IN_HEADERS,
	});
	const outputs = {};
	let resolveReady;
	let resolveDone;
	let cells = Infinity;
	const ready = new Promise((resolve) => (resolveReady = resolve));
	const done = new Promise((resolve) => (resolveDone = resolve));
	socket.addEventListener('message', (event) => {
		const message = JSON.parse(String(event.data));
		if (message.op === 'kernel-ready') resolveReady(message.data);
		if (message.op === 'cell-op') {
			const data = message.data.output?.data;
			if (typeof data === 'string' && data.includes(MARKER)) outputs[message.data.cell_id] = data;
			if (Object.keys(outputs).length === cells) resolveDone();
		}
	});
	const timeout = (ms, what) =>
		new Promise((_, reject) => setTimeout(() => reject(new Error(`timed out: ${what}`)), ms));
	const kernel = await Promise.race([ready, timeout(60_000, 'kernel-ready')]);
	cells = kernel.cell_ids.length;
	ok(`kernel WebSocket open through the hub; kernel ready with ${kernel.cell_ids.length} cell(s)`);

	const instantiate = await fetch(`${sandboxUrl}api/kernel/instantiate`, {
		method: 'POST',
		headers: {
			'content-type': 'application/json',
			'Marimo-Session-Id': sessionId,
			'Marimo-Server-Token': serverToken,
			...SIGN_IN_HEADERS,
		},
		body: JSON.stringify({ objectIds: [], values: [], autoRun: true }),
	});
	check(instantiate.ok, `instantiate returned ${instantiate.status}`);
	await Promise.race([done, timeout(60_000, 'cell output')]);
	socket.close();
	return Object.values(outputs).map((output) => output.replace(/<[^>]+>/g, '').replaceAll('&#x27;', "'").trim());
}

async function main() {
	console.log(`Local end-to-end run against ${HUB_URL}`);
	const network = JSON.parse(docker('network', 'inspect', NET6))[0];
	check(network.EnableIPv4 === false && network.EnableIPv6 === true, 'private network is IPv6-only');
	ok(`private network ${NET6} is IPv6-only (${network.IPAM.Config.map((c) => c.Subnet).join(', ')})`);

	const project = await api('POST', '/projects', { name: 'Local proof', description: 'compute-fly' });
	const notebook = await api('POST', `/projects/${project.id}/notebooks`, {
		title: 'Relay proof',
		description: 'Runs one cell on a runner machine',
		code: NOTEBOOK,
	});
	ok(`notebook created (${notebook.id})`);

	const started = Date.now();
	const session = await api('POST', `/projects/${project.id}/notebooks/${notebook.id}/sessions`, {});
	check(session.status === 'running', `session is running (got ${session.status})`);
	const record = JSON.parse(
		readFileSync(join(DATA_DIR, '_system/sessions', project.id, `${session.session_id}.json`), 'utf8'),
	);
	const sandboxId = record.sandbox_id;
	const [container] = runnerContainers(sandboxId);
	check(container !== undefined, 'a runner machine exists for the sandbox');
	const labels = JSON.parse(docker('inspect', container))[0].Config.Labels;
	const machineId = labels[`${LABEL}.id`];
	ok(`session started in ${((Date.now() - started) / 1000).toFixed(1)} s on machine ${machineId} for ${sandboxId}`);

	const host = `${machineId}.vm.${APP}.internal`;
	const addresses = docker('exec', 'kf-nb-local-hub', 'getent', 'ahosts', host)
		.split('\n')
		.map((line) => line.split(/\s+/)[0]);
	check(addresses.every((address) => address.includes(':')), `${host} resolves to IPv6 only`);
	ok(`hub resolves ${host} to IPv6 only (${[...new Set(addresses)].join(', ')})`);

	const ipv4 = listeners(container, 'tcp');
	const ipv6 = listeners(container, 'tcp6');
	check(ipv4.includes(2718) && ipv6.includes(2718), 'marimo on IPv4 2718, relay on IPv6 2718');
	check(ipv6.includes(2717), 'helper on IPv6');
	ok(`in the runner: marimo listens on IPv4 ${ipv4.join(',')}; relay and helper on IPv6 ${ipv6.join(',')}`);

	const outputs = await runCells(session.sandbox_url);
	const output = outputs.find((text) => text.includes('user='));
	check(output.includes(`${MARKER} user=appuser`), 'cell ran as appuser');
	check(output.includes('token_in_env=False'), 'helper token not in the notebook environment');
	check(output.includes('token_readable_in_proc=[]'), 'helper token not readable through /proc');
	ok(`cell ran on the runner: ${output}`);

	const arrived = outputs.find((text) => text.includes('headers=')).split('headers=')[1].replace(/'$/, '').split(' ');
	const names = arrived.map((header) => header.split(':')[0]);
	check(names.includes('authorization'), 'the hub adds the kernel password to what it passes on');
	check(
		!names.includes('cookie') && !names.includes('x-keyfleet-assertion'),
		`no sign-in cookie or note reaches notebook code (got ${names.join(',')})`,
	);
	check(
		arrived.every((header) => Number(header.split(':')[1]) < 97),
		`nothing the caller sent as sign-in reaches notebook code (got ${arrived.join(' ')})`,
	);
	ok(`notebook code sees none of the caller's sign-in, only the kernel's own password: ${arrived.join(' ')}`);

	// Every member can read a running notebook's address, so a neighbour may know its path.
	const neighbour = fromNeighbour(`http://[${addresses[0]}]:2718${new URL(session.sandbox_url).pathname}`);
	check(
		neighbour.status === 303 && neighbour.location.includes('/auth/login') && !neighbour.page,
		`another machine is refused on the kernel port (got ${JSON.stringify(neighbour)})`,
	);
	ok(`another machine on the private network, knowing the notebook's path but not its password, is sent to the kernel's password page (${neighbour.status})`);

	const scoped = JSON.parse(
		withBundle(`
			const { default: library } = await import('/etc/marimohub/fly-compute.mjs');
			const make = (owner) => library.create({
				env: { ...process.env, MARIMOHUB_COMPUTE_FLY_OWNER: owner },
				compute: { sessionMaxLifetimeSeconds: 14400 },
			});
			const ours = make('kf-nb-local');
			const theirs = make('kf-nb-decoy');
			const decoy = theirs.create('sb-decoydecoydecoy0');
			await decoy.ready();
			const result = { ours: await ours.listActive(), theirs: await theirs.listActive() };
			await decoy.destroy();
			await decoy.destroy();
			console.log(JSON.stringify(result));
		`),
	);
	check(
		scoped.ours.length === 1 && scoped.ours[0].id === sandboxId,
		`listActive for this hub is only ${sandboxId}: ${JSON.stringify(scoped.ours)}`,
	);
	check(
		scoped.theirs.length === 1 && scoped.theirs[0].id === 'sb-decoydecoydecoy0',
		`listActive for the other owner is only its decoy: ${JSON.stringify(scoped.theirs)}`,
	);
	check(runnerContainers('sb-decoydecoydecoy0').length === 0, 'decoy machine destroyed (twice)');
	ok(`listActive (shipped bundle) sees only its owner: ours=${scoped.ours.map((s) => s.id)} other=${scoped.theirs.map((s) => s.id)}`);

	// marimo writes its session snapshot (cell outputs) on its own schedule.
	const snapshot = '/workspace/__marimo__/session/notebook.py.json';
	let written = '';
	for (let attempt = 0; attempt < 30 && !written.includes(MARKER); attempt++) {
		await new Promise((resolve) => setTimeout(resolve, 1000));
		written = docker('exec', container, 'sh', '-c', `cat ${snapshot} 2>/dev/null || true`);
	}
	check(written.includes(MARKER), 'marimo session snapshot holds the cell output');
	ok('marimo wrote the cell output into its session snapshot in the runner');

	await api('DELETE', `/projects/${project.id}/notebooks/${notebook.id}/sessions/${session.session_id}`);
	ok('session deleted');

	const notebookRoot = join(DATA_DIR, 'projects', project.id, 'notebooks', notebook.id);
	const result = join(notebookRoot, 'workspace', 'result.txt');
	check(existsSync(result) && readFileSync(result, 'utf8') === `${MARKER}\n`, 'workspace file saved');
	const sessionFiles = findFile(join(notebookRoot, 'versions'), 'session.json');
	check(sessionFiles.length > 0, 'marimo session snapshot saved');
	check(readFileSync(sessionFiles[0], 'utf8').includes(MARKER), 'session snapshot holds the cell output');
	ok(`workspace read back with readFileBounded: workspace/result.txt and ${sessionFiles[0].slice(notebookRoot.length + 1)}`);

	for (let attempt = 0; attempt < 30 && runnerContainers(sandboxId).length > 0; attempt++) {
		await new Promise((resolve) => setTimeout(resolve, 1000));
	}
	check(runnerContainers(sandboxId).length === 0, 'runner machine removed');
	ok(`runner machine ${machineId} is gone`);
	console.log('Local end-to-end run succeeded.');
}

main().catch((error) => {
	console.error(`Local end-to-end run declined: ${error.message}`);
	process.exit(1);
});
