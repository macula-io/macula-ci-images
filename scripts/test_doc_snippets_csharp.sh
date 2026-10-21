#!/usr/bin/env bash
# Does the C# doc-snippets check pass the blocks that compile, and fail each kind
# of block that does not, at the doc line where it is wrong?
#
# The cases run against the check AS EMBEDDED IN doc-snippets-csharp.yml, which is
# the copy a caller executes, extracted by its markers. Two checks first say that
# the embedded block is scripts/doc_snippets_csharp.py byte for byte and that the
# workflow is valid YAML.
#
# The fixture is scripts/fixtures/doc_snippets/csharp, a package whose README and
# guide use every shape the check reads: a fragment with a using, a free value, a
# block that does not declare its own using, a skip with a reason, a type of the
# reader's own, and a block in another language. Each failing case appends one
# block to a copy of its README and states the exit code and the doc line the
# check must report.
#
# Usage: scripts/test_doc_snippets_csharp.sh [--verbose]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$HERE/doc_snippets_csharp.py"
WORKFLOW="$ROOT/.github/workflows/doc-snippets-csharp.yml"
FIXTURE="$HERE/fixtures/doc_snippets/csharp"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CHECK="$WORK/doc_snippets_csharp.py"

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

awk -v open_mark="<<'DOC_SNIPPETS_CSHARP_SCRIPT'" -v close_mark="DOC_SNIPPETS_CSHARP_SCRIPT" '
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

check "the block in doc-snippets-csharp.yml is the script" cmp -s "$SOURCE" "$CHECK"
check "doc-snippets-csharp.yml is valid YAML" \
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WORKFLOW"

cp -r "$FIXTURE" "$WORK/good"
LINES="$(wc -l < "$WORK/good/README.md")"
CODE=$((LINES + 2))

run_case "every shape the fixture uses passes" 0 "0 failure(s) in 4 block(s)" \
  python3 "$CHECK" "$WORK/good"

mkdir -p "$WORK/bare"
run_case "a directory that is not a project cannot be checked" 2 "no project to compile against" \
  python3 "$CHECK" "$WORK/bare"

cp -r "$WORK/good" "$WORK/broken"
printf '%s\n' 'namespace FixtureCounter;' 'public sealed class Broken { public void Oops( { }' \
  > "$WORK/broken/src/FixtureCounter/Broken.cs"
run_case "a package that does not build is not a pass" 2 "failed outside the docs read" \
  python3 "$CHECK" "$WORK/broken"

# A toolchain that cannot run must never read as a pass: a repository pinning an
# SDK the runner does not have prints no diagnostic this check can place.
cp -r "$WORK/good" "$WORK/nosdk"
printf '%s\n' '{"sdk":{"version":"99.0.100","rollForward":"disable"}}' > "$WORK/nosdk/global.json"
cat >> "$WORK/nosdk/README.md" <<'MD'

```csharp
Tally.Bump();
```
MD
run_case "a toolchain that cannot run is not a pass" 2 "without naming a block" \
  python3 "$CHECK" "$WORK/nosdk"

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

# The same, but in a doc of its own, so nothing carries a using into it.
fresh_doc() {
  local name="$1" expected="$2" want="$3" dir
  shift 3
  n=$((n + 1))
  dir="$WORK/case$n"
  cp -r "$WORK/good" "$dir"
  mkdir -p "$dir/guides"
  printf '%s\n' "$@" > "$dir/guides/fresh.md"
  run_case "$name" "$expected" "$want" python3 "$CHECK" "$dir"
}

with_block "a member the type does not have" 1 \
  "README.md:$CODE: 'Tally' does not contain a definition for 'Bumpp'" \
  '```csharp' 'Tally.Bumpp();' '```'
with_block "a member the value's type does not have" 1 \
  "README.md:$((CODE + 1)): 'Tally' does not contain a definition for 'Bumpp'" \
  '```csharp' 'var t = Tally.New("x");' 't.Bumpp();' '```'
with_block "a call that leaves a parameter out" 1 \
  "README.md:$CODE: There is no argument given that corresponds to the required parameter 'label'" \
  '```csharp' 'Tally.New();' '```'
with_block "a block that does not parse" 1 "README.md:$CODE: ) expected" \
  '```csharp' 'Tally.New("x"' '```'
with_block "a type the docs expected and the package does not have" 1 \
  "README.md:$CODE: The name 'Session' does not exist in the current context" \
  '```csharp' 'Session.New("x");' '```'
with_block "a block in another language is not read" 0 "0 failure(s) in 4 block(s)" \
  '```rust' 'tally::bump();' '```'
with_block "a skip with no reason" 1 "skip gives no reason" \
  '<!-- doc_snippets: skip -->' '```csharp' 'nope();' '```'
with_block "a marker that is not one" 1 "unknown marker 'ignore'" \
  '<!-- doc_snippets: ignore because -->' '```csharp' 'nope();' '```'

fresh_doc "a type the package provides, with its using left out" 1 \
  "guides/fresh.md:2: The name 'Tally' does not exist in the current context" \
  '```csharp' 'Tally.New("x");' '```'
# A block that is nothing but a using carries it on: "Add the namespace:" then a
# using alone is a README shape, and the block after it uses the alias.
fresh_doc "a using-only block carries its alias to the block below" 0 "0 failure(s)" \
  '```csharp' 'using TC = FixtureCounter.Tally;' '```' '' '```csharp' 'var t = TC.New("x");' '```'

fresh_doc "a value the prose made passes" 0 "0 failure(s)" \
  '```csharp' 'realm.Bump();' '```'
fresh_doc "a name a block of alternatives binds twice passes" 0 "0 failure(s)" \
  '```csharp' 'var x = 1;' 'var x = 2;' '```'
fresh_doc "a return of a value in a fragment passes" 0 "0 failure(s)" \
  '```csharp' 'return 1;' '```'
fresh_doc "a deconstruction of a free value passes" 0 "0 failure(s)" \
  '```csharp' 'var (count, rest) = tally.Take(3);' '```'

echo
echo "$((cases - failures)) of $cases passed"
[ "$failures" -eq 0 ]
