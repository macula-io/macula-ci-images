#!/usr/bin/env bash
# Does the wall-tree check pass a Division whose tree matches its wall, and fail
# each way of not matching, naming the note or the folder?
#
# The cases run against the check AS EMBEDDED IN wall-tree.yml, which is the copy
# a caller executes, extracted by its markers. Two checks first say the embedded
# block is scripts/wall_tree.py byte for byte and the workflow is valid YAML.
#
# The rule the check imports lives in mcl-corpus; this also runs its pin
# (test_folders_from_wall.py) and its mutation test, so the rule cannot drift
# from philosophy/EVENT_STORMING.md while the check still passes.
#
# Every case is a throwaway Division, copied from the committed fixture and then
# perturbed; nothing is read from this repository's own tree but the fixture.
#
# Usage: scripts/test_wall_tree.sh CORPUS [--verbose]
#   CORPUS is an mcl-corpus checkout at the pinned sha.
set -uo pipefail
# No bytecode is cached: the corpus's mutant runs rewrite and restore its rule,
# and a stale .pyc of a mutant must never be what a later case imports.
export PYTHONDONTWRITEBYTECODE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$HERE/wall_tree.py"
WORKFLOW="$ROOT/.github/workflows/wall-tree.yml"
SELFTEST="$ROOT/.github/workflows/wall-tree-selftest.yml"
FIXTURE="$HERE/fixtures/wall_tree/service"
CORPUS="${1:?usage: test_wall_tree.sh CORPUS [--verbose]}"
VERBOSE=0
[ "${2:-}" = "--verbose" ] && VERBOSE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CHECK="$WORK/wall_tree.py"

failures=0
cases=0

run_case() {
  local name="$1" expected="$2" want="$3" out status
  shift 3
  cases=$((cases + 1))
  out="$("$@" 2>&1)"
  status=$?
  if [ "$status" -eq "$expected" ] && { [ -z "$want" ] || grep -qF -- "$want" <<< "$out"; }; then
    printf 'ok   %-62s exit %s\n' "$name" "$status"
  else
    printf 'FAIL %-62s exit %s, expected %s%s\n' "$name" "$status" "$expected" \
      "${want:+ and \"$want\"}"
    failures=$((failures + 1))
  fi
  if [ "$VERBOSE" -eq 1 ] || [ "$status" -ne "$expected" ]; then
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

check() {
  local name="$1"
  shift
  cases=$((cases + 1))
  if "$@" > /dev/null 2>&1; then
    printf 'ok   %-62s\n' "$name"
  else
    printf 'FAIL %-62s\n' "$name"
    failures=$((failures + 1))
  fi
}

# extract <workflow>: the check as that workflow embeds it, by its markers.
extract() {
  awk -v open_mark="<<'WALL_TREE_SCRIPT'" -v close_mark="WALL_TREE_SCRIPT" '
    index($0, open_mark) && index($0, "cat > ") {
      pad = substr($0, 1, index($0, "cat") - 1)
      inside = 1
      next
    }
    inside && $0 == pad close_mark { inside = 0; next }
    inside {
      if (substr($0, 1, length(pad)) == pad) print substr($0, length(pad) + 1)
      else print
    }
  ' "$1"
}
extract "$WORKFLOW" > "$CHECK"

check "the block in wall-tree.yml is the script" cmp -s "$SOURCE" "$CHECK"
check "wall_tree.py parses" \
  python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$SOURCE"
check "wall-tree.yml is valid YAML" \
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WORKFLOW"

# The rule the check imports is pinned in the corpus, and the workflow checks it
# out at one sha. The selftest must check out the same sha, or what it proves is
# not what a caller runs.
sha_from_wall="$(sed -n "s/^[[:space:]]*default: '\([0-9a-f]\{40\}\)'$/\1/p" "$WORKFLOW" | head -1)"
check "the selftest checks out the corpus at the workflow's pinned sha" \
  grep -qF "$sha_from_wall" "$SELFTEST"

# The rule itself, held to the page (and every rule mutant killed), so the check
# cannot pass against a rule that drifted.
check "the rule matches philosophy/EVENT_STORMING.md" \
  python3 "$CORPUS/assets/test_folders_from_wall.py"
check "every rule mutant is killed" \
  python3 "$CORPUS/assets/mutants_folders_from_wall.py"
check "the wall's shape is refused by JSON path" \
  python3 "$CORPUS/assets/test_wall_schema.py"
check "every schema-reader mutant is killed" \
  python3 "$CORPUS/assets/mutants_wall_schema.py"

# A FRESH DIVISION PER CASE, from the committed fixture: a wall.json and the
# tree its three applications must have. `new_case; dir="$DIR"` runs in a
# subshell, so its counter never moves and every case rewrites the first one.
n=0
DIR=""
new_case() {
  n=$((n + 1))
  DIR="$WORK/case$n"
  cp -r "$FIXTURE" "$DIR"
}

new_case
run_case "the wall and the tree agree passes" 0 "" \
  python3 "$CHECK" --root "$DIR" --corpus "$CORPUS"

new_case; dir="$DIR"; rm -rf "$dir/apps/host_demo/src/open_account"
run_case "a missing desk folder fails, naming it" 1 \
  "open_account: a note asks for this folder and it is missing" \
  python3 "$CHECK" --root "$dir" --corpus "$CORPUS"

new_case; dir="$DIR"; mkdir -p "$dir/apps/host_demo/src/bogus_note"
run_case "a folder no note asks for fails, naming it" 1 \
  "bogus_note: a folder no note asks for" \
  python3 "$CHECK" --root "$dir" --corpus "$CORPUS"

new_case; dir="$DIR"; rm "$dir/wall.json"
run_case "no wall.json fails" 1 "no wall.json" \
  python3 "$CHECK" --root "$dir" --corpus "$CORPUS"

# A wall the rule refuses (a multi-input policy has no decided folder name) is
# refused through the check too, not passed silently.
new_case; dir="$DIR"
python3 - "$dir/wall.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
wall = json.loads(p.read_text())
wall["policies"] = [{"on": ["account_opened_v1", "account_closed_v1"], "maybe": "greet_member"}]
p.write_text(json.dumps(wall, indent=2))
PY
run_case "a wall the rule refuses is refused through the check" 1 \
  "no decided folder name" python3 "$CHECK" --root "$dir" --corpus "$CORPUS"

# Two desks of one name would collapse into one folder; the rule refuses it, and
# a repeated lane is refused by the schema's uniqueItems, both through the check.
new_case; dir="$DIR"
python3 - "$dir/wall.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
wall = json.loads(p.read_text())
wall["desks"].append(dict(wall["desks"][0]))
p.write_text(json.dumps(wall, indent=2))
PY
run_case "a desk named twice is refused through the check" 1 \
  "open_account more than once in cmd" python3 "$CHECK" --root "$dir" --corpus "$CORPUS"

new_case; dir="$DIR"
python3 - "$dir/wall.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
wall = json.loads(p.read_text())
wall["lanes"].append(wall["lanes"][0])
p.write_text(json.dumps(wall, indent=2))
PY
run_case "a repeated lane is refused through the check" 1 \
  "/lanes/1: repeats /lanes/0" python3 "$CHECK" --root "$dir" --corpus "$CORPUS"

# The wall holds names only (mcl-whiteboard#14, Demon 75): the schema's reader
# refuses an extra key and a non-name value through the check, by JSON path,
# before the rule runs.
new_case; dir="$DIR"
python3 - "$dir/wall.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
wall = json.loads(p.read_text())
wall["pipeline"] = ["validate", "persist"]
p.write_text(json.dumps(wall, indent=2))
PY
run_case "an extra key is refused, naming it" 1 \
  "/pipeline: not a name the schema allows" python3 "$CHECK" --root "$dir" --corpus "$CORPUS"

new_case; dir="$DIR"
python3 - "$dir/wall.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
wall = json.loads(p.read_text())
wall["desks"][0]["event"] = {"type": "event"}
p.write_text(json.dumps(wall, indent=2))
PY
run_case "a field-typed event is refused, naming it" 1 \
  "/desks/0/event: expected string, got object" python3 "$CHECK" --root "$dir" --corpus "$CORPUS"

new_case; dir="$DIR"; printf 'not json' > "$dir/wall.json"
run_case "a wall that is not valid JSON is refused" 1 "is not valid JSON" \
  python3 "$CHECK" --root "$dir" --corpus "$CORPUS"

printf '\n'
if [ "$failures" -eq 0 ]; then
  printf 'wall_tree: %d cases passed\n' "$cases"
  exit 0
fi
printf 'wall_tree: %d of %d cases FAILED\n' "$failures" "$cases"
exit 1
