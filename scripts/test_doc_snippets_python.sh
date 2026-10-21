#!/usr/bin/env bash
# Does the Python doc-snippets check pass the blocks that type-check, and fail each
# kind of block that does not, at the doc line where it is wrong?
#
# The cases run against the check AS EMBEDDED IN doc-snippets-python.yml, which is the
# copy a caller executes, extracted by its markers. Two checks first say that the
# embedded block is scripts/doc_snippets_python.py byte for byte and that the workflow
# is valid YAML.
#
# The fixture is scripts/fixtures/doc_snippets/python, a typed Python package whose
# README and guide use every shape the check reads: a block with a top-level await,
# a later block using the earlier block's import and a value the prose made, `[...]`,
# a pycon session with output, a skip with a reason, and a function of the reader's
# own. Each failing case appends one block to a copy of its README and states the
# exit code and the doc line the check must report.
#
# The interpreter is $PYTHON (default python3), which must have mypy.
#
# Usage: scripts/test_doc_snippets_go.sh [--verbose]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$HERE/doc_snippets_python.py"
WORKFLOW="$ROOT/.github/workflows/doc-snippets-python.yml"
FIXTURE="$HERE/fixtures/doc_snippets/python"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CHECK="$WORK/doc_snippets_python.py"
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

awk -v open_mark="<<'DOC_SNIPPETS_PYTHON_SCRIPT'" -v close_mark="DOC_SNIPPETS_PYTHON_SCRIPT" '
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

check "the block in doc-snippets-python.yml is the script" cmp -s "$SOURCE" "$CHECK"
check "doc-snippets-python.yml is valid YAML" \
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WORKFLOW"

cp -r "$FIXTURE" "$WORK/good"
LINES="$(wc -l < "$WORK/good/README.md")"
CODE=$((LINES + 2))

run_case "every shape the fixture uses passes" 0 "0 failure(s) in 4 block(s)" \
  "$PY" "$CHECK" "$WORK/good"

mkdir -p "$WORK/bare"
run_case "a directory that is not a Python project cannot be checked" 2 "no pyproject.toml" \
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
  "README.md:$CODE: Module \"fixture_counter\" has no attribute \"reset\"" \
  '```python' 'from fixture_counter import reset' '```'
with_block "a method a typed value does not have" 1 \
  "README.md:$((CODE + 1)): \"Tally\" has no attribute \"reset\"" \
  '```python' 't = fixture_counter.new("x")' 't.reset()' '```'
with_block "a keyword the function does not take" 1 \
  "README.md:$CODE: Unexpected keyword argument \"step\"" \
  '```python' 'await fixture_counter.new("x").bump(step=2)' '```'
with_block "an argument of the wrong type" 1 \
  "README.md:$CODE: Argument 1 to \"new\" has incompatible type \"int\"" \
  '```python' 'fixture_counter.new(3)' '```'
with_block "a block that does not parse, without stopping the others" 1 \
  "README.md:$CODE: syntax error" \
  '```python' 'def broken(:' '```' '```python' 'fixture_counter.new(3)' '```'
with_block "the block after a broken one is still checked" 1 \
  "README.md:$((CODE + 3)): Argument 1 to \"new\" has incompatible type \"int\"" \
  '```python' 'def broken(:' '```' '```python' 'fixture_counter.new(3)' '```'
with_block "a shell session calling what is not there" 1 \
  "README.md:$((CODE + 1)): Module has no attribute \"Nope\"" \
  '```pycon' '>>> import fixture_counter' '>>> fixture_counter.Nope' 'Traceback (most recent call last):' '```'
with_block "a skip with no reason" 1 "skip gives no reason" \
  '<!-- doc_snippets: skip -->' '```python' 'nope()' '```'
with_block "a marker that is not one" 1 "unknown marker 'ignore'" \
  '<!-- doc_snippets: ignore because -->' '```python' 'nope()' '```'

with_block "alternatives that bind a name twice pass" 0 "0 failure(s)" \
  '```python' 'from fixture_counter import new' 'from fixture_counter import new' '```'
with_block "a return in a block with no function around it passes" 0 "0 failure(s)" \
  '```python' 'return tally.count' '```'
with_block "a block in another language is not read" 0 "0 failure(s)" \
  '```rust' 'counter::reset();' '```'

# A guide that uses the package without importing it: its own doc, no carried import.
dir="$WORK/guide"
cp -r "$WORK/good" "$dir"
printf '%s\n' '# Bare' '' '```python' 'fixture_counter.new("x")' '```' > "$dir/guides/bare.md"
run_case "a package a doc uses and never imports" 1 \
  "guides/bare.md:4: Name \"fixture_counter\" is not defined: the package fixture_counter is used and never imported" \
  "$PY" "$CHECK" "$dir"

echo
echo "$((cases - failures)) of $cases passed"
[ "$failures" -eq 0 ]
