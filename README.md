# Deploying the control plane

Two paths, same process posture (loopback-only Bun + nginx ingress):

1. **VPS** (this section) — the existing RackNerd Debian box (2GB/1-core) that already runs nginx
   + laincore.com + wire-server. The control plane is a third co-tenant: Bun on `127.0.0.1:8787`,
   proxied by a new nginx vhost.
2. **Private/enterprise containers** — Docker Compose and Helm with customer-owned JEV keys, a
   private corpus at the contract paths, and an explicit no-contribution default. See
   [Docker & Helm](#docker--helm-private-enterprise-deployment) below.

## One-time setup (on the VPS)

```bash
# 1. Bun (pinned; engines.node>=22 territory, Bun bundles its own runtime)
curl -fsSL https://bun.sh/install | bash

# 2. Service user + data dir + secrets
useradd --system --home /opt/swarm-sentinel --shell /usr/sbin/nologin sentinel
mkdir -p /opt/swarm-sentinel /var/lib/swarm-sentinel /etc/swarm-sentinel
chown sentinel:sentinel /var/lib/swarm-sentinel

# 3. Secrets (env file consumed by the systemd unit)
openssl rand -base64 32   # → CONTROL_PLANE_ENC_KEY
openssl rand -hex 24      # → each ss_…-style issued token (store the value, share once)
cat > /etc/swarm-sentinel/env <<'EOF'
CONTROL_PLANE_ENC_KEY=<paste>
SENTINEL_TOKENS=<token1>,<token2>
# JEV_ENDPOINT=https://<typesafe-endpoint>   # optional: enables live adjudication
EOF
chown root:sentinel /etc/swarm-sentinel/env && chmod 640 /etc/swarm-sentinel/env

# 4. Swapfile insurance (§6) — skip if `swapon --show` already lists one
fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
sysctl vm.swappiness=10
```

## Code + service

```bash
# From the workstation: ship the repo (same convention as ServerPortal deploys — tar over SSH).
# Minimum set: package.json, tsconfig.json, src/, server/, bench/programs/  (dist/ is not required:
# Bun runs TS directly; bench/programs/ carries the paid judge program served by /v1/sieve/program)
#   → /opt/swarm-sentinel/

# On the VPS:
cp server/deploy/swarm-sentinel-control-plane.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now swarm-sentinel-control-plane
journalctl -u swarm-sentinel-control-plane -f     # expect "listening on 127.0.0.1:8787"
```

## Nginx vhost + TLS

```bash
cp server/deploy/nginx-api.conf /etc/nginx/sites-available/api.laincore.com
ln -s /etc/nginx/sites-available/api.laincore.com /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
certbot --nginx -d api.laincore.com        # issues + installs the cert, adds the 443 block
```

Existing vhosts (laincore.com, /api/wire/*) are untouched.

## Verify (no numbers published until drilled)

```bash
curl -s https://api.laincore.com/healthz | jq          # ok:true + counters
curl -s -X POST https://api.laincore.com/v1/inspect \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"command":"rm -rf /"}' | jq                     # action:"block", layer:"floor"
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://api.laincore.com/v1/inspect \
  -H "Authorization: Bearer wrong" -d '{}'             # 401
```

Then run the two drills from CONTROL_PLANE.md §7 (load drill: 58-case gauntlet replay at 500 req/s;
degradation drill: kill JEV upstream mid-run → ambiguous fails closed, floor keeps blocking).

## Upgrade path

```bash
systemctl restart swarm-sentinel-control-plane   # drain → fresh process; 502 blip at worst
```

Later hardening (optional, zero origin change): orange-proxy `api.laincore.com` through Cloudflare.

## Docker & Helm (private enterprise deployment)

The same control plane ships as containers for private/enterprise installs (contract #5):
**customer-owned JEV keys**, a **private corpus** at `/var/lib/swarm-sentinel/corpus` and trigger
store at `/var/lib/swarm-sentinel/triggers`, and an explicit **no-contribution** default —
enterprise data never feeds the shared corpus.

Tree: `server/deploy/docker/` (Dockerfiles, `compose.yaml`, sidecar config, `env.example`) and
`server/deploy/helm/swarm-sentinel/` (chart).

### Loopback/proxy posture (read this first)

Identical to the systemd + nginx layout above: `server/main.ts` binds `127.0.0.1:8787`
unconditionally — inside the container/pod it is reachable only via loopback, never directly. The
nginx sidecar (`server/deploy/docker/nginx-sidecar.conf`, the same caps as `nginx-api.conf`:
64 KB bodies, 30 r/s per-IP, 30 s read timeout) shares the network namespace and is the only
ingress, on `:8080`. TLS terminates at your host nginx / cluster ingress — never at the sidecar.
Container hardening mirrors the systemd unit: unprivileged uid 1000, read-only root filesystem,
zero capabilities, `no-new-privileges`, seccomp RuntimeDefault, 512 MB memory cap
(`MemoryMax=512M`).

Data paths are contract-fixed and set via `SENTINEL_*` env (also baked as image defaults):

| what | path | env |
|---|---|---|
| private corpus | `/var/lib/swarm-sentinel/corpus` | `SENTINEL_CORPUS_DIR` |
| triggers + telemetry JSONL | `/var/lib/swarm-sentinel/triggers` | `SENTINEL_DATA_DIR` (the trigger/telemetry store dir) |

### Build (from the repo root)

```bash
docker build -f server/deploy/docker/Dockerfile       -t swarm-sentinel-control-plane:local .
docker build -f server/deploy/docker/Dockerfile.proxy -t swarm-sentinel-proxy:local .
```

Docker ≥ 23 (BuildKit) picks up `server/deploy/docker/Dockerfile*.dockerignore` and keeps the
build-context upload small. For Kubernetes, push both images to your own registry and set
`image.repository` / `proxyImage.repository` to it.

### docker compose

```bash
cd server/deploy/docker
cp env.example .env && chmod 600 .env    # fill in CONTROL_PLANE_ENC_KEY + SENTINEL_TOKENS
docker compose up -d --build
```

`compose.yaml` publishes host `127.0.0.1:8787` → the sidecar, so the `nginx-api.conf` vhost from
the systemd deployment works unchanged (`proxy_pass http://127.0.0.1:8787`) — keep the compose
port loopback-bound. Named volumes back the two contract paths.

### Helm

Create the Secret first — customer-owned material, out of band, never in values files:

```bash
kubectl create secret generic swarm-sentinel-secrets \
  --from-literal=control-plane-enc-key="$(openssl rand -base64 32)" \
  --from-literal=sentinel-tokens="ss_<openssl rand -hex 24>" \
  --from-literal=jev-api-key="<customer-owned JEV key>"
```

Then lint and install:

```bash
helm lint server/deploy/helm/swarm-sentinel

helm install sentinel server/deploy/helm/swarm-sentinel \
  --namespace sentinel --create-namespace \
  --set image.repository=<registry>/swarm-sentinel-control-plane \
  --set proxyImage.repository=<registry>/swarm-sentinel-proxy \
  --set jev.endpoint=https://<private-or-local-jev-endpoint>/evaluate
```

The chart creates PVCs at the two contract paths (`persistence.corpus.size` 10Gi,
`persistence.triggers.size` 5Gi by default), deploys the plane + proxy sidecar in one pod
(replicas fixed at 1 — the trigger store is single-writer), and turns on the fail-closed
NetworkPolicy. `secret.create=true` plus `secret.controlPlaneEncKey`/`secret.sentinelTokens` is
available for test installs only (the values end up in Helm release history).

### Verify (both paths)

Compose — direct to the published loopback port:

```bash
curl -s http://127.0.0.1:8787/healthz | jq                # {"ok":true,...}
curl -s -X POST http://127.0.0.1:8787/v1/inspect \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"command":"rm -rf /"}' | jq                        # action:"block", layer:"floor"
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8787/v1/inspect \
  -H "Authorization: Bearer wrong" -d '{}'                # 401
```

Helm — the Service fronts the `:8080` sidecar (the plane itself is loopback-only in the pod):

```bash
kubectl -n sentinel port-forward svc/sentinel-swarm-sentinel 8787:8080
curl -s http://127.0.0.1:8787/healthz | jq                # {"ok":true,...}
curl -s -X POST http://127.0.0.1:8787/v1/inspect \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"command":"rm -rf /"}' | jq                        # action:"block", layer:"floor"
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8787/v1/inspect \
  -H "Authorization: Bearer wrong" -d '{}'                # 401
```

### BYOK: customer-owned JEV keys

All JEV material is the customer's (BYOK) and lives only in `server/deploy/docker/.env` (compose)
or the Kubernetes Secret (chart) — never in images, values files, or inbound headers. The plane's
live-adjudication path uses tenant BYOK credentials encrypted at rest under
`CONTROL_PLANE_ENC_KEY` (AES-256-GCM, decrypted in RAM only — the `registerByok` / dashboard flow
of CONTROL_PLANE.md §4); the JEV key is never an auth credential and never echoed in a response.
The Secret's `jev-api-key` is the customer's upstream JEV credential.

> **Zero-egress caveat** (PROJECT_PHASES.md data model): BYOK controls account ownership, **not**
> physical network locality. A private or local JEV endpoint (`jev.endpoint`) is additionally
> required when the deployment must have zero external egress.

### No-contribution (explicit flag, default ON)

`SENTINEL_NO_CONTRIBUTION=1` — `noContribution: true` in the chart, `SENTINEL_NO_CONTRIBUTION=1`
in `.env` — is the shipped default for private deployments: enterprise data never feeds the
shared corpus. It holds at two layers:

1. **Data contract** — the private corpus stays on customer volumes at
   `/var/lib/swarm-sentinel/corpus`; a private install has no export path for corpus, trigger, or
   telemetry data to shared-corpus infrastructure.
2. **Network belt** — the chart's NetworkPolicy (on by default) is fail-closed: egress is cluster
   DNS plus exactly `networkPolicy.extraEgress` (add your private/local JEV endpoint there). A
   private deployment cannot reach shared-corpus infrastructure at all.

Setting `noContribution: false` is a deliberate opt-in to the shared-learning loop and should be
a conscious, documented decision.
