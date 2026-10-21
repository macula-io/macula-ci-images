#!/usr/bin/env bash
# Does the TypeScript doc-snippets check pass the blocks that type-check, and fail
# each kind of block that does not, at the doc line where it is wrong?
#
# The cases run against the check AS EMBEDDED IN doc-snippets-ts.yml, which is the
# copy a caller executes, extracted by its markers. Two checks first say that the
# embedded block is scripts/doc_snippets_ts.py byte for byte and that the workflow
# is valid YAML.
#
# The fixture is scripts/fixtures/doc_snippets/ts, a TypeScript package whose
# README and guide use every shape the check reads: a block with a top-level await
# and a value the prose made, a later block using what the prose made and listing
# alternatives, a JavaScript block, a skip with a reason, and an exported function
# of the reader's own. Each failing case appends one block to a copy of its README
# and states the exit code and the doc line the check must report.
#
# tsc must be on PATH; the interpreter is $PYTHON (default python3), which must
# have pyyaml.
#
# Usage: scripts/test_doc_snippets_ts.sh [--verbose]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$HERE/doc_snippets_ts.py"
WORKFLOW="$ROOT/.github/workflows/doc-snippets-ts.yml"
FIXTURE="$HERE/fixtures/doc_snippets/ts"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CHECK="$WORK/doc_snippets_ts.py"
PY="${PYTHON:-python3}"

failures=0
cases=0

# run_case <name> <expected exit> <expected text or ''> <command...>
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

awk -v open_mark="<<'DOC_SNIPPETS_TS_SCRIPT'" -v close_mark="DOC_SNIPPETS_TS_SCRIPT" '
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
' "$WORKFLOW" > "$CHECK"

check "the block in doc-snippets-ts.yml is the script" cmp -s "$SOURCE" "$CHECK"
check "doc-snippets-ts.yml is valid YAML" \
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WORKFLOW"

cp -r "$FIXTURE" "$WORK/good"
LINES="$(wc -l < "$WORK/good/README.md")"
CODE=$((LINES + 2))

run_case "every shape the fixture uses passes" 0 "0 failure(s) in 4 block(s)" \
  "$PY" "$CHECK" "$WORK/good"

mkdir -p "$WORK/bare"
run_case "a directory that is not a package cannot be checked" 2 "no package.json" \
  "$PY" "$CHECK" "$WORK/bare"

n=0
with_block() {
  local name="$1" expected="$2" want="$3" dir
  shift 3
  n=$((n + 1))
  dir="$WORK/case$n"
  cp -r "$WORK/good" "$dir"
  printf '%s\n' "$@" >> "$dir/README.md"
  run_case "$name" "$expected" "$want" "$PY" "$CHECK" "$dir"
}

with_block "a name the package does not export" 1 \
  "README.md:$CODE: TS2305: Module '\"fixture-counter\"' has no exported member 'reset'" \
  '```ts' 'import { reset } from "fixture-counter";' '```'
with_block "a method a typed value does not have" 1 \
  "README.md:$((CODE + 2)): TS2339: Property 'reset' does not exist on type 'Tally'" \
  '```ts' 'import { create } from "fixture-counter";' 'const t = create("x");' 't.reset();' '```'
with_block "a call with the wrong arguments" 1 \
  "README.md:$((CODE + 1)): TS2554: Expected 1 arguments, but got 0" \
  '```ts' 'import { create } from "fixture-counter";' 'create();' '```'
with_block "an argument of the wrong type" 1 \
  "README.md:$((CODE + 1)): TS2345: Argument of type 'number' is not assignable" \
  '```ts' 'import { create } from "fixture-counter";' 'create(3);' '```'
with_block "a JavaScript block calling what is not there" 1 \
  "README.md:$((CODE + 1)): TS2339: Property 'bunp' does not exist on type 'Tally'" \
  '```js' 'import { create } from "fixture-counter";' 'create("x").bunp();' '```'
with_block "a module of the package's that is not there" 1 \
  "README.md:$CODE: TS2307: Cannot find module 'fixture-counter/missing'" \
  '```ts' 'import { x } from "fixture-counter/missing";' '```'
with_block "a block that does not parse" 1 "README.md:$CODE: TS1" \
  '```ts' 'const x = {;' '```'
with_block "a misspelt use of a name the block imports" 1 \
  "README.md:$((CODE + 1)): TS2552: Cannot find name 'creat'. Did you mean 'create'?" \
  '```ts' 'import { create } from "fixture-counter";' 'const t = creat("a");' '```'
with_block "a misspelt global" 1 \
  "README.md:$CODE: TS2552: Cannot find name 'consol'. Did you mean 'console'?" \
  '```ts' 'consol.log(1);' '```'
with_block "an instance named after the class it is of passes" 0 "0 failure(s)" \
  '```ts' 'import { Tally } from "fixture-counter";' 'const n: number = tally.count;' '```'
with_block "a skip with no reason" 1 "skip gives no reason" \
  '<!-- doc_snippets: skip -->' '```ts' 'nope();' '```'
with_block "a marker that is not one" 1 "unknown marker 'ignore'" \
  '<!-- doc_snippets: ignore because -->' '```ts' 'nope();' '```'

with_block "a return with no function around it passes" 0 "0 failure(s)" \
  '```ts' 'return tally.count;' '```'
with_block "a block in another language is not read" 0 "0 failure(s)" \
  '```rust' 'counter::reset();' '```'

# The generated configuration or the package's own source failing to compile is
# never a clean run.
dir="$WORK/broken-source"
cp -r "$WORK/good" "$dir"
printf '%s\n' 'export const broken: number = "no";' >> "$dir/src/index.ts"
run_case "an error outside the blocks is a run that could not be made" 2 "tsc could not run" \
  "$PY" "$CHECK" "$dir"

# A block is matched on the path tsc prints, not the basename: a package source
# file a block imports and that is named like a generated snippet is the package's
# own error, not a block's.
dir="$WORK/collision"
cp -r "$WORK/good" "$dir"
printf '%s\n' 'export const broken: number = "not a number";' > "$dir/src/snippet_0.ts"
printf '%s\n' '' 'A block that imports it:' '' \
  '```ts' 'import { broken } from "fixture-counter/snippet_0";' 'console.log(broken);' '```' \
  >> "$dir/README.md"
run_case "a source file named like a block is not read as one" 2 "tsc could not run" \
  "$PY" "$CHECK" "$dir"

echo
echo "$((cases - failures)) of $cases passed"
[ "$failures" -eq 0 ]
