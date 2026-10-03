#!/bin/sh
# Start of one runner machine: the IPv6 relay for the notebook kernel, then the
# helper, capped at the machine's lifetime. When the helper stops, the machine
# stops and Fly removes it (auto_destroy). Root-run programs are named by
# absolute path: the notebook user owns the Python environment on PATH.
set -eu
: "${MARIMOHUB_AGENT_TOKEN:?MARIMOHUB_AGENT_TOKEN is required}"
: "${MARIMOHUB_RUNNER_MAX_LIFETIME_SECONDS:?MARIMOHUB_RUNNER_MAX_LIFETIME_SECONDS is required}"

# marimo listens on IPv4 only and Fly's private network is IPv6, so relay the
# kernel port across. The relay runs as nobody and never holds the helper token.
/usr/bin/env -u MARIMOHUB_AGENT_TOKEN \
  /usr/bin/setpriv --reuid=nobody --regid=nogroup --clear-groups --no-new-privs \
  /usr/bin/socat TCP6-LISTEN:2718,ipv6only=1,fork,reuseaddr TCP4:127.0.0.1:2718 &

exec /usr/bin/timeout --kill-after=30 "${MARIMOHUB_RUNNER_MAX_LIFETIME_SECONDS}" \
  /usr/local/bin/python3 -I /opt/runner/helper.py
