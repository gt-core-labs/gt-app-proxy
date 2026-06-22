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

# 4. Done. The post-install hooks create the MinIO bucket + gate on the stores;
#    the API rolls only once its pods pass /health (schema + live seeds run at
#    API boot — see "Greenfield seeds" below).
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
| `gt-deploy-reconciler` | **CronJob** + dedicated `gt-deployer` **ServiceAccount**/`Role`/`RoleBinding` — pull-based in-cluster rollout (`deployReconciler.*`, gtproxy-50c890) |
| `watchtower`           | **removed** — replaced by GitOps + immutable tags          |
| named volumes          | PVCs (`*-eventlog`, `*-graph`, `*-orchd-rig*`, per-StatefulSet data) |

Ingress path routing (compose Traefik priorities → longest-prefix Ingress):

- `/auth /api /mcp /stream /openapi.json /health /.well-known` → `mcp-server:8765` (was priority 100)
- `/docs /share` → `gt-docs:3000` (was priority 50)
- `/` → `gt-web:3000` (catch-all, was priority 1)

## API vs daemon split (bead .4)

The **API** Deployment is stateless and scales to N replicas. The **singleton**
(`orchd`) Deployment is `replicas: 1` with a `Recreate` strategy — it owns the
in-process daemon loops (interactive session reaper, archive sweep,
drift-reconcile, account GC, convoy→scheduler bridge, quota rotation) that MUST
have exactly one ticker or they double-fire and race.

**The env gate:** the `gt-mcp-server` binary HAS a single `GT_RUN_DAEMONS` switch
(`should_run_daemons`, gt-mcp-server.rs): **default ON**, and an explicit
`GT_RUN_DAEMONS=0` turns **every** singleton daemon loop off (reaper, archive
sweep, graph drift-reconcile, account-dir GC, convoy→scheduler bridge, quota
rotation). This chart wires it directly:

| pod                | `GT_RUN_DAEMONS` | effect                                     |
| ------------------ | ---------------- | ------------------------------------------ |
| API (`mcp-server`) | `0`              | serves requests + runs boot seeds; ticks no daemon loop |
| singleton (`orchd`)| `1`              | owns every daemon tick                      |

The per-daemon cadence env on the API tier (`GT_GRAPH_DRIFT_TICK_SECS=0`,
`GT_ACCOUNTS_GC_TICK_SECS=0`) is kept as defense-in-depth but is redundant given
the single gate. **The API may scale to N replicas safely** — none of them tick a
singleton loop. Note: the **boot seeds** (knowledge/IdP/rigs catalog) are NOT
daemons and are NOT gated by `GT_RUN_DAEMONS`; they run on every API boot and are
idempotent (empty-table/empty-catalog gated), so N replicas racing to seed is
safe — the first wins, the rest skip.

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
(admin seed), `oauthSeedSecretGoogle` (GT_OAUTH_SEED_SECRET_GOOGLE — cleartext
client_secret for the boot-seeded google provider; empty ⇒ that login button is
skipped), `githubAppId` / `githubAppPrivateKey` / `githubAppWebhookSecret`
(GitHub App push webhook + private-rig drift reconcile), `rigGitToken` (orchd rig
clone). See `values.yaml` for the per-key feature notes.

## Greenfield seeds

Epic **hq-greenfield-seeds** (shipped) made the platform's live-curated state into
reproducible **boot seeds** that run at **API boot** inside `gt-mcp-server` —
**not** via the `seed` Job, and **not** manually. Each is idempotent (gated on its
table/catalog being EMPTY, so it never clobbers a curated prod):

| seed                              | runs at      | requires                                              |
| --------------------------------- | ------------ | ---------------------------------------------------- |
| Global admin                      | API boot     | `GT_ADMIN_EMAIL` + `GT_ADMIN_PASSWORD`               |
| Role / skills catalog (knowledge) | API boot     | — (always; empty-catalog gated)                      |
| IdP/OAuth providers (e.g. google) | API boot     | `GT_SECRET_KEY` + `GT_OAUTH_SEED_SECRET_<ID>` (e.g. `GT_OAUTH_SEED_SECRET_GOOGLE`); empty-table gated. Seeded provider is `enabled=false` until an admin enables it. |
| Rig catalog                       | API boot     | — (always; empty-table gated)                        |

The `seed` Job (post-install/upgrade hook) is therefore only a **pre-roll
readiness gate**: it waits for Dolt + Postgres so the first API pod boots against
ready stores. It deliberately does NOT run the live seeds — doing so would fight
the empty-table gate / double-seed.

**Quota Claude accounts** are the one NON-boot seed: an operator provisions
per-account credential dirs under `GT_CLAUDE_ACCOUNTS_ROOT` (defaults to
`<eventlog>/accounts`, on the shared eventlog PVC so both the onboarding REST
surface on the API tier and the rotation daemon on the singleton see the same
dirs). See gt-core `docs/ops/greenfield-seeds.md` §3 (secrets matrix) + §4.4.

## Verify (no cluster)

```sh
helm lint chart/gt
helm template gt chart/gt | kubectl --dry-run=client -f - apply   # optional
```
