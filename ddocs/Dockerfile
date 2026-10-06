# The dDocs server (npm @fileverse/api), unchanged, pinned by package-lock.json.
FROM node:22-bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-bookworm-slim
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
EXPOSE 8001
CMD ["node", "node_modules/@fileverse/api/dist/index.js"]
