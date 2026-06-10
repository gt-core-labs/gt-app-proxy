#!/usr/bin/env bash
# migrate-eventlog.sh — copy the event-sourced log + channels + heartbeats +
# onboarded claude accounts (the compose `gt-eventlog` volume, /var/lib/gt-core)
# into the k8s `gt-eventlog` PVC.
#
# The event log is APPEND-ONLY, file-based (NDJSON segments + .channels/
# .heartbeats/accounts/ subdirs + the fastembed model cache). A straight tar copy
# is the correct migration — no logical export needed. The ONLY hazard is a
# writer mutating it mid-copy, so it MUST be quiesced (see README): scale the API
# + daemon to 0, or stop the compose mcp-server/orchd, so the tarball is a
# consistent snapshot.
#
# Approach:
#   1. tar the source volume from inside the (stopped-writes) compose mcp-server
#      container → a tarball on the host.
#   2. start a one-shot helper pod that mounts ONLY the gt-eventlog PVC (so we
#      don't fight a running API pod for the RWO/RWX mount), `kubectl cp` the
#      tarball in, untar it, then delete the helper pod.
#
# Using a dedicated helper pod (not exec into a live API pod) avoids copying into
# a directory another process is writing, and works even when the API is scaled
# to 0 during the window.
#
# Source : docker exec gt-app-mcp-server tar   (reads the OLD volume)
# Target : helper pod mounting gt-eventlog PVC → untar (writes the NEW PVC)
#
# Verify : file count + a sorted sha256 manifest of the tree, src vs target.
#
# Usage:
#   DRY_RUN=1 ./migrate-eventlog.sh            # default — prints, writes nothing
#   DRY_RUN=0 ./migrate-eventlog.sh            # real migration (writes QUIESCED)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

TARBALL="$WORKDIR/eventlog.tar"
HELPER_POD="${HELPER_POD:-gt-eventlog-migrate}"
HELPER_MANIFEST="$HERE/manifests/eventlog-migrate-pod.yaml"
HELPER_MOUNT="/data"   # where the manifest mounts the PVC

pack() {
  ensure_workdir
  quiesce_note
  log "tarring $SRC_EVENTLOG_PATH from $SRC_MCP_CONTAINER"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[migrate][dry-run] docker exec %s tar -C %s -cf - . > %s\n' "$SRC_MCP_CONTAINER" "$SRC_EVENTLOG_PATH" "$TARBALL" >&2
    return 0
  fi
  # Exclude the fastembed model cache: it is a deterministic re-download, not data
  # (saves a few hundred MB and a slow copy). Drop the --exclude to carry it too.
  src_exec "$SRC_MCP_CONTAINER" tar -C "$SRC_EVENTLOG_PATH" --exclude=./fastembed -cf - . > "$TARBALL"
  log "tarball: $(wc -c <"$TARBALL") bytes → $TARBALL"
}

helper_up() {
  log "starting helper pod $HELPER_POD (mounts $DST_EVENTLOG_PVC)"
  run "$KCTL" -n "$K8S_NS" apply -f "$HELPER_MANIFEST"
  run "$KCTL" -n "$K8S_NS" wait --for=condition=Ready "pod/$HELPER_POD" --timeout=120s
}

helper_down() {
  log "deleting helper pod $HELPER_POD"
  run "$KCTL" -n "$K8S_NS" delete -f "$HELPER_MANIFEST" --ignore-not-found
}

unpack() {
  [ -s "$TARBALL" ] || { [ "$DRY_RUN" = "1" ] || die "tarball missing/empty: $TARBALL — run pack first"; }
  helper_up
  log "copying tarball into $HELPER_POD:$HELPER_MOUNT and untarring"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[migrate][dry-run] kubectl -n %s cp %s %s:/tmp/eventlog.tar\n' "$K8S_NS" "$TARBALL" "$HELPER_POD" >&2
    printf '[migrate][dry-run] kubectl -n %s exec %s -- tar -C %s -xf /tmp/eventlog.tar\n' "$K8S_NS" "$HELPER_POD" "$HELPER_MOUNT" >&2
    helper_down
    return 0
  fi
  "$KCTL" -n "$K8S_NS" cp "$TARBALL" "$HELPER_POD:/tmp/eventlog.tar"
  dst_exec "$HELPER_POD" tar -C "$HELPER_MOUNT" -xf /tmp/eventlog.tar
  dst_exec "$HELPER_POD" rm -f /tmp/eventlog.tar
  log "untar complete"
  # leave the helper pod up for verify(); verify() tears it down.
}

# A sorted sha256 manifest of the tree — order-independent integrity check.
src_manifest() { src_exec "$SRC_MCP_CONTAINER" sh -c "cd $SRC_EVENTLOG_PATH && find . -path ./fastembed -prune -o -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null"; }
dst_manifest() { dst_exec "$HELPER_POD" sh -c "cd $HELPER_MOUNT && find . -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null"; }

verify() {
  # verify needs the helper pod mounting the PVC.
  "$KCTL" -n "$K8S_NS" get pod "$HELPER_POD" >/dev/null 2>&1 || helper_up
  log "VERIFY eventlog: file manifest src vs dst"
  local s_man d_man s_n d_n s_sum d_sum
  s_man="$(src_manifest)"; d_man="$(dst_manifest)"
  s_n="$(printf '%s\n' "$s_man" | grep -c . || true)"
  d_n="$(printf '%s\n' "$d_man" | grep -c . || true)"
  # sha256 over the (path-stripped) per-file digests, sorted by path → a single
  # rollup hash that matches iff every file's content matches.
  s_sum="$(printf '%s\n' "$s_man" | awk '{print $1}' | sort | sha256sum | awk '{print $1}')"
  d_sum="$(printf '%s\n' "$d_man" | awk '{print $1}' | sort | sha256sum | awk '{print $1}')"
  log "files: src=$s_n dst=$d_n"
  log "rollup sha256: src=$s_sum dst=$d_sum"
  helper_down
  if [ "$s_n" = "$d_n" ] && [ "$s_sum" = "$d_sum" ]; then
    log "VERIFY OK (file count + content rollup match)"
  else
    die "VERIFY FAILED — keep the old gt-eventlog volume"
  fi
}

main() {
  preflight "$SRC_MCP_CONTAINER" "$DST_PG_POD"  # PG pod just proves cluster reachability
  case "${1:-all}" in
    pack)    pack ;;
    unpack)  unpack ;;
    verify)  verify ;;
    all)     pack; unpack; verify ;;
    *) die "usage: $0 [pack|unpack|verify|all]" ;;
  esac
}
main "$@"
