// Drives file writes over the revision read, one notebook session, then three
// failing runs, through the local hub and checks each step. Every request
// carries a pass signed as Keyfleet signs them. Started by local/run.sh, which
// sets every variable read below.
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash, createPrivateKey, randomBytes, randomUUID, sign } from 'node:crypto';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const { HUB_URL, DATA_DIR, NET6, APP, HUB_IMAGE, FLY_TOKEN, HELPER_SECRET } = process.env;
const { PASS_KEY, PASS_ISSUER, PASS_AUDIENCE } = process.env;
const MARKER = 'kf-relay-ok-42';
const LABEL = 'keyfleet.local-fly';
// The hub's super admin makes the project; two editors and a viewer are its
// members. The first editor writes the notebooks and starts their runs.
const PROVISIONER = 'kf_provisioner_local';
const EDITOR = 'kf_local_editor';
const OTHER_EDITOR = 'kf_local_other_editor';
const VIEWER = 'kf_local_viewer';

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


if __name__ == "__main__":
    app.run()
`;

// A notebook whose pyproject.toml rules out the hub's Python.
const PYPROJECT = `[project]
name = "capped"
version = "0.1.0"
requires-python = ">=3.11,<3.13"
dependencies = ["humanize"]
`;

const PLAIN = `import marimo

app = marimo.App()


@app.cell
def _():
    "ready"
    return


if __name__ == "__main__":
    app.run()
`;

const RAISES = `import marimo

app = marimo.App()


@app.cell
def _():
    1 / 0
    return


if __name__ == "__main__":
    app.run()
`;

/**
 * Values made for this run only, each one a notebook prints before it fails: the
 * value the hub injects, written plainly, base64-encoded and URL-encoded, and
 * credential shapes written into the notebook itself. `secret` is the part that
 * must never be stored or shown.
 */
function plantedValues() {
	const token = (bytes) => randomBytes(bytes).toString('base64url');
	const env = `kf plant/${randomBytes(6).toString('hex')}+${token(6)}`;
	const pw = token(12);
	const jwtPart = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
	const jwt = `${jwtPart({ alg: 'HS256', typ: 'JWT' })}.${jwtPart({ sub: token(12) })}.${token(32)}`;
	const bearer = token(24);
	const sk = `sk-${token(24)}`;
	const hex = randomBytes(20).toString('hex');
	return {
		env,
		lines: {
			bearer: `Authorization: Bearer ${bearer}`,
			url: `https://kfuser:${pw}@example.invalid/data`,
			jwt,
			sk,
			hex,
		},
		secrets: [
			{ label: 'injected value', secret: env },
			{ label: 'injected value, base64', secret: Buffer.from(env).toString('base64') },
			{ label: 'injected value, URL-encoded', secret: encodeURIComponent(env) },
			{ label: 'Bearer header', secret: bearer },
			{ label: 'URL with user:pass', secret: `kfuser:${pw}` },
			{ label: 'JWT', secret: jwt },
			{ label: 'sk- key', secret: sk },
			{ label: '40-hex string', secret: hex },
		],
	};
}

function plantingNotebook({ lines }) {
	return `import marimo

app = marimo.App()


@app.cell
def _():
    import base64
    import os
    import sys
    import urllib.parse

    value = os.environ["KF_PLANTED"]
    lines = [
        value,
        base64.b64encode(value.encode()).decode(),
        urllib.parse.quote(value, safe=""),
        "${lines.bearer}",
        "${lines.url}",
        "${lines.jwt}",
        "${lines.sk}",
        "${lines.hex}",
    ]
    for number, line in enumerate(lines, 1):
        print(f"planted {number}: {line}", file=sys.__stderr__, flush=True)
    raise RuntimeError("stopped after printing")
    return


if __name__ == "__main__":
    app.run()
`;
}

/** The labels of the planted values `text` holds, whole or by their first or last 12 characters. */
function leaks(text, secrets) {
	const parts = (secret) =>
		secret.length > 12 ? [secret, secret.slice(0, 12), secret.slice(-12)] : [secret];
	return secrets
		.filter(({ secret }) => parts(secret).some((part) => text.includes(part)))
		.map(({ label }) => label);
}

const signingJwk = JSON.parse(readFileSync(PASS_KEY, 'utf8')).keys[0];
const signingKey = createPrivateKey({ key: signingJwk, format: 'jwk' });
const kid = createHash('sha256')
	.update(JSON.stringify({ crv: signingJwk.crv, kty: signingJwk.kty, x: signingJwk.x, y: signingJwk.y }))
	.digest('base64url');

/** The pass header for `subject`, signed as Keyfleet.Notebooks.Pass signs it. */
function as(subject) {
	const now = Math.floor(Date.now() / 1000);
	const part = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
	const claims = {
		iss: PASS_ISSUER,
		aud: PASS_AUDIENCE,
		sub: subject,
		email: `${subject}@identity.keyfleet.invalid`,
		iat: now,
		exp: now + 300,
	};
	const body = `${part({ alg: 'ES256', kid, typ: 'JWT' })}.${part(claims)}`;
	const signature = sign('sha256', Buffer.from(body), { key: signingKey, dsaEncoding: 'ieee-p1363' });
	return { 'X-Keyfleet-Assertion': `${body}.${signature.toString('base64url')}` };
}

let step = 0;
function ok(message) {
	console.log(`  ${String(++step).padStart(2)}. ${message}`);
}
function check(condition, message) {
	if (!condition) throw new Error(`check failed: ${message}`);
}

async function api(subject, method, path, body) {
	const response = await fetch(`${HUB_URL}/api/v1${path}`, {
		method,
		headers: {
			...as(subject),
			...(body === undefined ? {} : { 'content-type': 'application/json' }),
		},
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

async function runCells(sandboxUrl) {
	const page = await (await fetch(sandboxUrl, { headers: as(EDITOR) })).text();
	const serverToken = page.match(/<marimo-server-token[^>]*data-token="([^"]*)"/)?.[1];
	check(serverToken !== undefined, 'the marimo page came back through the hub');
	ok('marimo page loaded through the hub proxy');

	const sessionId = randomUUID();
	const socket = new WebSocket(`${sandboxUrl.replace(/^http/, 'ws')}ws?session_id=${sessionId}`, {
		headers: as(EDITOR),
	});
	const outputs = [];
	let resolveReady;
	let resolveDone;
	const ready = new Promise((resolve) => (resolveReady = resolve));
	const done = new Promise((resolve) => (resolveDone = resolve));
	socket.addEventListener('message', (event) => {
		const message = JSON.parse(String(event.data));
		if (message.op === 'kernel-ready') resolveReady(message.data);
		if (message.op === 'cell-op') {
			const data = message.data.output?.data;
			if (typeof data === 'string' && data.includes(MARKER)) outputs.push(data);
			if (outputs.length > 0 && message.data.status === 'idle') resolveDone();
		}
	});
	const timeout = (ms, what) =>
		new Promise((_, reject) => setTimeout(() => reject(new Error(`timed out: ${what}`)), ms));
	const kernel = await Promise.race([ready, timeout(60_000, 'kernel-ready')]);
	ok(`kernel WebSocket open through the hub; kernel ready with ${kernel.cell_ids.length} cell(s)`);

	const instantiate = await fetch(`${sandboxUrl}api/kernel/instantiate`, {
		method: 'POST',
		headers: {
			...as(EDITOR),
			'content-type': 'application/json',
			'Marimo-Session-Id': sessionId,
			'Marimo-Server-Token': serverToken,
		},
		body: JSON.stringify({ objectIds: [], values: [], autoRun: true }),
	});
	check(instantiate.ok, `instantiate returned ${instantiate.status}`);
	await Promise.race([done, timeout(60_000, 'cell output')]);
	socket.close();
	return outputs.at(-1);
}

async function main() {
	console.log(`Local end-to-end run against ${HUB_URL}`);
	const network = JSON.parse(docker('network', 'inspect', NET6))[0];
	check(network.EnableIPv4 === false && network.EnableIPv6 === true, 'private network is IPv6-only');
	ok(`private network ${NET6} is IPv6-only (${network.IPAM.Config.map((c) => c.Subnet).join(', ')})`);

	const project = await api(PROVISIONER, 'POST', '/projects', {
		name: 'Local proof',
		description: 'compute-fly',
	});
	for (const [subject, role] of [
		[EDITOR, 'editor'],
		[OTHER_EDITOR, 'editor'],
		[VIEWER, 'viewer'],
	]) {
		await api(PROVISIONER, 'POST', `/projects/${project.id}/members`, {
			email: `${subject}@identity.keyfleet.invalid`,
			role,
		});
	}
	ok(
		`${PROVISIONER} made the project, with ${EDITOR} and ${OTHER_EDITOR} as editors and ${VIEWER} as a viewer`,
	);

	await fileRevisions(project);

	const notebook = await api(EDITOR, 'POST', `/projects/${project.id}/notebooks`, {
		title: 'Relay proof',
		description: 'Runs one cell on a runner machine',
		code: NOTEBOOK,
	});
	ok(`notebook created (${notebook.id})`);

	const started = Date.now();
	const session = await api(EDITOR, 'POST', `/projects/${project.id}/notebooks/${notebook.id}/sessions`, {});
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

	const output = await runCells(session.sandbox_url);
	check(output.includes(`${MARKER} user=appuser`), 'cell ran as appuser');
	check(output.includes('token_in_env=False'), 'helper token not in the notebook environment');
	check(output.includes('token_readable_in_proc=[]'), 'helper token not readable through /proc');
	ok(`cell ran on the runner: ${output.replace(/<[^>]+>/g, '').replaceAll('&#x27;', "'").trim()}`);

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

	await api(EDITOR, 'DELETE', `/projects/${project.id}/notebooks/${notebook.id}/sessions/${session.session_id}`);
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

	await failedRuns(project);
	console.log('Local end-to-end run succeeded.');
}

/**
 * Each kind of file, written by both editors at once over the ETag both read,
 * as Keyfleet writes a file with If-Match: exactly one write lands, the other
 * answers 412 with the file's ETag now and changes nothing, a later write over
 * the old ETag is refused the same way, and one over the current ETag lands.
 * The two writes are separate requests by separate members, holding no lock
 * between them.
 */
async function fileRevisions(project) {
	const notebook = await api(EDITOR, 'POST', `/projects/${project.id}/notebooks`, {
		title: 'Revisions',
		description: 'Two editors write the same files',
		code: PLAIN,
	});
	const notebookPath = `/projects/${project.id}/notebooks/${notebook.id}`;
	const file = (path) => `${HUB_URL}/api/v1${notebookPath}/workspace/files?path=${encodeURIComponent(path)}`;
	const put = (subject, path, body, { etag, create = false } = {}) =>
		fetch(`${file(path)}&create=${create}`, {
			method: 'PUT',
			headers: {
				...as(subject),
				'content-type': 'application/octet-stream',
				...(etag === undefined ? {} : { 'if-match': etag }),
			},
			body,
		});
	const read = async (path) => {
		const response = await fetch(file(path), { headers: as(EDITOR) });
		check(response.ok, `${path}: read returned ${response.status}`);
		return { etag: response.headers.get('etag'), text: await response.text() };
	};
	const versions = async () =>
		(await api(EDITOR, 'GET', `${notebookPath}/versions?limit=100`)).items.length;
	const pyproject = (n) => `[project]\nname = "revisions"\nversion = "0.1.${n}"\n`;

	check((await put(EDITOR, 'notes/plan.md', 'plan 0', { create: true })).ok, 'notes/plan.md added');
	check((await put(EDITOR, 'pyproject.toml', pyproject(0))).ok, 'pyproject.toml written');

	for (const [path, edit] of [
		['notes/plan.md', (n) => `plan ${n}`],
		['notebook.py', (n) => PLAIN.replace('"ready"', `"edit ${n}"`)],
		['pyproject.toml', pyproject],
	]) {
		const source = path !== 'notes/plan.md';
		const before = await read(path);
		check(/^"[^"]+"$/.test(before.etag ?? ''), `${path}: the read answers a strong ETag (got ${before.etag})`);
		const versionsBefore = await versions();

		const sent = [
			[EDITOR, edit(1)],
			[OTHER_EDITOR, edit(2)],
		];
		const answers = await Promise.all(
			sent.map(([subject, body]) => put(subject, path, body, { etag: before.etag })),
		);
		const statuses = answers.map((answer) => answer.status).sort((a, b) => a - b);
		check(statuses.join() === '200,412', `${path}: one write of two lands (got ${statuses})`);
		const won = answers.findIndex((answer) => answer.status === 200);
		const lost = answers[1 - won];
		const after = await read(path);
		check(after.text === sent[won][1], `${path}: the file holds the write that landed`);
		check(answers[won].headers.get('etag') === after.etag, `${path}: the write answers the ETag it stored`);
		check(lost.headers.get('etag') === after.etag, `${path}: the refused write is told the ETag now`);
		check((await lost.json()).error?.code === 'PRECONDITION_FAILED', `${path}: refused as a failed precondition`);
		check(
			(await versions()) === versionsBefore + (source ? 1 : 0),
			`${path}: ${source ? 'one new version' : 'no new version'}, none from the refused write`,
		);

		const stale = await put(EDITOR, path, edit(3), { etag: before.etag });
		check(stale.status === 412, `${path}: a write over the old ETag is refused (got ${stale.status})`);
		check(stale.headers.get('etag') === after.etag, `${path}: and told the ETag now`);
		check((await read(path)).text === sent[won][1], `${path}: the refused write changed nothing`);

		const merged = await put(OTHER_EDITOR, path, edit(4), { etag: after.etag });
		check(merged.ok, `${path}: a write over the current ETag lands (got ${merged.status})`);
		const last = await read(path);
		check(last.text === edit(4) && merged.headers.get('etag') === last.etag, `${path}: the merged write is stored`);
		ok(`${path}: of two writes over the same ETag one landed; stale writes answered 412 with the ETag now and changed nothing`);
	}
}

/** A run of `notebookId` in a job of its own, started by the editor and read until it has finished. */
async function finishedRun(projectId, notebookId) {
	const notebookPath = `/projects/${projectId}/notebooks/${notebookId}`;
	const job = await api(EDITOR, 'POST', `${notebookPath}/jobs`, { name: 'Failure proof' });
	const jobPath = `${notebookPath}/jobs/${job.id}`;
	const queued = await api(EDITOR, 'POST', `${jobPath}/runs`, {});
	const runPath = `${jobPath}/runs/${queued.run_id}`;
	for (let attempt = 0; attempt < 180; attempt++) {
		const run = await api(EDITOR, 'GET', runPath);
		if (['succeeded', 'failed', 'timed_out', 'cancelled'].includes(run.status)) {
			return { jobPath, runPath, run };
		}
		await new Promise((resolve) => setTimeout(resolve, 1000));
	}
	throw new Error(`run ${queued.run_id} did not finish in 180 s`);
}

/** The hub container's own output, both streams. */
function hubOutput() {
	const logs = spawnSync('docker', ['logs', 'kf-nb-local-hub'], {
		encoding: 'utf8',
		maxBuffer: 64 * 1024 * 1024,
	});
	return `${logs.stdout}${logs.stderr}`;
}

async function failedRuns(project) {
	const planted = plantedValues();
	await api(PROVISIONER, 'POST', `/projects/${project.id}/integrations`, {
		kind: 'custom_env',
		name: 'planted',
		config: { vars: { KF_PLANTED: planted.env } },
	});
	ok('the project puts KF_PLANTED, a value made for this run, into its runs');

	const notebooks = {};
	for (const [name, description, code] of [
		['Python cap', 'Asks for a Python the hub does not run', PLAIN],
		['Cell raises', 'Its one cell raises', RAISES],
		['Planted values', 'Prints the planted values, then raises', plantingNotebook(planted)],
	]) {
		notebooks[name] = await api(EDITOR, 'POST', `/projects/${project.id}/notebooks`, {
			title: name,
			description,
			code,
		});
	}
	const upload = await fetch(
		`${HUB_URL}/api/v1/projects/${project.id}/notebooks/${notebooks['Python cap'].id}/workspace/files?path=pyproject.toml&create=false`,
		{
			method: 'PUT',
			headers: { ...as(EDITOR), 'content-type': 'application/octet-stream' },
			body: PYPROJECT,
		},
	);
	check(upload.ok, `pyproject.toml upload returned ${upload.status}`);
	ok('three notebooks: one asks for Python <3.13, one raises, one prints the planted values and raises');

	const expected = { 'Python cap': 'dependencies', 'Cell raises': 'export', 'Planted values': 'export' };
	const answers = [];
	for (const [name, notebook] of Object.entries(notebooks)) {
		const { jobPath, runPath, run } = await finishedRun(project.id, notebook.id);
		check(run.status === 'failed', `${name}: run failed (got ${run.status})`);
		const reads = {};
		for (const [who, subject] of [
			['starter', EDITOR],
			['other editor', OTHER_EDITOR],
			['viewer', VIEWER],
		]) {
			const listing = await api(subject, 'GET', `${jobPath}/runs?limit=10`);
			reads[who] = {
				run: await api(subject, 'GET', runPath),
				listed: listing.items.find((item) => item.run_id === run.run_id),
			};
		}
		const { failure } = reads.starter.run;
		check(
			failure?.stage === expected[name],
			`${name}: stopped at ${expected[name]} (got ${failure?.stage})`,
		);
		check(
			typeof failure.excerpt === 'string' && failure.excerpt.length > 0,
			`${name}: its starter, who wrote the notebook, reads an excerpt`,
		);
		const { excerpt: _excerpt, ...summary } = failure;
		for (const who of ['other editor', 'viewer']) {
			check(
				JSON.stringify(reads[who].run.failure) === JSON.stringify(summary),
				`${name}: the ${who} reads the same failure without the excerpt`,
			);
		}
		check(
			Object.values(reads).every(
				({ run: read, listed }) => JSON.stringify(listed.failure) === JSON.stringify(read.failure),
			),
			`${name}: each one's listing answers the same failure`,
		);
		const records = findFile(DATA_DIR, 'run.json').filter((path) => path.includes(run.run_id));
		check(records.length === 1, `${name}: one stored run record (found ${records.length})`);
		answers.push({ name, runPath, reads, record: readFileSync(records[0], 'utf8') });
		ok(`${name}: run ${run.run_id} failed at ${failure.stage}; only its starter reads the excerpt`);
	}

	// The raw logs hold every planted value, so the checks below look for something there.
	const plantedRun = answers.find(({ name }) => name === 'Planted values');
	const logs = await fetch(`${HUB_URL}/api/v1${plantedRun.runPath}/logs`, { headers: as(EDITOR) });
	check(logs.ok, `the editor reads the run's logs (got ${logs.status})`);
	const missing = planted.secrets.length - leaks(await logs.text(), planted.secrets).length;
	check(missing === 0, `the raw logs hold every planted value (${missing} missing)`);
	const viewerLogs = await fetch(`${HUB_URL}/api/v1${plantedRun.runPath}/logs`, {
		headers: as(VIEWER),
	});
	check(viewerLogs.status === 403, `the viewer is refused the logs (got ${viewerLogs.status})`);
	ok(`the raw logs hold all ${planted.secrets.length} planted values; the viewer is refused them`);

	// Named, never quoted: a value found here is a secret.
	const places = answers.flatMap(({ name, reads, record }) => [
		...Object.entries(reads).flatMap(([who, { run, listed }]) => [
			[`${name}, ${who}'s run`, JSON.stringify(run)],
			[`${name}, ${who}'s listing`, JSON.stringify(listed)],
		]),
		[`${name}, stored run record`, record],
	]);
	places.push(["the hub's output", hubOutput()]);
	const found = places.flatMap(([place, text]) =>
		leaks(text, planted.secrets).map((label) => `${label} in ${place}`),
	);
	check(found.length === 0, `planted values got through: ${found.join('; ')}`);
	ok(`no planted value is in any run answer, listing, stored run record or the hub's output`);

	for (const { name, reads } of answers) {
		for (const [who, { run }] of Object.entries(reads)) {
			console.log(`      ${name}, ${who}: ${JSON.stringify(run.failure)}`);
		}
	}
}

main().catch((error) => {
	console.error(`Local end-to-end run declined: ${error.message}`);
	process.exit(1);
});
