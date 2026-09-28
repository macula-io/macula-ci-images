#!/usr/bin/env bash
# Does compare_image_layers.sh pass identical images, fail on different ones
# naming the file that differs, and fail on the same layers under a different
# config naming the config field?
#
# Builds four tiny images on debian:trixie-slim: two from the same inputs
# (rewrite-timestamp would not matter here; the files are written identically),
# one whose only difference is one file's content, and one whose only
# difference is a label.
#
# ENGINE is podman by default, unlike the comparator's docker: the fixed
# build time (--timestamp) is a podman build flag. The comparator itself only
# uses inspect, history and run, which both engines have.
#
# Usage: scripts/test_compare_image_layers.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPARE="$HERE/compare_image_layers.sh"
ENGINE="${ENGINE:-podman}"
export ENGINE
WORK="$(mktemp -d)"
TAG="compare-layers-test-$$"
trap '"$ENGINE" rmi -f "$TAG-a" "$TAG-b" "$TAG-c" "$TAG-d" >/dev/null 2>&1; rm -rf "$WORK"' EXIT

fail() { echo "REFUSED: $*"; exit 1; }

image() {
    printf 'FROM docker.io/library/debian:trixie-slim\nCOPY marker /opt/marker\n' > "$WORK/Containerfile"
    printf '%s\n' "$2" > "$WORK/marker"
    touch -d 2000-01-01 "$WORK/marker"
    "$ENGINE" build -q --timestamp 946684800 --label "io.macula.test=${3:-same}" \
        -f "$WORK/Containerfile" -t "$1" "$WORK" >/dev/null \
        || fail "could not build $1"
}

image "$TAG-a" same
image "$TAG-b" same
image "$TAG-c" different
image "$TAG-d" same moved

OUT=$(bash "$COMPARE" "$TAG-a" "$TAG-b" 2>&1) || fail "identical images were refused: $OUT"
grep -q "^IDENTICAL: " <<<"$OUT" || fail "identical images were not reported IDENTICAL: $OUT"

OUT=$(bash "$COMPARE" "$TAG-a" "$TAG-c" 2>&1) && fail "different images passed: $OUT"
grep -q "REFUSED: two uncached builds" <<<"$OUT" || fail "the refusal was not named: $OUT"
grep -q "DIFFERENT" <<<"$OUT" || fail "no layer was reported DIFFERENT: $OUT"
sed -n '/^files that differ:/,$p' <<<"$OUT" | grep -qx "/opt/marker" \
    || fail "the differing file was not named: $OUT"

OUT=$(bash "$COMPARE" "$TAG-a" "$TAG-d" 2>&1) && fail "a different config passed: $OUT"
grep -q "REFUSED: same layers, but the config differs" <<<"$OUT" || fail "the config refusal was not named: $OUT"
grep -q "io.macula.test" <<<"$OUT" || fail "the differing label was not named: $OUT"

echo "OK: compare_image_layers.sh passes identical images and names what differs, layers or config"
