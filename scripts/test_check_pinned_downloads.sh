#!/usr/bin/env bash
# Does check_pinned_downloads.py pass verified downloads and refuse the rest?
#
# Fixtures in scripts/fixtures/pinned_downloads/:
#   Containerfile.verified        curl -o and wget -O, each checked by sha*sum -c; apt: passes
#   Containerfile.piped           curl ... | sh: refused as piped into a shell
#   Containerfile.unchecked       curl -o FILE, FILE never checked: refused
#   Containerfile.wget-log-flag   wget -o is its LOG, not the download: refused
#
# Usage: scripts/test_check_pinned_downloads.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/check_pinned_downloads.py"
FIX="$HERE/fixtures/pinned_downloads"

fail() { echo "REFUSED: $*"; exit 1; }

OUT=$(python3 "$CHECK" "$FIX/Containerfile.verified" 2>&1) || fail "verified downloads were refused: $OUT"
grep -q "^OK: " <<<"$OUT" || fail "verified downloads were not reported OK: $OUT"

refused() {
    local file="$1" reason="$2"
    OUT=$(python3 "$CHECK" "$FIX/$file" 2>&1) && fail "$file passed: $OUT"
    grep -qF "$reason" <<<"$OUT" || fail "$file was refused without naming '$reason': $OUT"
}

refused Containerfile.piped "piped into a shell"
refused Containerfile.unchecked "/tmp/a.tgz is downloaded but not checked"
refused Containerfile.wget-log-flag "wget without -O FILE"

echo "OK: check_pinned_downloads.py passes verified downloads and names every unverified one"
