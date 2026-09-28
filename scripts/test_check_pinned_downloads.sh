#!/usr/bin/env bash
# Does check_pinned_downloads.py pass verified downloads and refuse the rest?
#
# Fixtures in scripts/fixtures/pinned_downloads/:
#   Containerfile.verified          curl -o with a literal sha256, wget -O with a
#                                   ${ARG} sha512, each checked by the next command;
#                                   a RUN without a download may use ||: passes
#   Containerfile.piped             curl ... | sh
#   Containerfile.unchecked         curl -o FILE, FILE never checked
#   Containerfile.wget-log-flag     wget -o is its LOG, not the download
#   Containerfile.fetched-sum       the sum itself is fetched: echo "$(curl ...)  FILE"
#   Containerfile.short-sum         the sum is not a full digest or an ${ARG}
#   Containerfile.run-before-check  the file runs before it is checked
#   Containerfile.ignored-check     ( check || true ): a failed check is ignored
#   Containerfile.shell-c           bash -c "curl ... | sh": a shell's -c string
#   Containerfile.wrapped           env curl, timeout 60 wget, /usr/bin/curl, bash < <(curl ...)
#   Containerfile.undeclared-arg    the sum is ${NOPE}, declared nowhere
# (the verified fixture also installs curl with apt-get, which is not a fetch)
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

refused Containerfile.piped "curl piped into another command"
refused Containerfile.unchecked "/tmp/a.tgz is downloaded but not checked"
refused Containerfile.wget-log-flag "wget without -O FILE"
refused Containerfile.fetched-sum "a download inside a command substitution"
refused Containerfile.fetched-sum "is not pinned"
refused Containerfile.short-sum "the sum 'abc' is not pinned"
refused Containerfile.run-before-check "the command after the download is not sha256sum/sha512sum -c"
refused Containerfile.ignored-check "must be one && chain"
refused Containerfile.shell-c "curl piped into another command"
refused Containerfile.wrapped "Containerfile.wrapped:2: curl is a download not at the head of its command"
refused Containerfile.wrapped "Containerfile.wrapped:3: wget is a download not at the head of its command"
refused Containerfile.wrapped "Containerfile.wrapped:4: curl piped into another command"
refused Containerfile.wrapped "Containerfile.wrapped:5: curl is a download not at the head of its command"
refused Containerfile.undeclared-arg "names no ARG declared with a default"

echo "OK: check_pinned_downloads.py passes verified downloads and names every unverified one"
