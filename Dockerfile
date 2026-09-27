# Swarm Sentinel control plane image (server/deploy/README.md runbook).
#
# Build (from the repo root — the context must be the repo root):
#   docker build -f server/deploy/docker/Dockerfile -t swarm-sentinel-control-plane:local .
#
# Loopback/proxy posture (same as the systemd + nginx deployment): server/main.ts binds
# 127.0.0.1:8787 unconditionally — this container is never reachable directly. The proxy
# sidecar (Dockerfile.proxy) shares the network namespace and is the only ingress.
#
# Zero runtime npm dependencies (package.json ships devDependencies only) — Bun runs TS directly.
ARG BUN_TAG=1.2-alpine
FROM oven/bun:${BUN_TAG}

WORKDIR /app

COPY package.json ./
COPY src ./src
COPY server ./server

# Contract #5 deployment data paths: corpus at .../corpus, triggers at .../triggers.
# SENTINEL_DATA_DIR is the trigger/telemetry JSONL store dir (see createControlPlane docs);
# pointing it at the triggers contract path keeps every persisted byte under a contract path.
# Pre-created + owned by uid 1000 so named volumes (compose) and fsGroup'd volumes (Kubernetes,
# chart securityContext: runAsUser/runAsGroup/fsGroup 1000) both come up writable.
ENV SENTINEL_DATA_DIR=/var/lib/swarm-sentinel/triggers \
    SENTINEL_CORPUS_DIR=/var/lib/swarm-sentinel/corpus \
    PORT=8787 \
    HOME=/tmp
RUN mkdir -p /var/lib/swarm-sentinel/corpus /var/lib/swarm-sentinel/triggers \
 && chown -R 1000:1000 /var/lib/swarm-sentinel /app

# Unprivileged, matching the systemd unit's NoNewPrivileges/DynamicUser posture.
USER 1000:1000

EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -qO- http://127.0.0.1:8787/healthz >/dev/null 2>&1 || exit 1

CMD ["bun", "server/main.ts"]
