#!/usr/bin/env bash
# Are two local images the same image: the same layers AND the same config?
# If not, which files or config fields differ?
#
# reproducibility.yml builds each base image twice from the same inputs and
# runs this on the two results. The config is compared, not only the layers,
# because its digest is part of the manifest digest a consumer pins: a label
# or a created time that moves gives the same layers a new digest.
#
# Exit 0 when every layer's diff_id AND the config digest (the image id)
# match. Otherwise print each layer's verdict; if the layers differ, name the
# files whose content differs (sha256 of every regular file and symlink,
# skipping what a container mounts at run time); if only the config differs,
# print the config fields and history entries that differ; and exit 1. An
# unreadable file is skipped, never fatal: the listing only names the cause.
#
# Usage: scripts/compare_image_layers.sh <image-a> <image-b>
#   ENGINE=docker (default; podman works too)
set -euo pipefail

A="${1:?usage: $0 <image-a> <image-b>}"
B="${2:?usage: $0 <image-a> <image-b>}"
ENGINE="${ENGINE:-docker}"

layers() { "$ENGINE" image inspect "$1" --format '{{json .RootFS.Layers}}'; }
config_id() { "$ENGINE" image inspect "$1" --format '{{.Id}}'; }

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
print(f"same layers: {len(a)}")
PY
then
    ID_A="$(config_id "$A")"
    ID_B="$(config_id "$B")"
    if [ "$ID_A" = "$ID_B" ]; then
        echo "IDENTICAL: same layers and the same config ($ID_A)"
        exit 0
    fi
    echo "REFUSED: same layers, but the config differs ($ID_A vs $ID_B)"
    echo "config fields that differ:"
    python3 - "$("$ENGINE" image inspect "$A" --format '{{json .}}')" \
              "$("$ENGINE" image inspect "$B" --format '{{json .}}')" <<'PY'
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
def flat(v, path=""):
    if isinstance(v, dict):
        for k, x in v.items():
            yield from flat(x, f"{path}.{k}")
    else:
        yield path, v
fa = dict(flat({"Created": a.get("Created"), "Config": a.get("Config")}))
fb = dict(flat({"Created": b.get("Created"), "Config": b.get("Config")}))
for k in sorted(set(fa) | set(fb)):
    if fa.get(k) != fb.get(k):
        print(f"  {k}: {fa.get(k)!r}  {fb.get(k)!r}")
PY
    echo "history entries that differ:"
    diff <("$ENGINE" history --no-trunc --format '{{.CreatedAt}} {{.CreatedBy}}' "$A") \
         <("$ENGINE" history --no-trunc --format '{{.CreatedAt}} {{.CreatedBy}}' "$B") \
        | grep '^[<>]' | head -40 || true
    exit 1
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
# "< <sha256>  <path>": strip the marker and the hash, keep the whole path.
diff "$WORK/A" "$WORK/B" | grep '^[<>]' | sed -E 's/^[<>] [0-9a-f]{64}  //' | sort -u | head -80 || true
exit 1
