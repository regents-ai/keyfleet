import Config

config :keyfleet, KeyfleetWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Every request reaches production through Fly's proxy, which sets Fly-Client-IP.
config :keyfleet, :behind_fly_proxy, true

# The graph files sit on the machine's volume; the image carries the host.
config :keyfleet, :graph,
  enabled: true,
  data_dir: "/data/graph",
  python: "/opt/graph_host/.venv/bin/python"

# Requests and outcomes are logged; database queries and debug detail are not.
config :logger, level: :info
