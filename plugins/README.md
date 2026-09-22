# Plugins

This folder is the home for runtime plugin packages: anything an agent runtime
installs on its own rather than through the `keyfleet` command. None exist
yet.

When one is needed, put it at `plugins/<runtime>/` with its own README,
manifest and checks, and add a root Make target for it.
