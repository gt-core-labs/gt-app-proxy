#!/usr/bin/env bash
# migrate-all.sh — run every per-store migration in the correct order.
#
# This is a convenience wrapper. Prefer running each store individually (so a
# failure is isolated and re-runnable). The order below puts the schema/relational
# stores first, then objects, then the append-only log; verification runs at the
# end of each store's `all` phase.
#
# DRY_RUN defaults to 1 (prints, writes nothing). The runbook (README.md) is the
# authority on quiescing + windows; this wrapper does NOT quiesce for you.
#
# Usage:
#   DRY_RUN=1 ./migrate-all.sh                 # rehearse the whole sequence
#   DRY_RUN=0 ./migrate-all.sh                 # real migration (in a window)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

log "==== gt-core stateful migration (DRY_RUN=$DRY_RUN) ===="
log "order: postgres → dolt → minio → eventlog (verify per store)"

"$HERE/migrate-postgres.sh" all
"$HERE/migrate-dolt.sh"     all
"$HERE/migrate-minio.sh"    all
"$HERE/migrate-eventlog.sh" all

log "==== all stores migrated + verified ===="
log "old docker volumes are UNTOUCHED — they are your rollback until cutover is confirmed."
