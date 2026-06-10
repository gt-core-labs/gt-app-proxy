#!/usr/bin/env bash
# migrate-dolt.sh — copy the Dolt tracking DB(s) (the canonical hq.issues + meta,
# plus any per-tenant hq_<ws> databases under multi-tenant routing) from the
# compose `gt-app-dolt` container into the k8s `gt-dolt-0` pod.
#
# Approach: Dolt speaks the MySQL wire and ships the `dolt` CLI in the image. The
# most portable copy is a logical SQL dump per database (`dolt dump -r sql`), then
# replay it into the target pod's running dolt-sql-server over the same `dolt sql`
# entrypoint. This avoids needing the two dolt instances to be network-peers
# (dolt remote/clone), works pod-to-pod via stdin, and is human-auditable.
#
# Why not `dolt remote`/clone: it needs a reachable remote + auth between the two
# dolt servers; over a migration window a logical dump piped through kubectl is
# simpler and keeps the source untouched (rollback = the old volume).
#
# NOTE: a SQL dump replays the WORKING SET (current table data), not the Dolt
# commit history. For the issue tracker that is what matters (issues.* reads the
# working set; gt-mcp-server re-commits on each mutation). If full Dolt commit
# history must be preserved, use the `clone` path documented in README instead.
#
# Source : docker exec gt-app-dolt dolt dump   (reads the OLD volume)
# Target : kubectl exec gt-dolt-0 -- dolt sql   (writes the NEW PVC)
#
# Verify : database list + per-DB table count + issues row count, src vs target.
#
# Usage:
#   DRY_RUN=1 ./migrate-dolt.sh                # default — prints, writes nothing
#   DRY_RUN=0 ./migrate-dolt.sh                # real migration (in a window)
#   DRY_RUN=0 DOLT_DBS="hq hq_acme" ./migrate-dolt.sh   # explicit DB set
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

# Read-only SQL probes against either side. Dolt is passwordless for DOLT_USER.
src_dolt_sql() { src_exec "$SRC_DOLT_CONTAINER" dolt sql -q "$1"; }   # cwd = /var/lib/dolt
dst_dolt_sql() { dst_exec "$DST_DOLT_POD"       sh -c "cd /var/lib/dolt && dolt sql -q \"$1\""; }

# Discover the databases to migrate. Default = the configured default DB plus any
# hq_* tenant DBs the source reports; override with DOLT_DBS="db1 db2".
discover_dbs() {
  if [ -n "${DOLT_DBS:-}" ]; then echo "$DOLT_DBS"; return; fi
  # SHOW DATABASES minus the dolt system DBs; keep hq + hq_* (the tracker shape).
  src_exec "$SRC_DOLT_CONTAINER" dolt sql -q "SHOW DATABASES;" \
    | awk 'NR>1 {print $1}' \
    | grep -Ev '^(Database|information_schema|mysql|sys|dolt|\+|\|)$' \
    | grep -E "^(${DOLT_DEFAULT_DB}|hq(_.*)?)$" || true
}

dump_one() {  # dump_one <db>
  local db="$1" out="$WORKDIR/dolt-${db}.sql"
  log "dumping dolt db: $db"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[migrate][dry-run] docker exec %s sh -c "cd /var/lib/dolt && dolt sql -q \\"USE %s\\" && dolt dump -r sql -f -fn %s" → %s\n' \
      "$SRC_DOLT_CONTAINER" "$db" "$out" "$out" >&2
    return 0
  fi
  # `dolt dump` writes a file inside the container; emit to stdout via -fn /dev/stdout
  # after USE <db>. Capture to the host workdir.
  src_exec "$SRC_DOLT_CONTAINER" sh -c "cd /var/lib/dolt && dolt sql -q 'USE \`$db\`' >/dev/null 2>&1; dolt dump -r sql --no-batch -f -fn /dev/stdout 2>/dev/null || dolt sql -q 'USE \`$db\`; SELECT 1' >/dev/null" > "$out" || \
    src_exec "$SRC_DOLT_CONTAINER" sh -c "cd /var/lib/dolt/$db 2>/dev/null && dolt dump -r sql -f -fn /dev/stdout" > "$out"
  log "  → $(wc -c <"$out") bytes ($out)"
}

restore_one() {  # restore_one <db>
  local db="$1" out="$WORKDIR/dolt-${db}.sql"
  log "restoring dolt db: $db → $DST_DOLT_POD"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[migrate][dry-run] kubectl -n %s exec -i %s -- sh -c "cd /var/lib/dolt && dolt sql -q '\''CREATE DATABASE IF NOT EXISTS \`%s\`'\'' && dolt sql --use-db %s" < %s\n' \
      "$K8S_NS" "$DST_DOLT_POD" "$db" "$db" "$out" >&2
    return 0
  fi
  [ -s "$out" ] || die "dump for $db missing/empty: $out — run dump first"
  # Ensure the database exists, then replay the dump into it. The dump from
  # `dolt dump -r sql` includes CREATE TABLE + INSERTs scoped to the db when
  # replayed with --use-db.
  dst_exec "$DST_DOLT_POD" sh -c "cd /var/lib/dolt && dolt sql -q 'CREATE DATABASE IF NOT EXISTS \`$db\`'"
  dst_exec "$DST_DOLT_POD" sh -c "cd /var/lib/dolt && dolt sql --use-db '$db'" < "$out"
  # Commit the working set so the new dolt has a baseline commit (gt-mcp-server
  # also commits per mutation, but a clean baseline aids drift-reconcile).
  dst_exec "$DST_DOLT_POD" sh -c "cd /var/lib/dolt && dolt sql -q 'USE \`$db\`; CALL DOLT_ADD(\"-A\"); CALL DOLT_COMMIT(\"-m\", \"migrate: import working set\", \"--allow-empty\");'" || warn "baseline commit on $db skipped"
}

verify() {
  local dbs rc=0
  dbs="$(discover_dbs)"
  [ -n "$dbs" ] || die "no dolt databases discovered to verify (set DOLT_DBS)"
  log "VERIFY dolt: dbs = $dbs"
  for db in $dbs; do
    local s_tabs d_tabs s_iss d_iss
    s_tabs="$(src_exec "$SRC_DOLT_CONTAINER" dolt sql -q "SELECT count(*) FROM information_schema.tables WHERE table_schema='$db';" | awk 'NR==2{print $1}' | tr -dc '0-9')"
    d_tabs="$(dst_exec "$DST_DOLT_POD" sh -c "cd /var/lib/dolt && dolt sql -q \"SELECT count(*) FROM information_schema.tables WHERE table_schema='$db';\"" | awk 'NR==2{print $1}' | tr -dc '0-9')"
    s_iss="$(src_exec "$SRC_DOLT_CONTAINER" dolt sql -q "SELECT count(*) FROM \`$db\`.issues;" 2>/dev/null | awk 'NR==2{print $1}' | tr -dc '0-9')"
    d_iss="$(dst_exec "$DST_DOLT_POD" sh -c "cd /var/lib/dolt && dolt sql -q \"SELECT count(*) FROM \\\`$db\\\`.issues;\"" 2>/dev/null | awk 'NR==2{print $1}' | tr -dc '0-9')"
    log "  $db: tables src=${s_tabs:-?} dst=${d_tabs:-?} | issues src=${s_iss:-NA} dst=${d_iss:-NA}"
    [ "${s_tabs:-x}" = "${d_tabs:-y}" ] || { warn "  $db table count mismatch"; rc=1; }
    if [ -n "${s_iss:-}" ]; then [ "${s_iss:-x}" = "${d_iss:-y}" ] || { warn "  $db issues row mismatch"; rc=1; }; fi
  done
  if [ "$rc" = "0" ]; then log "VERIFY OK"; else die "VERIFY FAILED — keep the old dolt volume"; fi
}

main() {
  preflight "$SRC_DOLT_CONTAINER" "$DST_DOLT_POD"
  ensure_workdir
  local dbs; dbs="$(discover_dbs)"
  [ -n "$dbs" ] || die "no dolt databases discovered (set DOLT_DBS or check $SRC_DOLT_CONTAINER)"
  case "${1:-all}" in
    dump)    quiesce_note; for db in $dbs; do dump_one "$db"; done ;;
    restore) for db in $dbs; do restore_one "$db"; done ;;
    verify)  verify ;;
    all)     quiesce_note; for db in $dbs; do dump_one "$db"; done; for db in $dbs; do restore_one "$db"; done; verify ;;
    *) die "usage: $0 [dump|restore|verify|all]" ;;
  esac
}
main "$@"
