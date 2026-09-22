# syntax=docker/dockerfile:1.7
# Shared Dockerfile for all Node services. Build with:
#   docker build -f services/Dockerfile --build-arg SERVICE=orders -t orders services
ARG NODE_VERSION=20

FROM node:${NODE_VERSION}-alpine AS deps
ARG SERVICE
WORKDIR /app
COPY ${SERVICE}/package*.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev --ignore-scripts

FROM node:${NODE_VERSION}-alpine AS runtime
ARG SERVICE
ARG APP_VERSION=dev
ENV NODE_ENV=production \
    PORT=8080 \
    APP_VERSION=${APP_VERSION} \
    NODE_OPTIONS=--enable-source-maps
WORKDIR /app
RUN addgroup -S app && adduser -S -G app -u 10001 app
COPY --from=deps --chown=app:app /app/node_modules ./node_modules
COPY --chown=app:app ${SERVICE}/package.json ./
COPY --chown=app:app ${SERVICE}/src ./src
USER 10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
CMD ["node", "src/server.js"]
