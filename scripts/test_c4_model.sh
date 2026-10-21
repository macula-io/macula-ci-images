#!/usr/bin/env bash
# Does the C4 model gate pass the repositories that carry the model, and fail each
# way of not carrying it, naming the diagram that is missing?
#
# The cases run against the check AS EMBEDDED IN c4-model.yml, which is the copy a
# caller executes, extracted by its markers. Two checks first say that the embedded
# block is scripts/c4_model.sh byte for byte and that the workflow is valid YAML.
#
# Every case is a throwaway repository: the diagrams and the README a service has,
# and one thing taken away or moved. Nothing is cloned and nothing is read from this
# repository's own tree.
#
# Usage: scripts/test_c4_model.sh [--verbose]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$HERE/c4_model.sh"
WORKFLOW="$ROOT/.github/workflows/c4-model.yml"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CHECK="$WORK/c4_model.sh"

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

awk -v open_mark="<<'C4_MODEL_SCRIPT'" -v close_mark="C4_MODEL_SCRIPT" '
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

check "the block in c4-model.yml is the script" cmp -s "$SOURCE" "$CHECK"
check "c4-model.yml is valid YAML" \
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WORKFLOW"

# service <dir>: the repository mcl-fovea is, with its two diagrams shown by both
# READMEs. Every case starts from it and takes one thing away.
service() {
  local dir="$1"
  mkdir -p "$dir/assets"
  printf "<svg xmlns='http://www.w3.org/2000/svg'/>\n" > "$dir/assets/c4-context.svg"
  printf "<svg xmlns='http://www.w3.org/2000/svg'/>\n" > "$dir/assets/c4-components.svg"
  printf '# service\n\n![context](assets/c4-context.svg)\n' > "$dir/README.md"
  mkdir -p "$dir/architecture"
  printf '# architecture\n\n![components](assets/c4-components.svg)\n' \
    > "$dir/architecture/README.md"
}

n=0
case_dir() {
  n=$((n + 1))
  service "$WORK/case$n"
  printf '%s' "$WORK/case$n"
}

run_case "the model a service carries passes" 0 "" bash "$CHECK" "$(case_dir)"

dir="$(case_dir)"; rm "$dir/assets/c4-context.svg"
run_case "a missing context diagram fails" 1 "no assets/*context*.svg" bash "$CHECK" "$dir"

dir="$(case_dir)"; rm "$dir/assets/c4-components.svg"
run_case "a missing component diagram fails" 1 "no assets/*component*.svg" bash "$CHECK" "$dir"

dir="$(case_dir)"; printf '# service\n' > "$dir/README.md"
run_case "a diagram no README shows fails" 1 "c4-context.svg is not shown" bash "$CHECK" "$dir"

dir="$(case_dir)"; rm -r "$dir/architecture"
run_case "the component diagram had only the architecture README" 1 \
  "c4-components.svg is not shown" bash "$CHECK" "$dir"

dir="$(case_dir)"
printf '# service\n\n![c](assets/c4-context.svg)\n![c](assets/c4-components.svg)\n' \
  > "$dir/README.md"
rm -r "$dir/architecture"
run_case "the front page alone is enough" 0 "" bash "$CHECK" "$dir"

dir="$(case_dir)"
mv "$dir/assets/c4-context.svg" "$dir/assets/sys-context.svg"
mv "$dir/assets/c4-components.svg" "$dir/assets/inside-components.svg"
printf '# service\n\n![a](assets/sys-context.svg)\n![b](assets/inside-components.svg)\n' \
  > "$dir/README.md"
rm -r "$dir/architecture"
run_case "the rest of the name is free, and case does not matter" 0 "" bash "$CHECK" "$dir"

dir="$(case_dir)"
mv "$dir/assets/c4-context.svg" "$dir/assets/C4-CONTEXT.SVG"
printf '# service\n\n![context](assets/C4-CONTEXT.SVG)\n' > "$dir/README.md"
run_case "an upper-case name is the same diagram" 0 "" bash "$CHECK" "$dir"

dir="$(case_dir)"
mv "$dir/assets/c4-context.svg" "$dir/assets/C4-CONTEXT.SVG"
run_case "a link that is not the file's own name does not show it" 1 \
  "C4-CONTEXT.SVG is not shown" bash "$CHECK" "$dir"

dir="$(case_dir)"; rm -rf "$dir/assets"
run_case "a repository with no assets at all fails both" 1 "no assets/*context*.svg" \
  bash "$CHECK" "$dir"

mkdir -p "$WORK/empty"
run_case "an empty directory is not a model" 1 "no assets/*component*.svg" \
  bash "$CHECK" "$WORK/empty"

printf '\n'
if [ "$failures" -eq 0 ]; then
  printf 'c4_model: %d cases passed\n' "$cases"
  exit 0
fi
printf 'c4_model: %d of %d cases FAILED\n' "$failures" "$cases"
exit 1
