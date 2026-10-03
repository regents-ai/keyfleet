import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { loadAdapterLibraries } from '@marimo-hub/config';
import type { SandboxId } from '@marimo-hub/core/ids';
import { hubEnv } from './world';

// The bundle the hub image ships at /etc/marimohub/fly-compute.mjs (built by `vp pack`).
const bundle = fileURLToPath(new URL('../dist/index.mjs', import.meta.url));

describe('marimohub adapter loader', () => {
	it('accepts the built bundle as a compute library', async () => {
		expect(existsSync(bundle), 'build compute-fly before testing').toBe(true);
		const { compute } = await loadAdapterLibraries({
			...hubEnv(),
			MARIMOHUB_COMPUTE_BACKEND: 'library',
			MARIMOHUB_COMPUTE_LIBRARY: bundle,
		});
		expect(compute?.capabilities).toEqual({ multiPort: false, computeProfiles: true });
		// The loader checks the first sandbox's methods when it is created.
		const sandbox = compute!.create('sb-aaaaaaaaaaaaaaaa' as SandboxId);
		expect(sandbox.supportsBucketMount).toBe(false);
		expect(typeof sandbox.readFileBounded).toBe('function');
	});

	it('reports a missing setting as a hub configuration error', async () => {
		await expect(
			loadAdapterLibraries({
				...hubEnv({ MARIMOHUB_COMPUTE_FLY_OWNER: undefined }),
				MARIMOHUB_COMPUTE_BACKEND: 'library',
				MARIMOHUB_COMPUTE_LIBRARY: bundle,
			}),
		).rejects.toThrow(/MARIMOHUB_COMPUTE_FLY_OWNER is required/);
	});
});
