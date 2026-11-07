# syntax=docker/dockerfile:1
# The Achtung server. Node runs the TypeScript sources directly (type stripping), so the
# image holds the sources and production dependencies only; there is no build step.
# Keep the Node version in sync with .tool-versions.
ARG NODE_IMAGE=node:24.21.0-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1

FROM ${NODE_IMAGE} AS dependencies
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY server/package.json server/
# --ignore-scripts: the only script is the root `prepare` (git hooks), useless here.
RUN pnpm install --frozen-lockfile --prod --ignore-scripts --filter @achtung/server

FROM ${NODE_IMAGE}
ARG VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_DATE
LABEL org.opencontainers.image.title="achtung" \
      org.opencontainers.image.description="Self-hosted alert inbox server" \
      org.opencontainers.image.source="https://github.com/stibi/achtung" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}"
ENV NODE_ENV=production
WORKDIR /app
COPY --from=dependencies /app/node_modules node_modules
COPY --from=dependencies /app/server/node_modules server/node_modules
COPY server/package.json server/
COPY server/src server/src
COPY server/drizzle server/drizzle
WORKDIR /app/server
USER node
EXPOSE 8080
CMD ["node", "src/main.ts"]
