# gcc:15.2.0-bookworm
FROM docker.io/library/gcc@sha256:9ca91b05c7b07d2979f16413e8b2cd6ec8a7c80ffca4121ccab0aeba33f90460 AS native
# hexpm/elixir:1.20.4-erlang-29.1.2-debian-bookworm-20261020-slim
FROM docker.io/hexpm/elixir@sha256:11ab449084960993491cdc3493be292464c5a63e8f753ed2afe351486471b69a AS elixir
# node:26.12.0-bookworm-slim
FROM docker.io/library/node@sha256:298992629d69bbd5b2b03ad57094d8e4fcb3a8eeb7c4e25d29de656519568913 AS node
# debian:bookworm-20261020-slim
FROM docker.io/library/debian@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8 AS slim
FROM ghcr.io/astral-sh/uv@sha256:95f2aa1fe59274951cfe9b0cbc7972e879ff1004bc8945d130a32eb0dbd85945 AS uv

FROM native AS assets

ENV npm_config_nodedir=/usr/local
WORKDIR /workspace/platform
COPY --from=node /usr/local /usr/local
COPY platform/package.json platform/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund

# Dependencies are fetched from mix.lock, which holds every package's checksum,
# and native dependencies are built or fetched for the target architecture.
# Shared Regent libraries arrive here from GitHub at the commits mix.lock pins.
FROM native AS build

ENV MIX_ENV=prod
ENV HOME=/root
WORKDIR /workspace/platform

COPY --from=elixir /usr/local /usr/local
COPY --from=assets /usr/local/bin/node /usr/local/bin/node
COPY --from=assets /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm

# Hex and rebar3 at fixed versions; rebar3 is the build Mix itself would pick
# for this Elixir and OTP, checked against its published SHA-512.
RUN mix local.hex 2.5.1 --force && \
  mix local.rebar rebar3 https://builds.hex.pm/installs/1.18.4/rebar3-3.25.1-otp-28 \
    --sha512 992fd755b7926fae455e5e07d9d195f4d3e7f181609eed1b9cabfe548624df10d148cd4b59bda40bebb185d3d68f9a9fd68a70b294101c8ad9cf0fadcc683d24 \
    --force

# Layers run from what changes least to what changes most, so an ordinary
# release rebuilds only the application's own files. The page packages change
# only with package-lock.json, and copying them takes over a minute, so they
# come first. The dependencies read only the compile-time configuration;
# runtime.exs joins the application's own files.
COPY --from=assets /workspace/platform/node_modules node_modules
# GitHub's download redirect sends headers longer than Erlang's HTTP client
# accepts, so rustler_precompiled cannot fetch prebuilt native code from GitHub.
# mdex_native uses its maker's mirror (config/config.exs); ex_keccak and
# ex_secp256k1 publish only on GitHub, so curl fetches the files this build
# uses into the shared cache first, where rustler_precompiled checks each one
# against the package's own checksums before using it. The versions follow
# mix.lock. Remove this when GitHub or rustler_precompiled fixes the limit.
ENV RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=/root/rustler_precompiled
RUN mkdir -p /root/rustler_precompiled && cd /root/rustler_precompiled && \
  curl --fail --silent --show-error --location --remote-name \
    https://github.com/exWeb3/ex_keccak/releases/download/v0.7.8/libexkeccak-v0.7.8-nif-2.16-x86_64-unknown-linux-gnu.so.tar.gz && \
  curl --fail --silent --show-error --location --remote-name \
    https://github.com/ayrat555/ex_secp256k1/releases/download/v0.8.0/libex_secp256k1-v0.8.0-nif-2.16-x86_64-unknown-linux-gnu.so.tar.gz
COPY platform/mix.exs platform/mix.lock ./
COPY platform/config/config.exs platform/config/prod.exs config/
RUN mix deps.get --only prod --check-locked && mix deps.compile

COPY platform/config/runtime.exs config/
COPY platform/lib lib
COPY platform/priv priv
COPY platform/rel rel
COPY platform/assets assets
COPY platform/contracts contracts
COPY cli/commands.json /workspace/cli/commands.json
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

# The site machine; fly.toml starts the graph machine with /app/bin/graph.
CMD ["/app/bin/site"]
