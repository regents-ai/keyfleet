# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89
# The key-art service image. Build context: the repository root
#   docker build -f key-art/Dockerfile .
# The drawing page is bundled from the site's own card code and packages
# (platform/assets/js/key_card, platform/package-lock.json), so pictures and the
# site draw with the same code at the same versions.

FROM node:24-slim@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d AS build
WORKDIR /repo/platform
COPY platform/package.json platform/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund
COPY platform/assets/js/key_card assets/js/key_card
COPY platform/priv/trait_tables priv/trait_tables
WORKDIR /repo/key-art
COPY key-art/package.json key-art/package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY key-art/page page
COPY key-art/build.mjs ./
RUN node build.mjs

# Playwright's own image carries the Chromium that playwright-core 1.61.1 drives.
FROM mcr.microsoft.com/playwright:v1.61.1-noble@sha256:5b8f294aff9041b7191c34a4bab3ac270157a28774d4b0660e9743297b697e48
WORKDIR /app
ENV NODE_ENV=production \
    PORT=8080
COPY key-art/package.json key-art/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund
COPY key-art/server.mjs ./
COPY --from=build /repo/key-art/dist dist
USER pwuser
EXPOSE 8080
CMD ["node", "server.mjs"]
