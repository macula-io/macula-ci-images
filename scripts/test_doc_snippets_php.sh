#!/usr/bin/env bash
# Does the PHP doc-snippets check pass the blocks that parse and type-check, and
# fail each kind of block that does not, at the doc line where it is wrong?
#
# The cases run against the check AS EMBEDDED IN doc-snippets-php.yml, which is the
# copy a caller executes, extracted by its markers. Two checks first say that the
# embedded block is scripts/doc_snippets_php.py byte for byte and that the workflow
# is valid YAML.
#
# The fixture is scripts/fixtures/doc_snippets/php, a package whose README and
# guide use every shape the check reads: a fragment with a use, a free variable and
# a bare function of the reader's own, a block that does not declare its own use, a
# type of its own, a skip with a reason, and a block in another language. Each
# failing case appends one block to a copy of its README and states the exit code
# and the doc line the check must report.
#
# Needs php, composer and phpstan on the PATH (PHPSTAN names the binary).
#
# Usage: scripts/test_doc_snippets_php.sh [--verbose]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$HERE/doc_snippets_php.py"
WORKFLOW="$ROOT/.github/workflows/doc-snippets-php.yml"
FIXTURE="$HERE/fixtures/doc_snippets/php"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CHECK="$WORK/doc_snippets_php.py"

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

awk -v open_mark="<<'DOC_SNIPPETS_PHP_SCRIPT'" -v close_mark="DOC_SNIPPETS_PHP_SCRIPT" '
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

check "the block in doc-snippets-php.yml is the script" cmp -s "$SOURCE" "$CHECK"
check "doc-snippets-php.yml is valid YAML" \
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WORKFLOW"

cp -r "$FIXTURE" "$WORK/good"
composer --working-dir="$WORK/good" dump-autoload --quiet
LINES="$(wc -l < "$WORK/good/README.md")"
CODE=$((LINES + 2))

run_case "every shape the fixture uses passes" 0 "0 failure(s) in 4 block(s)" \
  python3 "$CHECK" "$WORK/good"

mkdir -p "$WORK/bare"
run_case "a directory that is not a package cannot be checked" 2 "no composer.json" \
  python3 "$CHECK" "$WORK/bare"

cp -r "$WORK/good" "$WORK/noautoload"
rm -rf "$WORK/noautoload/vendor"
run_case "a package whose dependencies are not installed cannot be checked" 2 \
  "run composer install first" python3 "$CHECK" "$WORK/noautoload"

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

# The same, but in a doc of its own, so nothing carries a use into it.
fresh_doc() {
  local name="$1" expected="$2" want="$3" dir
  shift 3
  n=$((n + 1))
  dir="$WORK/case$n"
  cp -r "$WORK/good" "$dir"
  printf '%s\n' "$@" > "$dir/guides/fresh.md"
  run_case "$name" "$expected" "$want" python3 "$CHECK" "$dir"
}

with_block "a method the type does not have" 1 \
  "README.md:$((CODE + 1)): Call to an undefined method FixtureCounter\\Tally::bumpp()." \
  '```php' '$tally = Tally::new("apples");' '$tally->bumpp();' '```'
with_block "an argument count the method does not take" 1 \
  "README.md:$CODE: Static method FixtureCounter\\Tally::new() invoked with 0 parameters, 1 required." \
  '```php' 'Tally::new();' '```'
with_block "a block that does not parse" 1 "README.md:$CODE:" \
  '```php' 'Tally::new("x"' '```'
with_block "a block in another language is not read" 0 "0 failure(s) in 4 block(s)" \
  '```ruby' 'tally.bump' '```'
with_block "a skip with no reason" 1 "skip gives no reason" \
  '<!-- doc_snippets: skip -->' '```php' 'nope();' '```'
with_block "a marker that is not one" 1 "unknown marker 'ignore'" \
  '<!-- doc_snippets: ignore because -->' '```php' 'nope();' '```'

fresh_doc "a type the package provides, with its use left out" 1 \
  "guides/fresh.md:2: Call to static method new() on an unknown class Tally." \
  '```php' 'Tally::new("apples");' '```'
fresh_doc "a variable the prose made passes" 0 "0 failure(s)" \
  '```php' '$answer = $pool->call($realm, "mcl-echo/echo", "hi");' '```'
fresh_doc "a function of the reader's own passes" 0 "0 failure(s)" \
  '```php' 'echo my_own_helper();' '```'
fresh_doc "a qualified call to a function that is not there fails" 1 \
  "guides/fresh.md:2: Function Macula\\fixture not found." \
  '```php' '\Macula\fixture();' '```'

echo
echo "$((cases - failures)) of $cases passed"
[ "$failures" -eq 0 ]
