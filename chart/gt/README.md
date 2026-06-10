# gt — the gt-core platform Helm chart (Talos / Kubernetes)

This chart runs the whole gt-core platform on Kubernetes (target: **Talos**),
replicating the docker-compose assembly in this repo (`docker-compose.yml` +
`compose.embeddings.yml`). It is the k8s side of epic **hq-talos-migration**
(beads `.2` / `.3` / `.4` / `.5`).

Why migrate: under compose + watchtower, a bad image (the `.9` incident) was
auto-pulled and blindly recreated → crash-loop in prod → manual rollback. Under
this chart, readiness/liveness probes gate the rolling update (`maxUnavailable:
0`): **a pod that panics at boot never becomes Ready, never receives traffic,
and never replaces a healthy pod.** Deploy = GitOps (apply an immutable tag);
rollback = redeploy the previous tag / `helm rollback`.

## Bring-up

```sh
# 1. Get a cluster (local to iterate, or real Talos nodes).
talosctl cluster create               # local docker-backed Talos, OR
#   provision real Talos nodes with talosctl + a machine config.

# 2. Supply secrets (NEVER committed) — see "Secrets" below.
cp chart/gt/values-secret.yaml.example values-secret.yaml   # then edit
#   (or use --set / sealed-secrets / external-secrets)

# 3. Install.
helm install gt chart/gt -f values-secret.yaml \
  --set storageClass=<your-csi-class>

# 4. Done. The post-install hooks create the MinIO bucket + run schema bootstrap;
#    the API rolls only once its pods pass /healthz.
```

> This chart never deploys itself — it is rendered + applied by your GitOps
> controller (Argo/Flux) or `helm install/upgrade`. Do not run `talosctl` /
> `kubectl` against a cluster as part of authoring it.

## How the compose assembly maps to k8s

| compose service        | k8s object(s)                                              |
| ---------------------- | ---------------------------------------------------------- |
| `proxy` (Traefik)      | **Ingress** (`ingress.className`, default `traefik`) — path routing mirrored; TLS via cert-manager (ACME-DNS-01-via-Netlify has no k8s analogue) |
| `dolt`                 | **StatefulSet** + headless **Service** + PVC               |
| `postgres` (pgvector)  | **StatefulSet** + headless **Service** + PVC               |
| `minio`                | **StatefulSet** + headless **Service** + PVC               |
| `minio-createbucket`   | **Job** (post-install/upgrade hook, idempotent)            |
| `gt-mcp-server`        | **Deployment** (API, N replicas, probes, rolling update) + **Service** |
| `gt-orch-server` (orchd profile) | **Deployment** (singleton, `replicas=1`, `Recreate`) + rig/worktree PVCs |
| `gt-web`               | **Deployment** + **Service**                               |
| `gt-docs`              | **Deployment** + **Service**                               |
| `watchtower`           | **removed** — replaced by GitOps + immutable tags          |
| named volumes          | PVCs (`*-eventlog`, `*-graph`, `*-orchd-rig*`, per-StatefulSet data) |

Ingress path routing (compose Traefik priorities → longest-prefix Ingress):

- `/auth /api /mcp /stream /openapi.json /healthz /health /.well-known` → `mcp-server:8765` (was priority 100)
- `/docs /share` → `gt-docs:3000` (was priority 50)
- `/` → `gt-web:3000` (catch-all, was priority 1)

## API vs daemon split (bead .4)

The **API** Deployment is stateless and scales to N replicas. The **singleton**
(`orchd`) Deployment is `replicas: 1` with a `Recreate` strategy — it owns the
in-process daemon loops (interactive session reaper, archive sweep,
drift-reconcile, account GC, convoy→scheduler bridge, quota rotation) that MUST
have exactly one ticker or they double-fire and race.

**The env gate today (important):** the `gt-mcp-server` binary does **not** have
a single `GT_RUN_DAEMONS` switch. It unconditionally `tokio::spawn`s its daemon
loops. Some loops have an individual off-switch the chart uses on the API tier:

| loop                       | off-switch the binary honours today          | set on API? |
| -------------------------- | --------------------------------------------- | ----------- |
| graph drift-reconcile      | `GT_GRAPH_DRIFT_TICK_SECS=0`                  | ✅ yes      |
| account-dir GC             | `GT_ACCOUNTS_GC_TICK_SECS=0`                  | ✅ yes      |
| interactive session reaper | *(none — `GT_RECONCILE_TICK_SECS` is cadence only)* | ⚠️ still spawns |
| archive daemon             | *(none — only `system_config.json enabled=false`)*  | ⚠️ still spawns |

So a **clean** split needs a **gt-core follow-up**: add a `GT_RUN_DAEMONS`
(default `1`) env that gates every loop, so the API pods set `GT_RUN_DAEMONS=0`.
This chart **already wires `GT_RUN_DAEMONS=0` on the API and `=1` on the
singleton**, so the day that follow-up ships, the manifests need no change. Until
then the reaper + archive loops still run on the API replicas; with 2 API
replicas + 1 singleton that is 3 reaper/archive tickers (low-frequency, mostly
benign, but a known race the follow-up closes). File the follow-up as a
`gt-composition` bead before scaling the API past 1 in prod.

## Non-root / fsGroup (bead .5) — obsoletes .10 / .11

Every pod runs with `runAsNonRoot: true`, `runAsUser/runAsGroup: 1000`, and
`fsGroup: 1000`. The kubelet chowns each mounted PVC to the fsGroup, so the
uid-1000 process can write the event log, the rig checkout, and read the mounted
PEMs — **without** the root-owned bind-mount + `git config safe.directory='*'`
hack (`hq-vcs-connections.10`) and **without** an in-image privilege drop
(`.11`). Both are obsolete under this chart.

## Stateful topology (bead .3)

The event log (`*-eventlog` PVC) is a **file-based, single-writer** store the API
and the singleton both mount (compose: the shared `gt-eventlog` volume). Default
`eventlog.accessMode: ReadWriteMany` so every pod can mount it. If your CSI class
has no RWX:

- set `eventlog.accessMode=ReadWriteOnce` **and** keep `mcpServer.api.replicas: 1`
  + co-schedule the singleton on the same node, **or**
- use a shared-filesystem CSI (NFS/CephFS/Longhorn-RWX).

The actual daemon-tick **writer** is the singleton; the API replicas append
issue/feed events. `*-graph` (knowledge-graph output) is a separate PVC.

## Secrets

Secret material is templated from `.Values.secrets`. The in-repo `values.yaml`
holds **empty placeholders** — supply the real values at install time and never
commit them:

```sh
helm install gt chart/gt -f values-secret.yaml         # gitignored file, OR
helm install gt chart/gt --set secrets.postgresPassword=... --set secrets.secretKey=...
```

For GitOps prefer **sealed-secrets / external-secrets / SOPS**: set
`secrets.create=false` and provide an externally-managed Secret named
`<release>-gt-secrets` with the same keys.

Keys mirror the compose `.env` + `./secrets/*` files: `postgresPassword`,
`minioRootPassword`, `secretKey` (GT_SECRET_KEY, oauth builds), `jwtPrivateKey` /
`jwtPublicKey` (the `secrets/jwt_*.pem` bodies), `adminEmail` / `adminPassword`
(admin seed), `githubAppId` / `githubAppPrivateKey` / `githubAppWebhookSecret`
(GitHub App push webhook + private-rig drift reconcile), `rigGitToken` (orchd rig
clone). See `values.yaml` for the per-key feature notes.

## Greenfield seeds dependency

The `seed` Job (post-install/upgrade hook) currently only waits for the stores
and relies on the API binary's boot-time schema bootstrap (`ensure_database` +
`ensure_schema` + the PG migration array). **Live seeds are STUBBED** — the
knowledge prompts, IdP/OAuth providers, rig catalog and quota accounts are filled
by epic **hq-greenfield-seeds**. When it lands, replace the placeholder in
`templates/seed-job.yaml` with its seed command (a `gt`/REST call against the
in-cluster API).

## Verify (no cluster)

```sh
helm lint chart/gt
helm template gt chart/gt | kubectl --dry-run=client -f - apply   # optional
```
