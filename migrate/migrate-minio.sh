#!/usr/bin/env bash
# migrate-minio.sh — copy the document-attachment object bytes (the
# `gt-documents` bucket) from the compose `gt-app-minio` store into the k8s
# `gt-minio-0` store.
#
# Approach: `mc mirror` from the old MinIO endpoint to the new one. mirror is
# resumable + idempotent (only copies missing/changed objects), so it can be run
# repeatedly and re-run after a delta window. We drive `mc` from a throwaway
# minio/mc container that can reach BOTH endpoints:
#   - source endpoint: the compose service on its docker network, OR a host
#     port-forward of the source.
#   - target endpoint: a `kubectl port-forward svc/gt-minio 9000` exposed to the
#     mc container (the runbook sets up the forward; this script consumes URLs).
#
# Because reaching both stores at once is environment-specific, the endpoints are
# passed as URLs (SRC_MINIO_URL / DST_MINIO_URL); the runbook explains how to
# wire them (docker net alias for source, kubectl port-forward for target).
#
# Source : mc alias `src` → SRC_MINIO_URL
# Target : mc alias `dst` → DST_MINIO_URL
#
# Verify : object count + total bytes of the bucket, src vs target.
#
# Usage:
#   DRY_RUN=1 ./migrate-minio.sh                         # default — prints only
#   DRY_RUN=0 SRC_MINIO_URL=http://127.0.0.1:9000 \
#             DST_MINIO_URL=http://127.0.0.1:19000 ./migrate-minio.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

# Endpoints reachable from wherever mc runs. Defaults assume the runbook set up:
#   source = host loopback to compose minio (publish or `docker run --network`),
#   target = `kubectl port-forward svc/gt-minio 19000:9000`.
SRC_MINIO_URL="${SRC_MINIO_URL:-http://127.0.0.1:9000}"
DST_MINIO_URL="${DST_MINIO_URL:-http://127.0.0.1:19000}"
# Target creds default to the source creds (same chart secret values); override
# if the k8s MinIO uses different MINIO_ROOT_*.
DST_MINIO_USER="${DST_MINIO_USER:-$MINIO_ROOT_USER}"
DST_MINIO_PASSWORD="${DST_MINIO_PASSWORD:-$MINIO_ROOT_PASSWORD}"

# Run mc inside a one-shot minio/mc container so the host needs no mc binary.
MC_IMAGE="${MC_IMAGE:-minio/mc:latest}"
# `mc` invocation: chains alias-set for both stores then runs the passed mc args.
mc() {  # mc <mc-args...>
  docker run --rm --network "${MC_NETWORK:-host}" "$MC_IMAGE" sh -c "
    mc alias set src '$SRC_MINIO_URL' '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null &&
    mc alias set dst '$DST_MINIO_URL' '$DST_MINIO_USER' '$DST_MINIO_PASSWORD' >/dev/null &&
    $*"
}

mirror() {
  quiesce_note
  log "ensuring target bucket dst/$GT_BLOB_BUCKET exists"
  run docker run --rm --network "${MC_NETWORK:-host}" "$MC_IMAGE" sh -c "
    mc alias set dst '$DST_MINIO_URL' '$DST_MINIO_USER' '$DST_MINIO_PASSWORD' >/dev/null &&
    mc mb --ignore-existing dst/$GT_BLOB_BUCKET"
  log "mirroring src/$GT_BLOB_BUCKET → dst/$GT_BLOB_BUCKET"
  # --overwrite + (default) skip-unchanged ⇒ idempotent; --preserve keeps metadata.
  run docker run --rm --network "${MC_NETWORK:-host}" "$MC_IMAGE" sh -c "
    mc alias set src '$SRC_MINIO_URL' '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null &&
    mc alias set dst '$DST_MINIO_URL' '$DST_MINIO_USER' '$DST_MINIO_PASSWORD' >/dev/null &&
    mc mirror --overwrite --preserve src/$GT_BLOB_BUCKET dst/$GT_BLOB_BUCKET"
}

# Object count + total size via `mc du` (recursive). Read-only — runs in dry-run.
bucket_stats() {  # bucket_stats <alias>
  docker run --rm --network "${MC_NETWORK:-host}" "$MC_IMAGE" sh -c "
    mc alias set src '$SRC_MINIO_URL' '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null 2>&1 || true;
    mc alias set dst '$DST_MINIO_URL' '$DST_MINIO_USER' '$DST_MINIO_PASSWORD' >/dev/null 2>&1 || true;
    mc du --recursive '$1/$GT_BLOB_BUCKET'" 2>/dev/null | tail -1
}

verify() {
  log "VERIFY minio: src/$GT_BLOB_BUCKET vs dst/$GT_BLOB_BUCKET"
  local s d
  s="$(bucket_stats src)"; d="$(bucket_stats dst)"
  # `mc du` last line: "<size> <N> objects <path>" — compare size + object count.
  log "src du: $s"
  log "dst du: $d"
  local s_sz s_n d_sz d_n
  s_sz="$(printf '%s' "$s" | awk '{print $1}')"; s_n="$(printf '%s' "$s" | awk '{print $2}')"
  d_sz="$(printf '%s' "$d" | awk '{print $1}')"; d_n="$(printf '%s' "$d" | awk '{print $2}')"
  if [ "$s_sz" = "$d_sz" ] && [ "$s_n" = "$d_n" ]; then
    log "VERIFY OK (size $s_sz, objects $s_n match)"
  else
    die "VERIFY FAILED — src(size=$s_sz,n=$s_n) != dst(size=$d_sz,n=$d_n); keep the old minio volume"
  fi
}

main() {
  require_cmd docker
  ensure_workdir
  case "${1:-all}" in
    mirror)  mirror ;;
    verify)  verify ;;
    all)     mirror; verify ;;
    *) die "usage: $0 [mirror|verify|all]" ;;
  esac
}
main "$@"
