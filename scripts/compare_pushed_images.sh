#!/usr/bin/env bash
# Did two pushes of the same inputs give the same manifest digest?
#
# The manifest digest is what a consumer pins, so it is the verdict. Before
# giving it, both images are pulled and compare_image_layers.sh names what
# moved (files, or config fields and history), so a mismatch arrives with its
# cause. reproducibility.yml runs this on the two builds it pushed to the
# job-local registry.
#
# Usage: scripts/compare_pushed_images.sh <ref-a> <ref-b>
set -euo pipefail

A="${1:?usage: $0 <ref-a> <ref-b>}"
B="${2:?usage: $0 <ref-a> <ref-b>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

digest() {
    local d
    d="$(docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r .digest)"
    case "$d" in
        sha256:*) echo "$d" ;;
        *) echo "REFUSED: no manifest digest for $1 ('$d')" >&2; exit 1 ;;
    esac
}

DA="$(digest "$A")"
DB="$(digest "$B")"

docker pull -q "$A" >/dev/null
docker pull -q "$B" >/dev/null
CAUSE=0
bash "$HERE/compare_image_layers.sh" "$A" "$B" || CAUSE=1

if [ "$DA" = "$DB" ]; then
    [ "$CAUSE" -eq 0 ] || { echo "REFUSED: the manifest digests match ($DA) but the images do not"; exit 1; }
    echo "SAME MANIFEST DIGEST: $DA"
    exit 0
fi
echo "REFUSED: two builds of the same inputs gave different manifest digests: $DA vs $DB"
exit 1
