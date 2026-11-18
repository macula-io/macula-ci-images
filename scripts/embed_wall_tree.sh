#!/usr/bin/env bash
# Write the wall-to-tree check into the workflow that runs it:
# scripts/wall_tree.py into .github/workflows/wall-tree.yml.
#
# A reusable workflow runs in the CALLER's repository, so a step cannot run a
# script from this one: the path is not there. The check therefore travels
# inside the workflow, between two markers, as the c4-model and release-guard
# checks do, and this writes the block. The test fails when the embedded copy
# is not byte for byte the script, so the two cannot drift apart quietly.
#
# The rule the check imports (folders_from_wall) is not embedded: it lives in
# mcl-corpus, pinned to philosophy/EVENT_STORMING.md there, and the workflow
# checks it out at a pinned sha. Embedding it too would restate it and let the
# two copies drift.
#
# Usage: scripts/embed_wall_tree.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$HERE/wall_tree.py"
MARK="WALL_TREE_SCRIPT"

embed() {
WORKFLOW="$1"
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
  return 1
fi
chmod --reference="$WORKFLOW" "$tmp"
mv "$tmp" "$WORKFLOW"
echo "embed: wrote wall_tree.py into $WORKFLOW"
}

embed "$ROOT/.github/workflows/wall-tree.yml"
