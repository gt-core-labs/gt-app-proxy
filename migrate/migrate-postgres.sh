#!/usr/bin/env bash
# migrate-postgres.sh — copy the gtapp Postgres DB (durable MCP audit + the
# table-backed dispatch domains + every per-tenant ws_*/hq_* schema + the
# document subsystem's pgvector data) from the compose `gt-app-pg` container
# into the k8s `gt-postgres-0` pod.
#
# Approach: pg_dump the WHOLE gtapp database (all schemas, all objects) with
# --create so the dump recreates the DB + its OWNER/extensions, then restore it
# into the k8s pod's postgres server over `kubectl exec ... psql`. The pgvector
# `CREATE EXTENSION vector` is captured by the dump (it lives in the source DB);
# the pgvector/pgvector:pg16 image has the extension available so it re-creates
# cleanly. Roles are dumped separately with pg_dumpall --roles-only (a per-DB
# pg_dump does NOT carry global roles).
#
# Source : docker exec gt-app-pg pg_dump / pg_dumpall   (reads the OLD volume)
# Target : kubectl exec gt-postgres-0 -- psql           (writes the NEW PVC)
#
# Verify : table count + per-schema row tallies + extension list, source vs target.
#
# Usage:
#   DRY_RUN=1 ./migrate-postgres.sh            # default — prints, writes nothing
#   DRY_RUN=0 ./migrate-postgres.sh            # real migration (in a window)
#   DRY_RUN=0 ./migrate-postgres.sh verify     # re-run verification only
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

DUMP_FILE="$WORKDIR/postgres-${PG_DB}.sql"
ROLES_FILE="$WORKDIR/postgres-roles.sql"

# Read-only count probes (run even in dry-run so verification is always real).
src_psql() { src_exec "$SRC_PG_CONTAINER" psql -X -At -U "$PG_USER" -d "$PG_DB" -c "$1"; }
dst_psql() { dst_exec "$DST_PG_POD"       psql -X -At -U "$PG_USER" -d "$PG_DB" -c "$1"; }

count_tables() { echo "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema');"; }
list_schemas() { echo "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('pg_catalog','information_schema','pg_toast') ORDER BY 1;"; }
list_exts()    { echo "SELECT extname FROM pg_extension ORDER BY 1;"; }

dump() {
  ensure_workdir
  quiesce_note
  log "dumping roles (global) from $SRC_PG_CONTAINER"
  # pg_dumpall --roles-only must connect as a superuser; the compose superuser is PG_USER.
  if [ "$DRY_RUN" = "1" ]; then
    printf '[migrate][dry-run] docker exec %s pg_dumpall -U %s --roles-only > %s\n' "$SRC_PG_CONTAINER" "$PG_USER" "$ROLES_FILE" >&2
    printf '[migrate][dry-run] docker exec %s pg_dump -U %s --create --clean --if-exists -d %s > %s\n' "$SRC_PG_CONTAINER" "$PG_USER" "$PG_DB" "$DUMP_FILE" >&2
    return 0
  fi
  src_exec "$SRC_PG_CONTAINER" pg_dumpall -U "$PG_USER" --roles-only > "$ROLES_FILE"
  # --create: emit CREATE DATABASE + connect; --clean --if-exists: drop/recreate
  # objects idempotently so a re-run is safe. The whole DB ⇒ every ws_*/hq_*
  # schema + the documents/pgvector objects come along.
  src_exec "$SRC_PG_CONTAINER" pg_dump -U "$PG_USER" --create --clean --if-exists -d "$PG_DB" > "$DUMP_FILE"
  log "dump complete: $(wc -c <"$DUMP_FILE") bytes → $DUMP_FILE"
}

restore() {
  [ -s "$DUMP_FILE" ] || { [ "$DRY_RUN" = "1" ] || die "dump file missing/empty: $DUMP_FILE — run dump first"; }
  log "restoring roles into $DST_PG_POD"
  # Roles first (ignore "already exists" on the bootstrapped PG_USER role).
  if [ "$DRY_RUN" = "1" ]; then
    printf '[migrate][dry-run] kubectl -n %s exec -i %s -- psql -U %s -d postgres < %s\n' "$K8S_NS" "$DST_PG_POD" "$PG_USER" "$ROLES_FILE" >&2
    printf '[migrate][dry-run] kubectl -n %s exec -i %s -- psql -U %s -d postgres < %s\n' "$K8S_NS" "$DST_PG_POD" "$PG_USER" "$DUMP_FILE" >&2
    return 0
  fi
  dst_exec "$DST_PG_POD" psql -U "$PG_USER" -d postgres -v ON_ERROR_STOP=0 < "$ROLES_FILE" || warn "roles restore had non-fatal errors (pre-existing roles)"
  # The dump connects to the new DB via its embedded \connect; restore against the
  # maintenance `postgres` DB so --create can DROP/CREATE the target DB.
  log "restoring database $PG_DB into $DST_PG_POD"
  dst_exec "$DST_PG_POD" psql -U "$PG_USER" -d postgres -v ON_ERROR_STOP=1 < "$DUMP_FILE"
  log "restore complete"
}

verify() {
  log "VERIFY: source ($SRC_PG_CONTAINER) vs target ($DST_PG_POD)"
  local s_tables d_tables s_schemas d_schemas s_exts d_exts rc=0
  s_tables="$(src_psql "$(count_tables)")"; d_tables="$(dst_psql "$(count_tables)")"
  s_schemas="$(src_psql "$(list_schemas)" | tr '\n' ',')"; d_schemas="$(dst_psql "$(list_schemas)" | tr '\n' ',')"
  s_exts="$(src_psql "$(list_exts)" | tr '\n' ',')"; d_exts="$(dst_psql "$(list_exts)" | tr '\n' ',')"

  log "tables  : src=$s_tables dst=$d_tables"
  log "schemas : src=[$s_schemas] dst=[$d_schemas]"
  log "exts    : src=[$s_exts] dst=[$d_exts]"

  [ "$s_tables" = "$d_tables" ] || { warn "TABLE COUNT MISMATCH"; rc=1; }
  [ "$s_schemas" = "$d_schemas" ] || { warn "SCHEMA SET MISMATCH"; rc=1; }
  case "$d_exts" in *vector*) : ;; *) warn "pgvector EXTENSION MISSING in target"; rc=1 ;; esac

  # Per-schema row tallies: sum reltuples across each user schema, src vs target.
  local tally='SELECT n.nspname, COALESCE(SUM(c.reltuples)::bigint,0) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind='\''r'\'' AND n.nspname NOT IN ('\''pg_catalog'\'','\''information_schema'\'','\''pg_toast'\'') GROUP BY 1 ORDER BY 1;'
  log "per-schema row estimates (src):"; src_psql "$tally" | sed 's/^/[migrate]   src /' >&2
  log "per-schema row estimates (dst):"; dst_psql "$tally" | sed 's/^/[migrate]   dst /' >&2

  if [ "$rc" = "0" ]; then log "VERIFY OK"; else die "VERIFY FAILED — keep the old volume, do not cut over"; fi
}

main() {
  preflight "$SRC_PG_CONTAINER" "$DST_PG_POD"
  case "${1:-all}" in
    dump)    dump ;;
    restore) restore ;;
    verify)  verify ;;
    all)     dump; restore; verify ;;
    *) die "usage: $0 [dump|restore|verify|all]" ;;
  esac
}
main "$@"
