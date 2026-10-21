#!/usr/bin/env bash
# Does the Erlang doc-snippets check pass the blocks that work, and fail each kind
# of block that does not, at the doc line where it is wrong?
#
# The cases run against the check AS EMBEDDED IN doc-snippets-erlang.yml, which is
# the copy a caller executes, extracted by its markers. Two checks first say that
# the embedded block is scripts/doc_snippets_erlang.escript byte for byte and that
# the workflow is valid YAML.
#
# The fixture is scripts/fixtures/doc_snippets/good, a rebar3 project whose README
# and guide use every shape the check reads: expressions, a shell session with
# output lines, a record from the package header, a module, forms without a module,
# a term, a skip with a reason and a run-marked session. It compiles once; each
# failing case then appends one block to a copy of its README and states the exit
# code and the doc line the check must report.
#
# Usage: scripts/test_doc_snippets_erlang.sh [--verbose]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$HERE/doc_snippets_erlang.escript"
WORKFLOW="$ROOT/.github/workflows/doc-snippets-erlang.yml"
FIXTURE="$HERE/fixtures/doc_snippets/good"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CHECK="$WORK/doc_snippets_erlang.escript"
export RUNNER_TEMP="$WORK"

failures=0
cases=0

# run_case <name> <expected exit> <expected text or ''> <command...>
# Counts a failure when the exit code differs, or the output lacks the text.
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

# The block the workflow writes to the runner, with the indentation YAML strips
# taken off, so the result is the file the runner gets.
awk -v open_mark="<<'DOC_SNIPPETS_SCRIPT'" -v close_mark="DOC_SNIPPETS_SCRIPT" '
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

check "the block in doc-snippets-erlang.yml is the escript" cmp -s "$SOURCE" "$CHECK"
check "doc-snippets-erlang.yml is valid YAML" \
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WORKFLOW"

# --- the fixture, compiled once -------------------------------------------------
cp -r "$FIXTURE" "$WORK/good"
(cd "$WORK/good" && rebar3 compile > /dev/null) || { echo "FAIL the fixture does not compile"; exit 1; }
LINES="$(wc -l < "$WORK/good/README.md")"
NEXT=$((LINES + 1))

run_case "every shape the fixture uses passes" 0 "0 failure(s) in 2 doc(s)" \
  escript "$CHECK" "$WORK/good"

mkdir -p "$WORK/bare"
run_case "a checkout that was never compiled cannot be checked" 2 "rebar3 compile first" \
  escript "$CHECK" "$WORK/bare"

run_case "a timeout that is not a number is a usage error" 2 "usage:" \
  escript "$CHECK" --timeout soon "$WORK/good"

# with_block <name> <expected exit> <expected text> <block lines...>
# A copy of the compiled fixture whose README ends with the given lines.
n=0
with_block() {
  local name="$1" expected="$2" want="$3" dir
  shift 3
  n=$((n + 1))
  dir="$WORK/case$n"
  cp -r "$WORK/good" "$dir"
  printf '%s\n' "$@" >> "$dir/README.md"
  run_case "$name" "$expected" "$want" escript "$CHECK" ${TIMEOUT:+--timeout "$TIMEOUT"} "$dir"
}

# The line of the first appended block's first code line, and of its fence.
FENCE=$NEXT
CODE=$((NEXT + 1))

with_block "a call to a function the package does not export" 1 \
  "README.md:$CODE: fixture_counter:reset/1 is not exported" \
  '```erlang' 'fixture_counter:reset(T2).' '```'
with_block "a call to a module that is not on the code path" 1 \
  "README.md:$CODE: calls gone_module:start/0, and no module gone_module" \
  '```erlang' 'gone_module:start().' '```'
with_block "a fun reference to a missing function" 1 \
  "README.md:$CODE: fixture_counter:count/2 is not exported" \
  '```erlang' 'F = fun fixture_counter:count/2.' '```'
with_block "a fragment's free variable is a parameter, its bad call still fails" 1 \
  "README.md:$CODE: fixture_counter:bump/2 is not exported" \
  '```erlang' 'fixture_counter:bump(Client, Unbound).' '```'
with_block "a run session needs every variable bound" 1 \
  "README.md:$((CODE + 1)): in the run session: variable 'Unbound' is unbound" \
  '<!-- doc_snippets: run -->' '```erlang' 'Unbound + 1.' '```'
with_block "a block that does not parse" 1 "README.md:$CODE: syntax error" \
  '```erlang' 'fixture_counter:bump(.' '```'
with_block "a record the package does not define" 1 "README.md:$CODE: record nosuch undefined" \
  '```erlang' '#nosuch{} = T2.' '```'
with_block "forms and expressions in one block" 1 "README.md:$CODE: mixes forms and expressions" \
  '```erlang' '-record(r, {a}).' 'X = 1.' '```'
with_block "a module whose function calls what is not there" 1 \
  "README.md:$((CODE + 2)): calls gone_module:go/0" \
  '```erlang' '-module(doc_case_module).' '-export([f/0]).' 'f() -> gone_module:go().' '```'
with_block "forms without a module that use an unbound variable" 1 \
  "README.md:$CODE: variable 'X' is unbound" \
  '```erlang' 'f() -> X.' '```'
with_block "a module block that calls a function it does not define" 1 \
  "README.md:$((CODE + 2)): function helper/0 undefined" \
  '```erlang' '-module(doc_case_strict).' '-export([f/0]).' 'f() -> helper().' '```'
with_block "a reader's helper in a fragment does not hide a bad call beside it" 1 \
  "README.md:$((CODE + 1)): fixture_counter:reset/1 is not exported" \
  '```erlang' 'on_tally(T) -> notify(T),' '    fixture_counter:reset(T).' '```'
with_block "a shell session calling what is not there" 1 \
  "README.md:$CODE: fixture_counter:reset/1 is not exported" \
  '```erlang' '1> fixture_counter:reset(T2).' '** exception error: undefined function' '```'
with_block "a skip with no reason" 1 "README.md:$CODE: skip gives no reason" \
  '<!-- doc_snippets: skip -->' '```erlang' 'not_checked().' '```'
with_block "a marker that is not one" 1 "unknown marker 'ignore'" \
  '<!-- doc_snippets: ignore because -->' '```erlang' 'not_checked().' '```'
with_block "a run-marked session that raises" 1 \
  "README.md:$((CODE + 1)): the session raised error:{badmatch,2}" \
  '<!-- doc_snippets: run -->' '```erlang' '3 = fixture_counter:count(T2).' '```'
TIMEOUT=2 with_block "a run-marked session that never returns" 1 "the session ran past 2 s" \
  '<!-- doc_snippets: run -->' '```erlang' 'receive never -> ok end.' '```'

# Passes that must stay passes.
with_block "a skip with a reason is not checked" 0 "0 failure(s)" \
  '<!-- doc_snippets: skip shows the call that was removed in 0.2 -->' \
  '```erlang' 'fixture_counter:reset(T2).' '```'
with_block "a block in another language is not read" 0 "0 failure(s)" \
  '```elixir' 'FixtureCounter.reset(t2)' '```'
with_block "an example without its final full stop" 0 "0 failure(s)" \
  '```erlang' 'fixture_counter:count(T2)' '```'
with_block "a fragment using a variable the prose made passes" 0 "0 failure(s)" \
  '```erlang' 'N = fixture_counter:count(Tally),' 'N + 1.' '```'
with_block "a run executes the blocks up to it, not the ones after" 0 "0 failure(s)" \
  '<!-- doc_snippets: run -->' '```erlang' '2 = fixture_counter:count(T2).' '```' \
  '```erlang' 'fixture_counter:count(NotBoundHere).' '```'
with_block "forms calling the reader's own helper pass" 0 "0 failure(s)" \
  '```erlang' 'on_tally(T) -> notify(fixture_counter:count(T)).' '```'
with_block "a session fragment calling the reader's own helper passes" 0 "0 failure(s)" \
  '```erlang' 'receive {tally, T} -> handle_tally(T) end.' '```'
with_block "a spec listing passes once its types resolve" 0 "0 failure(s)" \
  '```erlang' '-spec bump(fixture_counter_tally()) -> ok.' '-type fixture_counter_tally() :: term().' '```'
with_block "a shape with many free variables passes" 0 "0 failure(s)" \
  '```erlang' '#{type => Type, version => Version, created_at => CreatedAtMs,' '  expires_at => ExpiresAtMs, payload => Payload, subject => Subject}' '```'
with_block "a block of comments only" 0 "0 failure(s)" \
  '```erlang' '%% events from one stream arrive in order' '```'
with_block "a macro in a forms block" 0 "0 failure(s)" \
  '```erlang' 'name() -> ?MODULE.' '```'
with_block "a doc's own version of a package module is not loaded over it" 0 "0 failure(s)" \
  '```erlang' '-module(fixture_counter).' '-export([new/1]).' 'new(_) -> broken.' '```' \
  '<!-- doc_snippets: run -->' '```erlang' '{tally, x, 0} = fixture_counter:new(x).' '```'

echo
echo "$((cases - failures)) of $cases passed"
[ "$failures" -eq 0 ]
