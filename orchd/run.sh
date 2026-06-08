#!/usr/bin/env bash
# gt-orch-server launcher — hq-orchd-deploy.1
#
# OFF BY DEFAULT. This script is NOT auto-started and NOT wired into any compose/systemd unit.
# The daemon spawns REAL paid claude processes (each polecat/dog = cost). Do NOT enable until:
#   .2 tmux + authenticated claude + rig checkout present on host
#   .3 GT_EVENTLOG_ROOT readable/writable (root-owned docker volume)
#   .4 dispatch trigger defined        .7 gastown hooks installed in the rig
#   .8 skills->scopes least-privilege  .5 explicit operator GO
#
# Needs access to the root-owned docker eventlog volume -> run as root (sudo).
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./orchd.env; set +a
echo "[run.sh] launching gt-orch-server (workspace=$GT_WORKSPACE, pool=$GT_POOL_SIZE, eventlog=$GT_EVENTLOG_ROOT)"
exec ./gt-orch-server
