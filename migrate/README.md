# Stateful data migration — Docker volumes → k8s PVCs

Runbook for moving the gt-core platform's stateful data from the current
**docker-compose named volumes** into the **k8s StatefulSet PVCs** defined in
`chart/gt`. This is bead **hq-talos-migration.7** (epic hq-talos-migration).

> **Authoring-only in this repo.** These scripts are NOT run as part of CI or by
> merging this branch. They are executed BY AN OPERATOR, once, during a planned
> maintenance window, against the real prod stack + the target cluster. Every
> script defaults to `DRY_RUN=1` (prints the commands, writes nothing).

## What moves

| Store        | Source (compose volume → container)              | Target (k8s)                    | Method                       |
| ------------ | ------------------------------------------------- | ------------------------------- | ---------------------------- |
| **Postgres** | `gt-pgdata` → `gt-app-pg` (`/var/lib/postgresql/data`) | `gt-postgres-0` (PVC `data-gt-postgres-0`) | `pg_dump --create` + roles → `psql` |
| **Dolt**     | `dolt-data` → `gt-app-dolt` (`/var/lib/dolt`)     | `gt-dolt-0` (PVC `data-gt-dolt-0`) | `dolt dump -r sql` → `dolt sql` |
| **MinIO**    | `minio-data` → `gt-app-minio` (`/data`)           | `gt-minio-0` (PVC `data-gt-minio-0`) | `mc mirror`                  |
| **Eventlog** | `gt-eventlog` → `gt-app-mcp-server` (`/var/lib/gt-core`) | PVC `gt-eventlog` (helper pod)  | `tar` → `kubectl cp` + untar |

Names assume the chart's default release name **`gt`** (fullname `gt`). If you
install under a different release, override the `DST_*` env vars (see
`lib/common.sh`).

> **Postgres carries everything in one dump.** A whole-DB `pg_dump` of `gtapp`
> includes the audit tables, the table-backed dispatch domains, **every per-tenant
> `ws_*` / `hq_*` schema**, and the document subsystem's `pgvector` objects +
> `CREATE EXTENSION vector`. Global roles are dumped separately
> (`pg_dumpall --roles-only`).
>
> **Dolt dumps the working set, not the commit history.** For the issue tracker
> the working set is what `issues.*` reads; gt-mcp-server re-commits on each
> mutation. If full Dolt history must survive, use the clone path (below) instead
> of the SQL dump.

## Prerequisites

- `docker` CLI with access to the running compose stack (the source).
- `kubectl` configured against the target cluster, namespace `gt` (the chart's
  StatefulSets + the `gt-eventlog` PVC already applied and **Running/Bound** —
  i.e. `helm install gt chart/gt` has been done, but the platform is fresh/empty).
- The stores' credentials available in the environment (mirror compose `.env`):
  `POSTGRES_PASSWORD`, `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`. Dolt is
  passwordless on the internal net.
- Free disk under `WORKDIR` (default `/var/tmp/gt-migrate`) for the dumps/tarballs.

## Quiescing (consistency) — REQUIRED for a clean snapshot

The migration reads the OLD store while it must NOT be mutated. Pick one:

1. **Maintenance window (recommended).** Put the platform in maintenance: stop the
   FE / return 503, and scale BOTH the new k8s API and the singleton daemon to 0
   (`kubectl -n gt scale deploy/gt-api deploy/gt-daemons --replicas=0`) so nothing
   on the new side writes either. Keep the old compose stack up but with its
   writers stopped (`docker compose stop gt-mcp-server gt-orch-server gt-web gt-docs`)
   — the DB/MinIO/eventlog containers stay UP so the scripts can read them.
2. **Stores read-only.** If you cannot stop the compose app, the dumps still run,
   but a concurrent write between dump and verify will show as a count mismatch
   and the verify step will fail closed (by design) — re-run after quiescing.

The **eventlog** is the most write-sensitive (append-only files): it MUST be
quiesced or the tar is a torn snapshot. The scripts print a quiesce reminder
before any write.

## Order

Run stores independently (isolates failures, each is re-runnable):

```sh
cd migrate

# 0. REHEARSE everything first (writes nothing):
DRY_RUN=1 ./migrate-all.sh

# 1. Quiesce (see above).

# 2. Real migration, one store at a time, verifying each:
DRY_RUN=0 ./migrate-postgres.sh all
DRY_RUN=0 ./migrate-dolt.sh     all
DRY_RUN=0 ./migrate-minio.sh    all      # needs endpoint wiring, see below
DRY_RUN=0 ./migrate-eventlog.sh all

# …or the wrapper (same order, verify per store):
DRY_RUN=0 ./migrate-all.sh
```

Each script accepts a sub-phase so you can re-run a single step:
`dump|restore|verify` (pg/dolt), `mirror|verify` (minio), `pack|unpack|verify`
(eventlog).

### MinIO endpoint wiring

`mc mirror` needs to reach BOTH stores. The script runs `mc` in a throwaway
`minio/mc` container; supply reachable URLs:

```sh
# Target: forward the in-cluster MinIO service to the host.
kubectl -n gt port-forward svc/gt-minio 19000:9000 &

# Source: publish/forward the compose MinIO API to the host (compose only
# publishes the console :9001 by default — expose :9000 for the window, e.g.
# `docker run ... --network <compose-net>` or a temporary port publish).
DRY_RUN=0 \
  SRC_MINIO_URL=http://127.0.0.1:9000 \
  DST_MINIO_URL=http://127.0.0.1:19000 \
  MC_NETWORK=host \
  ./migrate-minio.sh all
```

### Eventlog helper pod

`migrate-eventlog.sh` applies `manifests/eventlog-migrate-pod.yaml` — a busybox
pod that mounts only the `gt-eventlog` PVC at `/data` — so the untar does not
fight a live API pod for the mount. The script tears the pod down after verify.
(Scale the API/daemon to 0 first so the RWO/RWX mount is free.)

## Verification

Every store self-verifies (and fails closed on mismatch):

- **Postgres** — user-table count, the set of non-system schemas (so every
  `ws_*`/`hq_*` is present), the `pgvector` extension presence, and per-schema row
  estimates, source vs target.
- **Dolt** — per-database table count + the `issues` row count, source vs target,
  across the default `hq` DB and any discovered `hq_*` tenant DBs.
- **MinIO** — `mc du` total bytes + object count of the bucket, source vs target.
- **Eventlog** — file count + a sorted-sha256 **rollup hash** of every file's
  content (order-independent), source vs target.

A failed verify exits non-zero and prints `keep the old volume` — do NOT cut over.

## Cutover & rollback

The migration **never deletes the old docker volumes.** They are the rollback:

- **Cut over** only after all four verifies pass: point DNS/Ingress at the cluster
  (or scale the new API/daemon back up) and stop the compose app for good.
- **Roll back** (any verify failed, or post-cutover regression): bring the compose
  stack back up (`docker compose up -d`) — the original volumes are untouched —
  and scale the k8s API/daemon back to 0. Re-run the migration after fixing the
  cause.
- Reclaim the old volumes (`docker volume rm gt-app_dolt-data …`) ONLY after the
  cluster has been the source of truth long enough to trust (days, not minutes).

## Appendix — Dolt full-history alternative (clone)

If preserving Dolt commit history matters more than simplicity, replace the SQL
dump with a remote clone instead of `dolt dump`:

```sh
# In the SOURCE container, expose the db as a file-remote, then clone it from a
# helper that can reach the target dolt's data dir. Because both dolt servers are
# pods/containers, the practical path is: tar the source /var/lib/dolt (it is a
# normal directory of dolt repos), kubectl cp it into the gt-dolt PVC via a helper
# pod (same shape as migrate-eventlog.sh), then let dolt-sql-server open it.
# This carries the FULL commit graph, at the cost of a binary (not logical) copy.
```

This is intentionally left as a documented alternative — the default scripts use
the logical SQL dump because it is portable, auditable, and sufficient for the
tracker's working-set semantics.
