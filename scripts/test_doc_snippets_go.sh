#!/usr/bin/env bash
# Does the Go doc-snippets check pass the blocks that build, and fail each kind of
# block that does not, at the doc line where it is wrong?
#
# The cases run against the check AS EMBEDDED IN doc-snippets-go.yml, which is the
# copy a caller executes, extracted by its markers. Two checks first say that the
# embedded block is scripts/doc_snippets_go.py byte for byte and that the workflow
# is valid YAML.
#
# The fixture is scripts/fixtures/doc_snippets/go, a Go module whose README and
# guide use every shape the check reads: a fragment with an import, a free ctx and
# elided error handling, a block of alternatives, a skip with a reason, a function
# of the reader's own, and a whole program. Each failing case appends one block to
# a copy of its README and states the exit code and the doc line the check must
# report.
#
# Usage: scripts/test_doc_snippets_go.sh [--verbose]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$HERE/doc_snippets_go.py"
WORKFLOW="$ROOT/.github/workflows/doc-snippets-go.yml"
FIXTURE="$HERE/fixtures/doc_snippets/go"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CHECK="$WORK/doc_snippets_go.py"

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

awk -v open_mark="<<'DOC_SNIPPETS_GO_SCRIPT'" -v close_mark="DOC_SNIPPETS_GO_SCRIPT" '
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

check "the block in doc-snippets-go.yml is the script" cmp -s "$SOURCE" "$CHECK"
check "doc-snippets-go.yml is valid YAML" \
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WORKFLOW"

cp -r "$FIXTURE" "$WORK/good"
LINES="$(wc -l < "$WORK/good/README.md")"
CODE=$((LINES + 2))

run_case "every shape the fixture uses passes" 0 "0 failure(s) in 4 block(s)" \
  python3 "$CHECK" "$WORK/good"

mkdir -p "$WORK/bare"
run_case "a directory that is not a module cannot be checked" 2 "no go.mod" \
  python3 "$CHECK" "$WORK/bare"

n=0
with_block() {
  local name="$1" expected="$2" want="$3" dir
  shift 3
  n=$((n + 1))
  dir="$WORK/case$n"
  cp -r "$WORK/good" "$dir"
  printf '%s\n' "$@" >> "$dir/README.md"
  run_case "$name" "$expected" "$want" python3 "$CHECK" "$dir"
}

with_block "a function the package does not have" 1 \
  "README.md:$CODE: undefined: counter: the package counter has no member" \
  '```go' 'counter.Reset()' '```'
with_block "a method a declared value does not have" 1 \
  "README.md:$((CODE + 1)): t.Reset undefined" \
  '```go' 't := counter.New("x")' 't.Reset()' '```'
with_block "a field the struct does not have" 1 \
  "README.md:$CODE: unknown field Total in struct literal" \
  '```go' 'x := counter.Tally{Total: 3}' '```'
with_block "a call with the wrong arguments" 1 \
  "README.md:$CODE: not enough arguments in call to counter.New" \
  '```go' 'counter.New()' '```'
with_block "a block that does not parse" 1 "README.md:$CODE: syntax error" \
  '```go' 'counter.New("x"' '```'
with_block "a reader's function calling what is not there" 1 \
  "README.md:$((CODE + 1)): t.Reset undefined" \
  '```go' 'func reset(t *counter.Tally) {' '	t.Reset()' '}' '```'
with_block "a whole program that does not build" 1 \
  "README.md:$((CODE + 2)): undefined: counter.Start" \
  '```go' 'package main' 'import "example.org/fixturecounter/counter"' 'func main() { counter.Start() }' '```'
with_block "a standard-library member that is not there" 1 \
  "README.md:$CODE: undefined: os: the package os has no member" \
  '```go' 'data, err := os.ReadFil("x")' '```'
with_block "a reader's function returning the wrong count" 1 \
  "README.md:$CODE: not enough return values" \
  '```go' 'func Make() (int, error) { return 1 }' '```'
with_block "a whole program with an unused import" 1 \
  "README.md:$((CODE + 1)): \"os\" imported and not used" \
  '```go' 'package main' 'import "os"' 'func main() {}' '```'
with_block "a name one block declares does not stand in for another's import" 1 \
  "README.md:$((CODE + 3)): undefined: counter: the package counter has no member" \
  '```go' 'var counter = 1' '```' '```go' 'counter.Reset()' '```'
with_block "a skip with no reason" 1 "skip gives no reason" \
  '<!-- doc_snippets: skip -->' '```go' 'nope()' '```'
with_block "a marker that is not one" 1 "unknown marker 'ignore'" \
  '<!-- doc_snippets: ignore because -->' '```go' 'nope()' '```'

with_block "a fragment using a value the prose made passes" 0 "0 failure(s)" \
  '```go' 'err := tally.Bump(ctx)' '```'
with_block "a var block stays a function body" 0 "0 failure(s)" \
  '```go' 'var t *counter.Tally' 't = counter.New("x")' '```'
with_block "a block in another language is not read" 0 "0 failure(s)" \
  '```rust' 'counter::reset();' '```'

echo
echo "$((cases - failures)) of $cases passed"
[ "$failures" -eq 0 ]
