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

# 4. An `if: always()` step runs after a failure, as in CI, and the job still
#    fails; a step after the failure without it does not run.
SHA=$(repo always '      - run: "false"
      - run: echo skipped-after-failure
      - name: cleanup
        if: always()
        run: echo cleanup-ran')
OUT=$("$GATE" "$WORK/always" "$SHA" 2>&1) && fail "a job with a failed step exited 0: $OUT"
grep -qx "cleanup-ran" <<<"$OUT" || fail "the if: always() step did not run after the failure: $OUT"
grep -qx "skipped-after-failure" <<<"$OUT" && fail "a plain step ran after the failure: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "an always() run left its workspace behind"

# 5. A job-level timeout-minutes bounds the whole run instead of being ignored.
SHA=$(repo timeout '      - run: sleep 600' | tail -1)
sed -i 's/^    runs-on: ubuntu-latest$/    runs-on: ubuntu-latest\n    timeout-minutes: 0.05/' "$WORK/timeout/.github/workflows/lint.yml"
git -C "$WORK/timeout" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qam timeout
SHA=$(git -C "$WORK/timeout" rev-parse HEAD)
STARTED=$(date +%s)
OUT=$("$GATE" "$WORK/timeout" "$SHA" 2>&1) && fail "a job past its timeout exited 0: $OUT"
[ $(( $(date +%s) - STARTED )) -lt 120 ] || fail "timeout-minutes did not bound the run"
grep -q "timed out" <<<"$OUT" || fail "the timeout was not reported: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "a timed-out run left its workspace behind"

# 6. A GitHub expression the gate cannot evaluate is refused, naming it.
# shellcheck disable=SC2016 # a literal GitHub expression, on purpose
SHA=$(repo expression '      - run: echo "${{ github.sha }}"')
OUT=$("$GATE" "$WORK/expression" "$SHA" 2>&1) && fail "a step with a GitHub expression was accepted: $OUT"
grep -q "github.sha" <<<"$OUT" || fail "the refusal did not name the expression: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "a refused expression left its workspace behind"

# 7. Env layers as in CI: workflow env, overridden by job env, overridden by
#    step env; and the runner's own variables a step may read.
# shellcheck disable=SC2016 # expanded inside the container, on purpose
SHA=$(repo layers '      - run: echo "layers=$FROM_WORKFLOW/$FROM_JOB/$FROM_STEP ws=$GITHUB_WORKSPACE ci=$CI"
        env:
          FROM_STEP: step-level')
sed -i '1i env:\n  FROM_WORKFLOW: workflow-level\n  FROM_JOB: overridden-by-job' "$WORK/layers/.github/workflows/lint.yml"
git -C "$WORK/layers" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qam layers
SHA=$(git -C "$WORK/layers" rev-parse HEAD)
OUT=$("$GATE" "$WORK/layers" "$SHA" 2>&1) || fail "the env layers job failed: $OUT"
grep -qx "layers=workflow-level/job-level/step-level ws=/w ci=true" <<<"$OUT" \
    || fail "env did not layer workflow < job < step, or the runner variables were missing: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "an env run left its workspace behind"

# 8. A step's GITHUB_PATH and GITHUB_ENV lines reach the steps after it, as
#    the runner carries them.
# shellcheck disable=SC2016 # expanded inside the container, on purpose
SHA=$(repo carry '      - run: |
          mkdir -p /opt/gate-bin && printf "#!/bin/sh\necho tool-found\n" > /opt/gate-bin/gate-tool
          chmod +x /opt/gate-bin/gate-tool
          echo /opt/gate-bin >> "$GITHUB_PATH"
          echo "CARRIED=from-an-earlier-step" >> "$GITHUB_ENV"
      - run: gate-tool && echo "carried=$CARRIED"')
OUT=$("$GATE" "$WORK/carry" "$SHA" 2>&1) || fail "the carry job failed: $OUT"
grep -qx "tool-found" <<<"$OUT" || fail "a GITHUB_PATH entry did not reach the next step: $OUT"
grep -qx "carried=from-an-earlier-step" <<<"$OUT" || fail "a GITHUB_ENV line did not reach the next step: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "a carry run left its workspace behind"

echo "OK: ci_gate.sh runs the job as CI would and leaves nothing behind"
