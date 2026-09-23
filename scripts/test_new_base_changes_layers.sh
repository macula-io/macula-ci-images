#!/usr/bin/env bash
# Does moving an image to a newer dated Debian base actually change it?
#
# The scheduled rebuild exists to carry Debian security updates. It used to
# reproduce identical layers every day, served from cache, while every run
# went green. This builds one Containerfile on two dated bases and refuses
# unless both builds pass the Containerfile's own tool assertions AND the two
# images differ in their layers, base included.
#
# Uses podman (on host00, `docker' is rootless podman's compat API, which
# gives containers pids.max=1). Override with ENGINE=docker elsewhere.
#
# Usage: scripts/test_new_base_changes_layers.sh <Containerfile> <older> <newer>
#   e.g. scripts/test_new_base_changes_layers.sh Containerfile.ci-otp \
#          trixie-20260824-slim trixie-20260918-slim
set -uo pipefail

FILE="${1:?usage: $0 <Containerfile> <older-debian> <newer-debian>}"
OLDER="${2:?older DEBIAN_VERSION}"
NEWER="${3:?newer DEBIAN_VERSION}"
ENGINE="${ENGINE:-podman}"
TAG="local/base-layer-test"

build() {
    "$ENGINE" build -q -f "$FILE" --build-arg "DEBIAN_VERSION=$1" -t "$TAG:$1" . \
        || { echo "REFUSED: $FILE does not build on DEBIAN_VERSION=$1"; exit 1; }
}
layers() { "$ENGINE" image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$TAG:$1"; }

build "$OLDER" >/dev/null
build "$NEWER" >/dev/null
A="$(layers "$OLDER")"
B="$(layers "$NEWER")"

[ -n "$A" ] && [ -n "$B" ] || { echo "REFUSED: could not read the images' layers"; exit 1; }
[ "$A" != "$B" ] || { echo "REFUSED: $OLDER and $NEWER produced IDENTICAL layers"; exit 1; }
[ "$(head -1 <<< "$A")" != "$(head -1 <<< "$B")" ] \
    || { echo "REFUSED: the base layer did not change between $OLDER and $NEWER"; exit 1; }

echo "OK: $FILE on $OLDER and $NEWER builds green on both, and every layer from the base up differs ($(wc -l <<< "$A") vs $(wc -l <<< "$B") layers)."
