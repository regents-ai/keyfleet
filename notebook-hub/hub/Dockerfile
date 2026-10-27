# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89
# The hub image: marimohub's own server image built from source at the pinned
# commit (apps/server/Dockerfile), with the Fly compute library added at
# /etc/marimohub/fly-compute.mjs. Build context: notebook-hub/.

# --- build stage: marimohub at the pin, plus compute-fly as a workspace package ---
FROM node:24-slim@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d AS build
ENV CI=true
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN corepack enable
# Both come from marimohub/pin.env (scripts/build-images.sh passes them).
ARG MARIMOHUB_REPO
ARG MARIMOHUB_COMMIT
WORKDIR /repo
RUN git init --quiet \
 && git remote add origin "$MARIMOHUB_REPO" \
 && git fetch --quiet --depth 1 origin "$MARIMOHUB_COMMIT" \
 && git checkout --quiet --detach FETCH_HEAD
COPY marimohub/pnpm-lock.patch /tmp/pnpm-lock.patch
RUN git apply /tmp/pnpm-lock.patch
# A catalog write that lands but is retried by the storage client keeps its snapshot
# (the catalog is read before deleting); without it the hub could delete the snapshot
# its own catalog names.
COPY marimohub/catalog-commit.patch /tmp/catalog-commit.patch
RUN git apply /tmp/catalog-commit.patch
# A failed storage call's log line carries the store's HTTP status, request ids and
# tries, so a refused write can be traced with the store.
COPY marimohub/storage-errors.patch /tmp/storage-errors.patch
RUN git apply /tmp/storage-errors.patch
COPY compute-fly packages/compute-fly
RUN pnpm install --frozen-lockfile
RUN pnpm exec vp run --filter @marimo-hub/web --filter @marimo-hub/server build
# marimohub's catalog tests, with the three catalog-commit.patch adds.
RUN cd packages/core && pnpm exec vp test run src/services/catalog/
RUN cd packages/compute-fly && pnpm exec vp pack

# --- runtime: as marimohub's server image, plus the compute library ---
FROM node:24-slim@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    PORT=3000 \
    MARIMOHUB_STATIC_ROOT=./public \
    MARIMOHUB_COMPUTE_BACKEND=library \
    MARIMOHUB_COMPUTE_LIBRARY=/etc/marimohub/fly-compute.mjs \
    MARIMOHUB_SANDBOX_EXPOSURE=proxy
ARG MARIMOHUB_VERSION=dev
ARG MARIMOHUB_IMAGE
ENV MARIMOHUB_VERSION=$MARIMOHUB_VERSION \
    MARIMOHUB_IMAGE=$MARIMOHUB_IMAGE
COPY --from=build /repo/apps/server/dist ./dist
COPY --from=build /repo/packages/web/dist ./public
COPY --from=build /repo/packages/compute-fly/dist/index.mjs /etc/marimohub/fly-compute.mjs
EXPOSE 3000
CMD ["node", "dist/index.mjs"]
