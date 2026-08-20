#!/bin/bash
# Deploy this sleep_test directory onto a target (buoy / bench device).
# Adapted from METOC_BUOY tools/deploy_to_buoy.sh, minus the git/submodule
# checks (this directory is standalone, not a git checkout).
#
# Usage, from a machine that can reach the target:
#   ./tools/deploy_to_target.sh torizon@192.168.1.12
#   ./tools/deploy_to_target.sh torizon@192.168.1.12 my_remote_dir
#
# Updates ~/sleep_test on the target to match this directory exactly, EXCEPT:
#   - secrets/ is only sent if the target doesn't have it yet (--ignore-existing)
#   - config.env is never overwritten (holds the deployed SYSTEM_ID etc.);
#     a diff is printed so new/changed variables aren't missed
# Stale files that no longer exist here are deleted on the target.
set -euo pipefail

DEST="${1:?usage: ./deploy_to_target.sh user@target-ip [remote-dir]}"
RDIR="${2:-sleep_test}"
cd "$(dirname "$0")/.."

[ -f compose.yaml ] || { echo "ERROR: run from the sleep_test root"; exit 1; }

echo "== deploying sleep_test to $DEST:$RDIR"
rsync -av --delete \
    --exclude '.git' \
    --exclude '__pycache__' \
    --exclude 'secrets' \
    --exclude 'config.env' \
    --exclude 'logs' \
    --exclude '*.tgz' \
    ./ "$DEST:$RDIR/"

# First deploy: seed secrets and config.env without clobbering existing ones
rsync -av --ignore-existing secrets config.env "$DEST:$RDIR/"

echo ""
echo "== config.env: target vs local (target version is kept; merge new vars by hand)"
ssh "$DEST" "cat $RDIR/config.env" 2>/dev/null | diff - config.env \
    && echo "(identical)" || true

echo ""
echo "== done. On the target:"
echo "   ssh $DEST"
echo "   cd $RDIR && docker compose build && docker compose up -d"
