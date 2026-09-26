FROM docker.io/library/gcc@sha256:9ca91b05c7b07d2979f16413e8b2cd6ec8a7c80ffca4121ccab0aeba33f90460 AS native
FROM docker.io/hexpm/elixir@sha256:d21e3b8bab8bc2e8d51eb4bb03b1d73aad6b91c5c90b3ecc778eb5d136c2e3e6 AS elixir
FROM docker.io/library/node@sha256:5aea649bacdc35e8e20571131c4f3547477dfe66e677d45c005af6dbd1edfaa7 AS node
FROM docker.io/library/debian@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241 AS slim
FROM ghcr.io/astral-sh/uv@sha256:95f2aa1fe59274951cfe9b0cbc7972e879ff1004bc8945d130a32eb0dbd85945 AS uv

FROM native AS assets

ENV npm_config_nodedir=/usr/local
WORKDIR /workspace/platform
COPY --from=node /usr/local /usr/local
COPY platform/package.json platform/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund

# Dependencies are fetched from mix.lock, which holds every package's checksum,
# and native dependencies are built or fetched for the target architecture.
# The shared Regent libraries arrive in the context at the commits
# scripts/build-release-context.sh pins.
FROM native AS build

ENV MIX_ENV=prod
ENV REGENT_DEPS_ROOT=/workspace
ENV HOME=/root
WORKDIR /workspace/platform

COPY --from=elixir /usr/local /usr/local
COPY --from=assets /usr/local/bin/node /usr/local/bin/node
COPY --from=assets /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm

RUN mix local.hex --force && mix local.rebar --force
COPY platform/mix.exs platform/mix.lock ./
COPY elixir-utils/privy /workspace/elixir-utils/privy
COPY elixir-utils/agent_access /workspace/elixir-utils/agent_access
COPY elixir-utils/siwa/siwa-elixir/apps/siwa /workspace/elixir-utils/siwa/siwa-elixir/apps/siwa
COPY regents/identity /workspace/regents/identity
COPY design-system/regent_ui /workspace/design-system/regent_ui
COPY platform/config config
RUN mix deps.get --only prod --check-locked && mix deps.compile

COPY platform/lib lib
COPY platform/priv priv
COPY platform/rel rel
COPY platform/assets assets
COPY platform/contracts contracts
COPY --from=assets /workspace/platform/node_modules node_modules
RUN mix compile && mix assets.deploy && mix release

# The graph host: a standalone CPython and the packages uv.lock pins, installed
# from the sealed Python supply in the context without reaching the network.
# The builder base is used for its git, which uv needs to check the pinned
# ActiveGraph commit out of the supply's cache. The interpreter is a
# self-contained build, so the virtual environment runs on the slim base as is.
FROM native AS graph-host

ENV UV_OFFLINE=1 \
  UV_CACHE_DIR=/workspace/uv-cache \
  UV_PYTHON_CACHE_DIR=/workspace/python-cache \
  UV_PYTHON_INSTALL_DIR=/opt/python \
  UV_PYTHON_PREFERENCE=only-managed \
  UV_PROJECT_ENVIRONMENT=/opt/graph_host/.venv \
  UV_COMPILE_BYTECODE=1 \
  UV_LINK_MODE=copy
WORKDIR /workspace/platform/graph_host

COPY --from=uv /uv /usr/local/bin/uv
COPY uv-cache /workspace/uv-cache
COPY python-cache /workspace/python-cache
COPY platform/graph_host/pyproject.toml platform/graph_host/uv.lock platform/graph_host/.python-version ./
COPY platform/graph_host/src src
RUN uv python install && uv sync --frozen --no-dev --no-editable

# The release carries its own ERTS, so the runtime image needs no Elixir and no
# Erlang install. Two things it does still need are absent from the slim base:
# the OpenSSL library the crypto NIF links against, and the CA bundle outbound
# TLS verifies against. Both are lifted from the builder image, which is only
# sound while the two images are the same Debian release, so this stage asserts
# that first and the build stops here if a base ever moves. Lifting to a fixed
# path also keeps the runtime stage from naming a library directory that
# differs per architecture.
FROM elixir AS runtime-support

COPY --from=slim /etc/os-release /slim-os-release
RUN set -eu; \
  builder="$(. /etc/os-release; printf '%s' "$VERSION_CODENAME")"; \
  runtime="$(. /slim-os-release; printf '%s' "$VERSION_CODENAME")"; \
  if [ "$builder" != "$runtime" ]; then \
    echo "runtime base is Debian $runtime but the builder is Debian $builder;" \
      "the OpenSSL library and CA bundle may not be lifted across releases" >&2; \
    exit 1; \
  fi; \
  mkdir /runtime-support; \
  cp /usr/lib/*-linux-gnu/libcrypto.so.3 /runtime-support/; \
  cp /etc/ssl/certs/ca-certificates.crt /runtime-support/

FROM slim AS app

# The builder image sets this and the slim base does not. Without it the VM
# runs with latin1 name encoding, which Elixir warns about at boot.
ENV LANG=C.UTF-8
ENV HOME=/app
WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends coreutils \
  && rm -rf /var/lib/apt/lists/*

COPY --from=runtime-support /runtime-support/libcrypto.so.3 /usr/lib/
COPY --from=runtime-support /runtime-support/ca-certificates.crt /etc/ssl/certs/

RUN groupadd --system --gid 1001 app \
  && useradd --system --uid 1001 --gid app --home-dir /app app

COPY --from=build --chown=app:app /workspace/platform/_build/prod/rel/keyfleet ./

# The graph host stays root-owned: the app runs it and never changes it.
COPY --from=graph-host /opt/python /opt/python
COPY --from=graph-host /opt/graph_host/.venv /opt/graph_host/.venv
COPY platform/graph_host/third_party /opt/graph_host/third_party

USER app

EXPOSE 4000

CMD ["/app/bin/keyfleet", "start"]
