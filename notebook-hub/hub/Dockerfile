# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89
# The hub image: marimohub's own server image built from source at the pinned
# commit (apps/server/Dockerfile), with the Fly compute library added at
# /etc/marimohub/fly-compute.mjs. Build context: notebook-hub/.

# --- build stage: marimohub at the pin, plus compute-fly as a workspace package ---
FROM node:24.22.1-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205 AS build
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
# Deleted-notebook cleanup works on 16 notebooks at a time, so a project with
# thousands of notebooks finishes inside the maintenance deadline.
COPY marimohub/sweep-concurrency.patch /tmp/sweep-concurrency.patch
RUN git apply /tmp/sweep-concurrency.patch
# A read the store cancels with 408 (Tigris RequestCanceled) is retried like any
# other brief store failure. Writes are not retried after a 408, though the storage
# client still retries them after server errors and timeouts.
COPY marimohub/storage-read-retry.patch /tmp/storage-read-retry.patch
RUN git apply /tmp/storage-read-retry.patch
# The app pool sweep works on 16 pools at a time and passes over a deleted
# notebook's empty pool, so a purged project's thousands of pools finish inside
# both loop deadlines.
COPY marimohub/app-pool-sweep.patch /tmp/app-pool-sweep.patch
RUN git apply /tmp/app-pool-sweep.patch
# A store call that fails names its call and object key in its log line, and the
# storage client's own retries wait 1, 2, 4 and 8 seconds between five tries.
COPY marimohub/storage-calls.patch /tmp/storage-calls.patch
RUN git apply /tmp/storage-calls.patch
# A lease write that landed but was retried by the storage client and refused still
# wins (the lease is read back for this attempt's own holder and expiry), and a loop
# refused its lease logs who holds it and until when, so a lockout is never silent.
COPY marimohub/maintenance-lock-landed.patch /tmp/maintenance-lock-landed.patch
RUN git apply /tmp/maintenance-lock-landed.patch
# Each notebook's upload and thumbnail cleanup runs hourly under its own lease
# instead of in every five-minute maintenance cycle, and reads thumbnail.json only
# when an image is over a day old.
COPY marimohub/notebook-prune-hourly.patch /tmp/notebook-prune-hourly.patch
RUN git apply /tmp/notebook-prune-hourly.patch
# A super admin lists every notebook machine the hub holds a record of, sessions and
# job runs alike, with when each started and ended; Keyfleet reads it every hour to
# count each fleet's notebook hours.
COPY marimohub/notebook-machines.patch /tmp/notebook-machines.patch
RUN git apply /tmp/notebook-machines.patch
# A project's notebook list takes updated_after, so Keyfleet's hourly read for its
# Atlas asks only for the notebooks saved since its last read.
COPY marimohub/notebooks-updated-after.patch /tmp/notebooks-updated-after.patch
RUN git apply /tmp/notebooks-updated-after.patch
COPY compute-fly packages/compute-fly
RUN pnpm install --frozen-lockfile
RUN pnpm exec vp run --filter @marimo-hub/web --filter @marimo-hub/server build
# marimohub's catalog tests, with the three catalog-commit.patch adds and the
# maintenance-lock-landed.patch lease tests.
RUN cd packages/core && pnpm exec vp test run src/services/catalog/
# The notebook and thumbnail tests, with the sweep-concurrency.patch add and the
# notebook-prune-hourly.patch adds, and the storage client's tests, with the
# storage-read-retry.patch adds.
RUN cd packages/core && pnpm exec vp test run src/services/content/NotebookService.test.ts src/services/content/ThumbnailService.test.ts
RUN cd packages/storage-s3 && pnpm exec vp test run
# The server's loop and startup tests, with the lease and hourly prune adds, and the
# Cloudflare example's tests for its lease calls.
RUN cd apps/server && pnpm exec vp test run src/backgroundLoops.test.ts src/cron.test.ts src/cron.tracing.test.ts src/bootstrap.test.ts
RUN cd examples/cloudflare-worker && pnpm exec vp test run src/index.test.ts
# The app pool tests, with the app-pool-sweep.patch add, the notebook-machines.patch
# route tests and the notebooks-updated-after.patch notebook route tests, with the API
# description both add to.
RUN cd packages/api && pnpm exec vp test run src/routes/sessions.appPool.test.ts src/routes/admin.machines.test.ts src/routes/notebooks.test.ts src/openapi.spec.test.ts
RUN cd packages/compute-fly && pnpm exec vp pack

# --- runtime: as marimohub's server image, plus the compute library ---
FROM node:24.22.1-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205 AS runtime
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
