#!/usr/bin/env bash
# Does compare_image_layers.sh pass identical images, and fail on different
# ones naming the file that differs?
#
# Builds three tiny images on debian:trixie-slim: two from the same inputs
# (rewrite-timestamp would not matter here; the files are written identically)
# and one whose only difference is one file's content.
#
# Usage: scripts/test_compare_image_layers.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPARE="$HERE/compare_image_layers.sh"
ENGINE="${ENGINE:-podman}"
export ENGINE
WORK="$(mktemp -d)"
TAG="compare-layers-test-$$"
trap '"$ENGINE" rmi -f "$TAG-a" "$TAG-b" "$TAG-c" >/dev/null 2>&1; rm -rf "$WORK"' EXIT

fail() { echo "REFUSED: $*"; exit 1; }

image() {
    printf 'FROM docker.io/library/debian:trixie-slim\nCOPY marker /opt/marker\n' > "$WORK/Containerfile"
    printf '%s\n' "$2" > "$WORK/marker"
    touch -d 2000-01-01 "$WORK/marker"
    "$ENGINE" build -q --timestamp 946684800 -f "$WORK/Containerfile" -t "$1" "$WORK" >/dev/null \
        || fail "could not build $1"
}

image "$TAG-a" same
image "$TAG-b" same
image "$TAG-c" different

OUT=$(bash "$COMPARE" "$TAG-a" "$TAG-b" 2>&1) || fail "identical images were refused: $OUT"
grep -q "^IDENTICAL: " <<<"$OUT" || fail "identical images were not reported IDENTICAL: $OUT"

OUT=$(bash "$COMPARE" "$TAG-a" "$TAG-c" 2>&1) && fail "different images passed: $OUT"
grep -q "REFUSED: two uncached builds" <<<"$OUT" || fail "the refusal was not named: $OUT"
grep -q "DIFFERENT" <<<"$OUT" || fail "no layer was reported DIFFERENT: $OUT"
sed -n '/^files that differ:/,$p' <<<"$OUT" | grep -qx "/opt/marker" \
    || fail "the differing file was not named: $OUT"

echo "OK: compare_image_layers.sh passes identical images and names what differs"
