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
# Where a failed run's logs are kept: outside TMPDIR, so leftovers() still
# counts only workspaces, and inside WORK, so the test leaves nothing either.
export GATE_LOG_DIR="$WORK/kept"

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
grep -q "REFUSED: the job timed out" <<<"$OUT" || fail "the timeout was not reported: $OUT"
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

# 9. A job with no `container: image:' runs on the runner's own toolchain
#    (setup-beam on ubuntu-latest), which this gate cannot reproduce: refused
#    by name, never a traceback a caller could read as a test failure.
SHA=$(repo nocontainer '      - run: echo should-not-run')
sed -i '/^    container:$/d; /^      image: /d' "$WORK/nocontainer/.github/workflows/lint.yml"
git -C "$WORK/nocontainer" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qam nocontainer
SHA=$(git -C "$WORK/nocontainer" rev-parse HEAD)
OUT=$("$GATE" "$WORK/nocontainer" "$SHA" 2>&1) && fail "a job with no container image was accepted: $OUT"
grep -q "Traceback" <<<"$OUT" && fail "a job with no container image crashed the gate: $OUT"
grep -q "REFUSED: job 'check' has no container image" <<<"$OUT" || fail "the refusal did not name the missing container: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "a refused no-container run left its workspace behind"

# 10. A job the workflow does not have is refused by name, not a traceback.
SHA=$(repo nojob '      - run: echo should-not-run')
OUT=$("$GATE" "$WORK/nojob" "$SHA" lint.yml build 2>&1) && fail "a missing job was accepted: $OUT"
grep -q "Traceback" <<<"$OUT" && fail "a missing job crashed the gate: $OUT"
grep -q "REFUSED: lint.yml has no job 'build'" <<<"$OUT" || fail "the refusal did not name the missing job: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "a refused missing-job run left its workspace behind"

# A fake `rebar3' the build step installs through GITHUB_PATH, so the test
# step looks like the real thing to the gate. $1 is its body.
# shellcheck disable=SC2016 # expanded inside the container, on purpose
fake_rebar3() {
    printf '      - name: build
        run: |
          mkdir -p /opt/fake
          cat > /opt/fake/rebar3 <<'"'"'EOF'"'"'
          #!/bin/sh
          %s
          EOF
          chmod +x /opt/fake/rebar3
          echo /opt/fake >> "$GITHUB_PATH"
          echo build-ran
      - run: rebar3 eunit' "$1"
}
kept() { find "$GATE_LOG_DIR/runs" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l; }

rm -rf "$GATE_LOG_DIR"   # the failing runs above kept theirs

# 11. Without GATE_TEST_CPUS the gate is the CI job and nothing more: the test
#     step runs once, uncapped below GATE_CPUS, and no throttled pass is named.
# shellcheck disable=SC2016 # expanded inside the container, on purpose
SHA=$(repo plainrun "$(fake_rebar3 'echo "eunit-ran cpu.max=$(cat /sys/fs/cgroup/cpu.max)"')")
OUT=$(env -u GATE_TEST_CPUS "$GATE" "$WORK/plainrun" "$SHA" 2>&1) || fail "the fake-rebar3 job failed: $OUT"
[ "$(grep -c "^eunit-ran" <<<"$OUT")" -eq 1 ] || fail "without GATE_TEST_CPUS the test step did not run exactly once: $OUT"
grep -q "throttled" <<<"$OUT" && fail "a throttled pass ran without GATE_TEST_CPUS: $OUT"
[ "$(kept)" -eq 0 ] || fail "a passing run kept a log"

# 12. GATE_TEST_CPUS=0.5 re-runs only the test steps, after the normal job,
#     with the carried PATH, capped at half a CPU, and the report names it.
OUT=$(GATE_TEST_CPUS=0.5 "$GATE" "$WORK/plainrun" "$SHA" 2>&1) || fail "a throttled passing job failed: $OUT"
[ "$(grep -cx "build-ran" <<<"$OUT")" -eq 1 ] || fail "the throttled pass re-ran a build step: $OUT"
[ "$(grep -c "^eunit-ran" <<<"$OUT")" -eq 2 ] || fail "the test step did not run once plain and once throttled: $OUT"
grep -qx "eunit-ran cpu.max=50000 100000" <<<"$OUT" || fail "the throttled pass was not capped at 0.5 CPU: $OUT"
grep -q "throttled test pass passed under --cpus=0.5" <<<"$OUT" || fail "the report did not name the cap: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "a throttled run left its workspace behind"

# 13. GATE_TEST_CPUS=runner is the measured default: at least as slow as a
#     GitHub-hosted runner at p90.
OUT=$(GATE_TEST_CPUS=runner "$GATE" "$WORK/plainrun" "$SHA" 2>&1) || fail "GATE_TEST_CPUS=runner failed: $OUT"
grep -qx "eunit-ran cpu.max=50000 100000" <<<"$OUT" || fail "GATE_TEST_CPUS=runner is not 0.5: $OUT"

# 14. A malformed cap is refused before anything runs, naming the value. A
#     whole CPU or more is not a throttle; the default gate already runs at 4.
for v in abc 0 0.0 1 1.0 1.5 -0.5 .5 0.5x ""; do
    OUT=$(GATE_TEST_CPUS="$v" "$GATE" "$WORK/plainrun" "$SHA" 2>&1) && fail "GATE_TEST_CPUS='$v' was accepted: $OUT"
    grep -q "REFUSED: GATE_TEST_CPUS='$v'" <<<"$OUT" || fail "the refusal did not name GATE_TEST_CPUS='$v': $OUT"
    grep -qx "build-ran" <<<"$OUT" && fail "a step ran despite GATE_TEST_CPUS='$v': $OUT"
done
[ "$(leftovers)" -eq 0 ] || fail "a refused cap left its workspace behind"

# 15. A throttle on a job with no test step is refused, naming the steps.
SHA=$(repo notests '      - name: only a build
        run: echo build-ran')
OUT=$(GATE_TEST_CPUS=0.5 "$GATE" "$WORK/notests" "$SHA" 2>&1) && fail "a throttle with no test step was accepted: $OUT"
grep -q "REFUSED: GATE_TEST_CPUS is set but job 'check' has no test step" <<<"$OUT" || fail "the refusal was not named: $OUT"
grep -q "only a build" <<<"$OUT" || fail "the refusal did not list the steps: $OUT"
grep -qx "build-ran" <<<"$OUT" && fail "a step ran despite the refusal: $OUT"

# 16. A test that only fails when slow: green plain, red throttled, and the
#     gate fails naming the cap, with the failing test in its summary.
# shellcheck disable=SC2016 # expanded inside the container, on purpose
SHA=$(repo slowred "$(fake_rebar3 'case "$(cat /sys/fs/cgroup/cpu.max)" in 50000*) echo "keygen_tests: corrupted_first...*timed out*"; exit 1;; esac; echo eunit-ran')")
OUT=$(GATE_TEST_CPUS=0.5 "$GATE" "$WORK/slowred" "$SHA" 2>&1) && fail "a test red under the throttle exited 0: $OUT"
grep -qx "eunit-ran" <<<"$OUT" || fail "the plain pass did not run green first: $OUT"
grep -q "throttled test pass FAILED under --cpus=0.5" <<<"$OUT" || fail "the throttled failure did not name the cap: $OUT"
SUMMARY=$(sed -n '/^failures:/,/^log kept:/p' <<<"$OUT")
grep -q "corrupted_first...\*timed out\*" <<<"$SUMMARY" || fail "the summary did not name the failing test: $OUT"
grep -q "throttled test pass FAILED" <<<"$SUMMARY" && fail "the summary listed the gate's own report line: $SUMMARY"
[ "$(leftovers)" -eq 0 ] || fail "a throttled failure left its workspace behind"

# 17. A failed run keeps its log and the test logs outside the cleaned
#     workspace, and prints the failing tests' lines, so a failure that does
#     not come back on a rerun is still named.
# shellcheck disable=SC2016 # expanded inside the container, on purpose
SHA=$(repo keeplog "$(fake_rebar3 'mkdir -p _build/test/logs/ct_run.x; echo suite-detail > _build/test/logs/ct_run.x/suite.log; echo "mod_tests: a_test...*failed*"; echo "  in function mod_tests:a_test/0"; echo "Failures:"; echo "  1) mod_tests:b_test/0"; echo "Pending:"; echo "  mod_tests:slow_test/0: the slow one"; echo "    %% Unknown error: {timeout,"; echo "Failed: 1.  Skipped: 0.  Passed: 9."; exit 1')")
rm -rf "$GATE_LOG_DIR"
OUT=$("$GATE" "$WORK/keeplog" "$SHA" 2>&1) && fail "a failing eunit exited 0: $OUT"
DIR=$(sed -n 's/^log kept: //p' <<<"$OUT")
[ -n "$DIR" ] && [ -d "$DIR" ] || fail "no kept log directory was named: $OUT"
case "$DIR" in "$GATE_LOG_DIR"/runs/keeplog-*) ;; *) fail "the log was not kept in GATE_LOG_DIR/runs: $DIR";; esac
grep -q "mod_tests: a_test...\*failed\*" "$DIR/job.log" || fail "the kept job.log lacks the failure"
[ "$(cat "$DIR/test-logs/ct_run.x/suite.log")" = suite-detail ] || fail "the test logs were not kept"
SUMMARY=$(sed -n '/^failures:/,$p' <<<"$OUT")
grep -q "mod_tests: a_test...\*failed\*" <<<"$SUMMARY" || fail "the summary did not name the failing test: $OUT"
grep -q "in function mod_tests:a_test/0" <<<"$SUMMARY" || fail "the summary lost the failure's detail line: $OUT"
grep -q "Failed: 1." <<<"$SUMMARY" || fail "the summary lost the totals: $OUT"
grep -q "1) mod_tests:b_test/0" <<<"$SUMMARY" || fail "the summary lost rebar3's Failures entry: $OUT"
grep -q "mod_tests:slow_test/0: the slow one" <<<"$SUMMARY" || fail "the summary did not name the cancelled (Pending) test: $OUT"
grep -q "Unknown error: {timeout," <<<"$SUMMARY" || fail "the summary lost why the pending test was cancelled: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "a kept-log run left its workspace behind"

# 18. Kept logs are pruned to the newest GATE_LOG_KEEP, and a malformed
#     GATE_LOG_KEEP is refused before anything runs.
rm -rf "$GATE_LOG_DIR"
for _ in 1 2 3; do
    GATE_LOG_KEEP=2 "$GATE" "$WORK/keeplog" "$SHA" >/dev/null 2>&1 && fail "a failing eunit exited 0"
    sleep 1
done
[ "$(kept)" -eq 2 ] || fail "GATE_LOG_KEEP=2 left $(kept) kept runs"
# Only the gate's own run directories are pruned, and two guards keep it so:
# runs live under GATE_LOG_DIR/runs, and only names of the gate's exact shape
# are candidates. GATE_LOG_DIR may be a shared place; the rest is not ours.
FOREIGN=("$GATE_LOG_DIR/not-the-gates" "$GATE_LOG_DIR/keeplog-0123456789ab-20000101T000000Z"
         "$GATE_LOG_DIR/runs/not-the-gates" "$GATE_LOG_DIR/runs/keeplog-x-y"
         "$GATE_LOG_DIR/runs/keeplog-0123456789ab-notadate" "$GATE_LOG_DIR/runs/keeplog-0123456789AB-20000101T000000Z")
mkdir -p "${FOREIGN[@]}"
touch -d '2000-01-01' "${FOREIGN[@]}"
GATE_LOG_KEEP=1 "$GATE" "$WORK/keeplog" "$SHA" >/dev/null 2>&1 && fail "a failing eunit exited 0"
for d in "${FOREIGN[@]}"; do
    [ -d "$d" ] || fail "pruning deleted a directory the gate did not make: $d"
done
[ "$(find "$GATE_LOG_DIR/runs" -mindepth 1 -maxdepth 1 -regextype posix-extended \
      -regex '.*/keeplog-[0-9a-f]{12}-[0-9]{8}T[0-9]{6}Z' | wc -l)" -eq 1 ] \
    || fail "GATE_LOG_KEEP=1 did not prune the gate's own runs to one"

for v in 0 -1 x ""; do
    OUT=$(GATE_LOG_KEEP="$v" "$GATE" "$WORK/keeplog" "$SHA" 2>&1) && fail "GATE_LOG_KEEP='$v' was accepted: $OUT"
    grep -q "REFUSED: GATE_LOG_KEEP='$v'" <<<"$OUT" || fail "the refusal did not name GATE_LOG_KEEP='$v': $OUT"
    grep -qx "build-ran" <<<"$OUT" && fail "a step ran despite GATE_LOG_KEEP='$v': $OUT"
done
# A short sha on the command line still names the run with 12 hex digits,
# so the prune can recognise it.
rm -rf "$GATE_LOG_DIR"
OUT=$("$GATE" "$WORK/keeplog" "${SHA:0:7}" 2>&1) && fail "a failing eunit exited 0: $OUT"
grep -Eq "^log kept: $GATE_LOG_DIR/runs/keeplog-${SHA:0:12}-[0-9]{8}T[0-9]{6}Z$" <<<"$OUT" \
    || fail "a short sha did not name the run with the commit's first 12 hex digits: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "a pruned run left its workspace behind"

# 19. A timeout in the throttled pass says so, not that the job was too slow.
# shellcheck disable=SC2016 # expanded inside the container, on purpose
SHA=$(repo slowhang "$(fake_rebar3 'case "$(cat /sys/fs/cgroup/cpu.max)" in 50000*) sleep 600;; esac; echo eunit-ran')")
sed -i 's/^    runs-on: ubuntu-latest$/    runs-on: ubuntu-latest\n    timeout-minutes: 0.25/' "$WORK/slowhang/.github/workflows/lint.yml"
git -C "$WORK/slowhang" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qam slowhang
SHA=$(git -C "$WORK/slowhang" rev-parse HEAD)
OUT=$(GATE_TEST_CPUS=0.5 "$GATE" "$WORK/slowhang" "$SHA" 2>&1) && fail "a throttled pass past the timeout exited 0: $OUT"
grep -qx "eunit-ran" <<<"$OUT" || fail "the plain pass did not finish first: $OUT"
grep -q "REFUSED: the throttled test pass (--cpus=0.5) timed out" <<<"$OUT" || fail "the throttled timeout was not named as such: $OUT"
grep -q "REFUSED: the job timed out" <<<"$OUT" && fail "a throttled timeout was reported as the job's: $OUT"
[ "$(leftovers)" -eq 0 ] || fail "a throttled timeout left its workspace behind"

# 20. GATE_LOG_DIR at / or $HOME is refused before anything runs: the gate
#     writes and prunes there, so a slip must not reach either.
for v in / "$HOME" "$HOME/" "$HOME/." //; do
    OUT=$(GATE_LOG_DIR="$v" "$GATE" "$WORK/slowhang" "$SHA" 2>&1) && fail "GATE_LOG_DIR='$v' was accepted: $OUT"
    grep -q "REFUSED: GATE_LOG_DIR='$v'" <<<"$OUT" || fail "the refusal did not name GATE_LOG_DIR='$v': $OUT"
    grep -qx "build-ran" <<<"$OUT" && fail "a step ran despite GATE_LOG_DIR='$v': $OUT"
done

echo "OK: ci_gate.sh runs the job as CI would and leaves nothing behind"
