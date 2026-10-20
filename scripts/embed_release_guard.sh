#!/usr/bin/env bash
# Write scripts/release_guard.sh into every workflow that runs it.
#
# A reusable workflow runs in the CALLER's repository, so a step cannot run
# ./scripts/release_guard.sh: that file is not ours there, so every release would die
# with exit 127, and worse, a tag that skipped review could carry its own copy of that
# path and choose its own guard. The checks therefore travel inside the workflow,
# between two markers, and this script writes the block. scripts/test_release_guard.sh
# fails when an embedded copy is not byte for byte the script, so the copies cannot
# drift apart quietly.
#
# Usage: scripts/embed_release_guard.sh [workflow...]
#   With no argument, every workflow that embeds the guard is rewritten in place.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$HERE/release_guard.sh"
OPEN_MARK="<<'RELEASE_GUARD_SCRIPT'"
CLOSE_MARK="RELEASE_GUARD_SCRIPT"

workflows=("$@")
if [ "${#workflows[@]}" -eq 0 ]; then
  workflows=(
    "$ROOT/.github/workflows/release-guard.yml"
    "$ROOT/.github/workflows/attest-image.yml"
  )
fi

# embed <workflow>
# Replaces every marked block with the script, at the indentation of its `cat` line,
# which is the indentation YAML strips from the run step. An empty source line stays
# empty rather than becoming trailing whitespace.
embed() {
  local workflow="$1" tmp
  tmp="$(mktemp)"

  if ! awk -v src="$SOURCE" -v open_mark="$OPEN_MARK" -v close_mark="$CLOSE_MARK" '
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
      if (blocks == 0) { print "embed: no marked block in " FILENAME > "/dev/stderr"; exit 1 }
    }
  ' "$workflow" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  chmod --reference="$workflow" "$tmp"
  mv "$tmp" "$workflow"
}

status=0
for workflow in "${workflows[@]}"; do
  [ -f "$workflow" ] || { echo "embed: no such workflow: $workflow" >&2; status=1; continue; }
  if embed "$workflow"; then
    echo "embed: wrote $(basename "$SOURCE") into $workflow"
  else
    status=1
  fi
done

exit "$status"
