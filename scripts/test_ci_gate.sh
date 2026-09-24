#!/usr/bin/env bash
# Does ci_gate.sh run a workflow job the way CI would, and leave nothing behind?
#
# Builds a throwaway git repository with a small workflow and gates it in
# debian:trixie-slim: a job that passes, one that fails part-way, and one whose
# step uses a key the gate cannot reproduce. Refuses unless each ends the way
# CI would have and no workspace survives any of them. /tmp here is a shared
# tmpfs, so a leftover export is RAM taken from every other session.
#
# Usage: scripts/test_ci_gate.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/ci_gate.sh"
IMAGE="docker.io/library/debian:trixie-slim"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"

fail() { echo "REFUSED: $*"; exit 1; }

# A repository whose .github/workflows/lint.yml `check' job has the given steps.
repo() {
    local dir="$WORK/$1" steps="$2"
    mkdir -p "$dir/.github/workflows"
    printf 'jobs:\n  check:\n    runs-on: ubuntu-latest\n    container:\n      image: %s\n    env:\n      FROM_JOB: job-level\n    steps:\n%s\n' \
        "$IMAGE" "$steps" > "$dir/.github/workflows/lint.yml"
    git -C "$dir" init -q -b main
    git -C "$dir" add -A
    git -C "$dir" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm t
    git -C "$dir" rev-parse HEAD
}

leftovers() { find "$TMPDIR" -mindepth 1 -maxdepth 1 | wc -l; }

# 1. Passes: every run step, in order, as root, with the checkout at the cwd,
#    job env visible, uses: steps named as skipped.
# shellcheck disable=SC2016 # expanded inside the container, on purpose
SHA=$(repo pass '      - uses: actions/checkout@v4
      - name: who
        run: echo "uid=$(id -u) job=$FROM_JOB"
      - run: test -f .github/workflows/lint.yml && echo "tree=present"')
OUT=$("$GATE" "$WORK/pass" "$SHA" 2>&1) || fail "a passing job failed: $OUT"
grep -q "uid=0 job=job-level" <<<"$OUT" || fail "steps did not run as root with the job env: $OUT"
grep -qx "tree=present" <<<"$OUT" || fail "the commit was not the working directory: $OUT"
grep -q "skipped: uses: actions/checkout@v4" <<<"$OUT" || fail "a uses: step was not reported as skipped: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "a passing run left its workspace behind"

# 2. Fails part-way: non-zero exit, and nothing after the failing step runs.
SHA=$(repo failing '      - run: echo first-ran
      - run: "false"
      - run: echo third-ran')
OUT=$("$GATE" "$WORK/failing" "$SHA" 2>&1) && fail "a failing job exited 0: $OUT"
grep -qx "first-ran" <<<"$OUT" || fail "the step before the failure did not run: $OUT"
grep -qx "third-ran" <<<"$OUT" && fail "a step after the failure ran: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "a failing run left its workspace behind"

# 3. A step key the gate cannot reproduce is refused before anything runs.
# The step prints ran-2, which its own text does not contain, so the refusal
# naming the step cannot be mistaken for the step having run.
# shellcheck disable=SC2016 # expanded inside the container, on purpose
SHA=$(repo unsupported '      - run: echo "ran-$((1+1))"
        if: github.event_name == '"'"'push'"'"'')
OUT=$("$GATE" "$WORK/unsupported" "$SHA" 2>&1) && fail "an unsupported step key was accepted: $OUT"
grep -qx "ran-2" <<<"$OUT" && fail "a step ran despite the refusal: $OUT"
grep -q "if" <<<"$OUT" || fail "the refusal did not name the key: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "a refused run left its workspace behind"

echo "OK: ci_gate.sh runs the job as CI would and leaves nothing behind"
