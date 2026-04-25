# syntax=docker/dockerfile:1.7

FROM node:24-bookworm-slim AS build

WORKDIR /app

RUN corepack enable && corepack prepare pnpm@10.6.0 --activate

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.json tsconfig.base.json ./
COPY packages ./packages
COPY runtime-apps/relay-server ./runtime-apps/relay-server

RUN pnpm install --frozen-lockfile
RUN pnpm --filter @kodexlink/protocol build \
  && pnpm --filter @kodexlink/shared build \
  && pnpm --filter @kodexlink/schemas build \
  && pnpm --filter @kodexlink/relay-server build
RUN pnpm prune --prod

FROM node:24-bookworm-slim AS runtime

ENV NODE_ENV=production
ENV CODEX_MOBILE_LOG_DIR=/app/.runtime/logs
WORKDIR /app

COPY --from=build /app /app

RUN mkdir -p /app/.runtime/logs && chown -R node:node /app/.runtime

USER node

CMD ["node", "runtime-apps/relay-server/dist/server.js", "serve"]
