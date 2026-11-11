import { mkdtempSync, realpathSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { SandboxId } from '@marimo-hub/core/ids';
import manifest from '../src/index';
import type { FlyCompute } from '../src/index';
import { COMPUTE_CONTEXT, FlyWorld, hubEnv, localRunner } from './world';

const ID = 'sb-aaaaaaaaaaaaaaaa' as SandboxId;

// Real files and the real bounded-read script, run by a helper that executes
// commands on this computer. realpath: macOS tmpdir sits behind a symlink.
const dir = realpathSync(mkdtempSync(join(tmpdir(), 'compute-fly-bounded-')));
writeFileSync(join(dir, 'ten.txt'), '0123456789');
writeFileSync(join(dir, 'binary.bin'), Buffer.from([0, 255, 1, 254]));
symlinkSync(join(dir, 'ten.txt'), join(dir, 'link.txt'));

let world: FlyWorld;

function instance() {
	const compute = manifest.create({
		env: hubEnv(),
		errors: { preconditionFailed: (message?: string) => new Error(message) },
		compute: { ...COMPUTE_CONTEXT, sessionIdleTimeoutMs: 1_800_000 },
	} as never) as FlyCompute;
	return compute.create(ID);
}

beforeEach(() => {
	world = new FlyWorld();
	world.runner = localRunner;
	vi.stubGlobal('fetch', vi.fn(world.fetch));
});

afterEach(() => {
	vi.unstubAllGlobals();
});

describe('readFileBounded', () => {
	it('reads a file exactly at the limit', async () => {
		const result = await instance().readFileBounded!(join(dir, 'ten.txt'), {
			maxBytes: 10,
			timeoutMs: 10_000,
		});
		expect(result).toEqual({
			success: true,
			content: Buffer.from('0123456789').toString('base64'),
			encoding: 'base64',
		});
	});

	it('reads binary content unchanged', async () => {
		const result = await instance().readFileBounded!(join(dir, 'binary.bin'), {
			maxBytes: 4,
			timeoutMs: 10_000,
		});
		expect(result.success && Buffer.from(result.content, 'base64')).toEqual(
			Buffer.from([0, 255, 1, 254]),
		);
	});

	it('refuses a file one byte over the limit', async () => {
		expect(
			await instance().readFileBounded!(join(dir, 'ten.txt'), { maxBytes: 9, timeoutMs: 10_000 }),
		).toEqual({
			success: false,
			content: '',
			error: {
				code: 'READ_FAILED',
				reason: 'size_limit',
				exec_code: 'COMMAND_FAILED',
				stdout_bytes: 0,
				stderr: 'MARIMOHUB_BOUNDED_READ:size_limit\n',
			},
		});
	});

	it('refuses a symlink, even to a readable file', async () => {
		expect(
			(
				await instance().readFileBounded!(join(dir, 'link.txt'), {
					maxBytes: 100,
					timeoutMs: 10_000,
				})
			).success,
		).toBe(false);
	});

	it('refuses a directory and a missing file', async () => {
		const sandbox = instance();
		expect(
			(await sandbox.readFileBounded!(dir, { maxBytes: 100, timeoutMs: 10_000 })).success,
		).toBe(false);
		expect(
			(await sandbox.readFileBounded!(join(dir, 'absent'), { maxBytes: 100, timeoutMs: 10_000 }))
				.success,
		).toBe(false);
	});

	it.each([
		{ maxBytes: -1, timeoutMs: 1_000 },
		{ maxBytes: 1.5, timeoutMs: 1_000 },
		{ maxBytes: 10, timeoutMs: 0 },
		{ maxBytes: 10, timeoutMs: 2 ** 31 },
	])('refuses an invalid budget %o without running anything', async (budget) => {
		expect((await instance().readFileBounded!(join(dir, 'ten.txt'), budget)).success).toBe(false);
		expect(world.requests).toEqual([]);
	});

	it('cancels a helper reply that exceeds the wire budget', async () => {
		const sandbox = instance();
		await sandbox.ready!();
		const cancel = vi.fn();
		vi.mocked(fetch).mockResolvedValueOnce(
			new Response(
				new ReadableStream({
					start(controller) {
						controller.enqueue(new Uint8Array(5000));
					},
					cancel,
				}),
			),
		);
		expect(
			(await sandbox.readFileBounded!(join(dir, 'ten.txt'), { maxBytes: 2, timeoutMs: 100 }))
				.success,
		).toBe(false);
		expect(cancel).toHaveBeenCalledOnce();
	});
});
