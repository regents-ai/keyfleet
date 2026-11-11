import Config

# Every page is served over HTTPS and says so with Strict-Transport-Security.
# Fly's proxy ends TLS and says so in `x-forwarded-proto`, which `:rewrite_on`
# reads. Fly's health check reaches the machine directly over plain HTTP with
# `Host: localhost` (fly.toml), and is answered rather than redirected, so
# `:exclude` sits inside `:force_ssl`, where Plug.SSL reads it. `:force_ssl` is
# read when the endpoint compiles, so it lives here and not in runtime.exs.
config :keyfleet, KeyfleetWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: ["localhost", "127.0.0.1"]]

# Public requests reach production through Fly's proxy, which sets Fly-Client-IP on
# its IPv4 connections (KeyfleetWeb.ClientAddress).
config :keyfleet, :behind_fly_proxy, true

# The private port fly.toml names under [metrics]; Fly routes no public traffic to it.
config :keyfleet, :metrics_listener, ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 9091

# The graph files sit on the graph machine's volume; the image carries the
# host. Only the graph machine runs the writers (Keyfleet.Application), so the
# site machine leaves the graph off.
config :keyfleet, :graph,
  data_dir: "/data/graph",
  python: "/opt/graph_host/.venv/bin/python"

# Requests and outcomes are logged; database queries and debug detail are not.
config :logger, level: :info

# The visit lines (KeyfleetWeb.VisitLog) say what each request and page did,
# by route. Phoenix's own request and connection lines would repeat them with
# each raw path and its parameters, so they are off.
config :phoenix, :logger, false
