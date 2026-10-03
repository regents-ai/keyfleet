import { defineConfig } from 'vite-plus';

// One self-contained ES module: the hub loads it from a file path
// (MARIMOHUB_COMPUTE_LIBRARY=/etc/marimohub/fly-compute.mjs) with no
// node_modules beside it, so the marimohub helpers it uses are bundled in.
export default defineConfig({
	pack: {
		entry: ['src/index.ts'],
		platform: 'node',
		format: ['esm'],
		dts: false,
		deps: { alwaysBundle: [/^@marimo-hub\//] },
	},
});
