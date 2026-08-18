#!/bin/bash
# Pull every external Docker image the sleep_test stack needs and get them
# onto a target that has no internet.
# Adapted from METOC_BUOY tools/pull_deploy_images.sh.
#
# Run on a machine WITH internet (e.g. the GCS laptop):
#   ./tools/pull_deploy_images.sh                        # pull + save tarball
#   ./tools/pull_deploy_images.sh torizon@192.168.1.11   # pull + ship + load
#
# The image list is discovered from compose.yaml (image:) and every service
# Dockerfile (FROM), so it stays correct as services are added. All pulls
# force linux/arm64 — the buoy is an Apalis iMX8; a default pull on an x86
# laptop would ship useless amd64 layers.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-}"
OUT="${2:-sleep_test_images.tgz}"

IMAGES=$(
  { grep -hE '^\s*image:' compose.yaml | awk '{print $2}'
    find services -maxdepth 2 -name Dockerfile \
        -exec grep -hE '^FROM ' {} + | awk '{print $2}'
  } | grep -v '^scratch$' | sort -u)

echo "Images required by the sleep_test stack:"
echo "$IMAGES" | sed 's/^/  /'

for img in $IMAGES; do
    echo ""
    echo ">> pulling $img (linux/arm64)"
    docker pull --platform linux/arm64 "$img"
done

echo ""
echo ">> saving to $OUT (this can take a while)"
# Multi-arch trap: if amd64 layers were ever cached under these tags, plain
# docker save can fail with "unable to create manifest / content digest".
# Newer Docker can save a single platform explicitly; on older Docker the
# cure is removing the stale tag and re-pulling arm64.
# shellcheck disable=SC2086
if docker save --help 2>/dev/null | grep -q -- '--platform'; then
    docker save --platform linux/arm64 $IMAGES | gzip > "$OUT"
else
    docker save $IMAGES | gzip > "$OUT"
fi
ls -lh "$OUT"

# The arm64 pulls above overwrote this machine's local tags — if the stack
# here uses any of the same images (postgres), running them would now hit
# "exec format error". Restore the host-platform variants.
echo ""
echo ">> restoring host-platform tags"
for img in $IMAGES; do
    docker pull "$img" >/dev/null 2>&1 || true
done

if [ -n "$DEST" ]; then
    echo ""
    echo ">> shipping to $DEST and loading"
    scp "$OUT" "$DEST:~/"
    ssh "$DEST" "gunzip -c ~/$(basename "$OUT") | docker load && rm ~/$(basename "$OUT")"
    echo "done — images loaded on $DEST"
else
    echo ""
    echo "Next: scp $OUT torizon@<target>:~ && ssh torizon@<target> 'gunzip -c ~/$OUT | docker load'"
fi
