#!/usr/bin/env bash
# The labels every published base image carries, one per line, for
# docker/build-push-action's `labels:` input.
#
# build.yml publishes with these and reproducibility.yml proves with these, so
# the image the check builds twice is the image that ships, config included.
# A label is part of the image config, and the config digest is part of the
# manifest digest: one label that moves between builds of the same inputs
# (a build time, a commit sha) gives a consumer pinning by digest a "new"
# image every day. So every label here is a function of the inputs only:
#   - created is SOURCE_DATE_EPOCH (the dated Debian base's midnight UTC),
#     not the build time;
#   - there is no revision: a commit that changes no content must not move
#     the image, and the dated tag already names the build.
# docker/metadata-action's labels are NOT used for exactly those two reasons.
#
# Usage: scripts/image_labels.sh <title> <source-date-epoch> [key=value ...]
#   extra key=value arguments are appended as they are (io.macula.* labels)
set -euo pipefail

TITLE="${1:?usage: $0 <title> <source-date-epoch> [key=value ...]}"
EPOCH="${2:?usage: $0 <title> <source-date-epoch> [key=value ...]}"
shift 2
SOURCE="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-macula-io/macula-ci-images}"

[[ "$EPOCH" =~ ^[0-9]+$ ]] || { echo "REFUSED: source-date-epoch '$EPOCH' is not a number" >&2; exit 1; }

echo "org.opencontainers.image.title=${TITLE}"
echo "org.opencontainers.image.source=${SOURCE}"
echo "org.opencontainers.image.created=$(date -u -d "@${EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
for label in "$@"; do
    [[ "$label" == *=* ]] || { echo "REFUSED: label '$label' is not key=value" >&2; exit 1; }
    echo "$label"
done
