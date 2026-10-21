#!/usr/bin/env bash
# Write the dependency-advisories check into the workflow that runs it:
# scripts/dependency_advisories.py into .github/workflows/dependency-advisories.yml.
#
# A reusable workflow runs in the CALLER's repository, so a step cannot run a script
# from this one: the path is not there. The check therefore travels inside the
# workflow, between two markers, as the release guard and the doc-snippet checks do,
# and this writes the block. The self-test fails when the embedded copy is not byte
# for byte the script, so the two cannot drift apart quietly.
#
# Usage: scripts/embed_dependency_advisories.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# embed <source> <workflow> <marker>
# The marked block is replaced by the script at the indentation of its `cat` line,
# which is the indentation YAML strips from the run step. An empty source line stays
# empty rather than becoming trailing whitespace.
embed() {
  local source="$1" workflow="$2" mark="$3" tmp
  tmp="$(mktemp)"
  if ! awk -v src="$source" -v open_mark="<<'$mark'" -v close_mark="$mark" '
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
  ' "$workflow" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod --reference="$workflow" "$tmp"
  mv "$tmp" "$workflow"
  echo "embed: wrote $(basename "$source") into $workflow"
}

embed "$HERE/dependency_advisories.py" "$ROOT/.github/workflows/dependency-advisories.yml" \
  DEPENDENCY_ADVISORIES_SCRIPT
