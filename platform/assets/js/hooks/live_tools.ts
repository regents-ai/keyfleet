import type {Hook} from "../hook_composition"

// Signed agent operations are registered from public_tools.ts. This hook remains
// on human pages for compatibility, but never exposes owner-session actions.
export const LiveTools: Hook = {}
