#!/usr/bin/env bash
# common.sh — shared helpers for the gt-core stateful-data migration scripts
# (epic hq-talos-migration, bead .7). Sourced by every per-store script.
#
# These scripts move data from the CURRENT docker-compose named volumes into the
# k8s StatefulSet PVCs defined in chart/gt. They are AUTHORING-ONLY here: never
# run against prod or any cluster without going through the runbook (README.md),
# a maintenance window, and a verified backup. The old docker volumes stay intact
# until verification passes — that is the rollback.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration knobs (override via env). Defaults mirror docker-compose.yml +
# compose.embeddings.yml + chart/gt values (release name `gt`, fullname `gt`).
# ---------------------------------------------------------------------------

# --- SOURCE: the running docker-compose stack ---
# The compose project name. compose.embeddings/.env set COMPOSE_PROJECT_NAME=gt-app
# in prod; container_name is pinned regardless (gt-app-pg / gt-app-dolt / gt-app-minio).
SRC_PG_CONTAINER="${SRC_PG_CONTAINER:-gt-app-pg}"
SRC_DOLT_CONTAINER="${SRC_DOLT_CONTAINER:-gt-app-dolt}"
SRC_MINIO_CONTAINER="${SRC_MINIO_CONTAINER:-gt-app-minio}"
SRC_MCP_CONTAINER="${SRC_MCP_CONTAINER:-gt-app-mcp-server}"

# DB / store credentials — mirror the compose env defaults (.env overrides).
PG_USER="${PG_USER:-${POSTGRES_USER:-gtapp}}"
PG_DB="${PG_DB:-${POSTGRES_DB:-gtapp}}"
PG_PASSWORD="${PG_PASSWORD:-${POSTGRES_PASSWORD:-gtapp}}"

DOLT_USER="${DOLT_USER:-gtapp}"          # passwordless on the internal net
DOLT_DEFAULT_DB="${DOLT_DEFAULT_DB:-hq}" # single-tenant default; multi-tenant adds hq_<ws>

MINIO_ROOT_USER="${MINIO_ROOT_USER:-gtapp}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-gtappsecret}"
GT_BLOB_BUCKET="${GT_BLOB_BUCKET:-gt-documents}"

# eventlog volume mount inside the mcp-server container.
SRC_EVENTLOG_PATH="${SRC_EVENTLOG_PATH:-/var/lib/gt-core}"

# --- TARGET: the k8s cluster (chart release `gt`, fullname `gt`) ---
KCTL="${KCTL:-kubectl}"
K8S_NS="${K8S_NS:-gt}"
DST_PG_POD="${DST_PG_POD:-gt-postgres-0}"
DST_DOLT_POD="${DST_DOLT_POD:-gt-dolt-0}"
DST_MINIO_POD="${DST_MINIO_POD:-gt-minio-0}"
# The API pod that mounts the eventlog PVC (gt-eventlog). Any pod that has it
# mounted works; the helper pod option (see migrate-eventlog.sh) avoids races.
DST_EVENTLOG_PVC="${DST_EVENTLOG_PVC:-gt-eventlog}"
DST_EVENTLOG_PATH="${DST_EVENTLOG_PATH:-/var/lib/gt-core}"

# k8s in-pod PGDATA is relocated to a subdir so fsGroup owns it (chart postgres.yaml
# sets PGDATA=/var/lib/postgresql/data/pgdata). The restore targets the SERVER, not
# the data dir, so this is informational — psql connects over the socket/port.
DST_PGDATA="${DST_PGDATA:-/var/lib/postgresql/data/pgdata}"

# --- run controls ---
# DRY_RUN=1 prints every mutating command instead of executing it. Default ON so a
# bare invocation NEVER writes. Set DRY_RUN=0 explicitly (in the runbook, in a
# window) to actually migrate.
DRY_RUN="${DRY_RUN:-1}"

# Working dir for dumps/artifacts (gitignored). Defaults under /var/tmp so a dump
# survives the shell but is clearly disposable.
WORKDIR="${WORKDIR:-/var/tmp/gt-migrate}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '[migrate] %s\n' "$*" >&2; }
warn() { printf '[migrate][WARN] %s\n' "$*" >&2; }
die()  { printf '[migrate][FATAL] %s\n' "$*" >&2; exit 1; }

# run CMD... — execute, or just print under DRY_RUN. Use for MUTATING ops only;
# read-only probes (counts) always run so verification works in a dry-run too.
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[migrate][dry-run] %s\n' "$*" >&2
    return 0
  fi
  log "+ $*"
  "$@"
}

# ---------------------------------------------------------------------------
# Source/target accessors. Source is docker exec into the compose container;
# target is kubectl exec into the StatefulSet pod. Kept behind functions so a
# different topology (e.g. a remote docker host, or a Job instead of exec) only
# needs these overridden.
# ---------------------------------------------------------------------------
src_exec() {  # src_exec <container> -- cmd...
  local c="$1"; shift
  docker exec -i "$c" "$@"
}
dst_exec() {  # dst_exec <pod> -- cmd...
  local p="$1"; shift
  "$KCTL" -n "$K8S_NS" exec -i "$p" -- "$@"
}

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

ensure_workdir() {
  mkdir -p "$WORKDIR"
  log "workdir: $WORKDIR (DRY_RUN=$DRY_RUN)"
}

# Confirm a source container and a target pod are both reachable before any copy.
# Read-only; safe in dry-run.
preflight() {
  require_cmd docker "$KCTL"
  log "preflight: source containers + target pods"
  docker inspect "$1" >/dev/null 2>&1 || die "source container not running: $1"
  "$KCTL" -n "$K8S_NS" get pod "$2" >/dev/null 2>&1 || die "target pod not found: $2 (ns $K8S_NS)"
  log "preflight ok: src=$1 dst=$2"
}

# quiesce reminder — printed, never automated. Stopping writes is an operator
# decision tied to a maintenance window (see README "Quiescing").
quiesce_note() {
  cat >&2 <<'EOF'
[migrate] ----------------------------------------------------------------
[migrate] QUIESCE: for a CONSISTENT snapshot, stop writes to this store first.
[migrate]   - Scale the k8s API + daemon to 0 OR keep the compose stack the SOLE
[migrate]     writer and put the platform in maintenance (Ingress 503 / stop FE).
[migrate]   - The migration reads from the OLD store; nothing should mutate it
[migrate]     between the dump and the verification count.
[migrate] ----------------------------------------------------------------
EOF
}
