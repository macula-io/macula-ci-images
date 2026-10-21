#!/usr/bin/env bash
# Write the C4 model check into the workflow that runs it: scripts/c4_model.sh
# into .github/workflows/c4-model.yml.
#
# A reusable workflow runs in the CALLER's repository, so a step cannot run a
# script from this one: the path is not there. The check therefore travels
# inside the workflow, between two markers, as the release guard and the
# doc-snippets checks do, and this writes the block. The test fails when the
# embedded copy is not byte for byte the script, so the two cannot drift apart
# quietly.
#
# Usage: scripts/embed_c4_model.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$HERE/c4_model.sh"
WORKFLOW="$ROOT/.github/workflows/c4-model.yml"
MARK="C4_MODEL_SCRIPT"

tmp="$(mktemp)"
if ! awk -v src="$SOURCE" -v open_mark="<<'$MARK'" -v close_mark="$MARK" '
  BEGIN {
    n = 0
    while ((getline line < src) > 0) block[++n] = line
    if (n == 0) { print "embed: " src " is empty" > "/dev/stderr"; exit 1 }
  }
  inside {
    if ($0 == pad close_mark) {
      for (i = 1; i <= n; i++) print (block[i] == "" ? "" : pad block[i])
      print
      inside = 0
      next
    }
    next
  }
  index($0, open_mark) && index($0, "cat > ") {
    pad = substr($0, 1, index($0, "cat") - 1)
    print
    inside = 1
    blocks++
    next
  }
  { print }
  END {
    if (inside) { print "embed: no closing marker in " FILENAME > "/dev/stderr"; exit 1 }
    if (blocks != 1) { print "embed: expected one marked block in " FILENAME > "/dev/stderr"; exit 1 }
  }
' "$WORKFLOW" > "$tmp"; then
  rm -f "$tmp"
  exit 1
fi
chmod --reference="$WORKFLOW" "$tmp"
mv "$tmp" "$WORKFLOW"
echo "embed: wrote c4_model.sh into $WORKFLOW"
