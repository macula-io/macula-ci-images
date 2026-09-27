#!/usr/bin/env bash
# Do two local images have identical layers? If not, which files differ?
#
# reproducibility.yml builds each base image twice from the same inputs and
# runs this on the two results. Exit 0 when every layer's diff_id matches.
# Otherwise print each layer's verdict, name the files whose content differs
# (sha256 of every regular file and symlink, skipping what a container mounts
# at run time), and exit 1. An unreadable file is skipped, never fatal: the
# listing only names the cause, and the layers have already been compared.
#
# Usage: scripts/compare_image_layers.sh <image-a> <image-b>
#   ENGINE=docker (default; podman works too)
set -euo pipefail

A="${1:?usage: $0 <image-a> <image-b>}"
B="${2:?usage: $0 <image-a> <image-b>}"
ENGINE="${ENGINE:-docker}"

layers() { "$ENGINE" image inspect "$1" --format '{{json .RootFS.Layers}}'; }

if python3 - "$(layers "$A")" "$(layers "$B")" <<'PY'
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
for i in range(max(len(a), len(b))):
    x = a[i] if i < len(a) else "-"
    y = b[i] if i < len(b) else "-"
    print(f"layer {i}: {'same' if x == y else 'DIFFERENT'}  {x}  {y}")
if a != b:
    print("REFUSED: two uncached builds of the same inputs gave different layers")
    sys.exit(1)
print(f"IDENTICAL: {len(a)} layers")
PY
then
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for side in A B; do
    image="${!side}"
    "$ENGINE" run --rm --network=none --entrypoint sh "$image" -c \
        'find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /etc/hostname \
                        -o -path /etc/hosts -o -path /etc/resolv.conf -o -path /etc/mtab \) -prune \
              -o \( -type f -o -type l \) -print0 2>/dev/null \
         | sort -z | xargs -0 sha256sum 2>/dev/null; true' > "$WORK/$side"
done
echo "files that differ:"
diff "$WORK/A" "$WORK/B" | grep '^[<>]' | awk '{print $3}' | sort -u | head -80 || true
exit 1
