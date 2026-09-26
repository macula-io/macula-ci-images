#!/usr/bin/env bash
# Run one job of a repository's workflow the way CI runs it: inside the job's
# own pinned container image, as root, on a clean export of one commit.
#
# "Tests pass on my machine" proves the machine, not the gate. CI runs each
# step in the job's `container: image:`, as root, from a fresh checkout, and a
# local run differs in all three: another OTP, another user, a _build and a
# gitignored rebar.lock that outlived the source (the lock that pinned macula
# 11.4.0 under a 12.x constraint). This runs every `run:' step of the job, in
# order, in that image, on `git archive' of the commit, and exits with the
# job's status.
#
# Env is layered as CI layers it: the runner's CI, GITHUB_ACTIONS,
# GITHUB_WORKSPACE (/w) and GITHUB_SHA, then the workflow's `env', then the
# job's, then each step's. What a step appends to GITHUB_PATH and GITHUB_ENV
# reaches the steps after it.
#
# What it cannot reproduce it refuses rather than approximates: a step using
# `shell', `continue-on-error' or `timeout-minutes', an `if' other than
# `always()', or a `${{ }}' expression in the image or a run step, stops the
# run before anything starts, naming what it found. `uses:' steps are skipped
# and listed: the export replaces actions/checkout, and a cache only makes CI
# faster. An `if: always()' step runs after the others even when one failed,
# as in CI, and the job's `timeout-minutes' bounds the whole run.
#
# /tmp on host00 is a SHARED tmpfs (RAM). The export and the job's _build live
# in a temporary directory under TMPDIR, and an exit trap removes it whether
# the job passed, failed or was refused. Container limits default to the
# host00 build rules and can be overridden.
#
# GATE_TEST_CPUS=<fraction> (opt-in; use it before any release tag) re-runs
# only the job's test steps (rebar3 eunit/ct, mix test, cargo test, go test,
# gleam test, pytest) after the normal job has passed, in the same container
# with its cap lowered to that fraction of one CPU. Unset, the gate is the CI
# job and nothing more. A GitHub-hosted runner's core is slower than host00's
# and its speed varies by machine; a test that only fits its timeout on a fast core
# (RSA-4096 keygen inside eunit's 5 s, mcl-om 9c576f0) passes here and fails
# there. `--cpus=1' does not show that: one host00 core is about as fast as a
# typical runner. `GATE_TEST_CPUS=runner' is 0.5, measured on 2026-09-26: 20
# pq_hybrid keygens took p90 570-1290 ms on nine GitHub runner benches, and
# 525 ms uncapped, 669 at 1.0, 1519 at 0.5 and 2295 at 0.25 on host00. 0.5 is
# the largest cap at least as slow as the slowest runner's p90. It is a tail
# detector, not a proof: 9c576f0 went red at 0.5 in 2 of 3 runs, as it went
# red on CI in 1 of 1. A value that is not a decimal strictly between 0 and 1
# is refused, and so is a job with no test step.
#
# A failed run keeps its output and the tree's _build/test/logs (ct) under
# GATE_LOG_DIR (default ~/.cache/ci-gate), outside the cleaned workspace, and
# prints the failing tests' lines, so a failure that does not come back on a
# rerun is still named. A passing run keeps nothing; only the newest
# GATE_LOG_KEEP (20) kept runs stay.
#
# Uses podman (on host00, `docker' is rootless podman's compat API, which
# gives containers pids.max=1). Override with ENGINE=docker elsewhere.
# Needs git, python3 with PyYAML.
#
# Usage: scripts/ci_gate.sh <repo> <sha> [workflow file, default lint.yml] [job, default check]
#   e.g. scripts/ci_gate.sh ~/work/github.com/macula-services/mcl-om a340c1e lint-and-test.yml
#   GATE_CPUS=4 GATE_MEMORY=8g ENGINE=podman GATE_TEST_CPUS=runner|0.5
#   GATE_LOG_DIR=~/.cache/ci-gate GATE_LOG_KEEP=20
set -euo pipefail

# THE BODY IS ONE FUNCTION, CALLED ON THE LAST LINE AS `{ main "$@"; exit; }':
# bash parses the whole function, and that whole line, before running any of
# it, and the exit keeps it from reading past.
# A script rewritten in place while it runs (an editor, `open(path, "w")') is
# otherwise read on from the old byte offset: it corrupted a real run once.
# Nothing tests this: the corruption could not be reproduced on demand.
main() {

REPO="${1:?usage: $0 <repo> <sha> [workflow file] [job]}"
SHA="${2:?commit sha}"
WORKFLOW="${3:-lint.yml}"
JOB="${4:-check}"
ENGINE="${ENGINE:-podman}"
CPUS="${GATE_CPUS:-4}"
MEMORY="${GATE_MEMORY:-8g}"
LOG_DIR="${GATE_LOG_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ci-gate}"
LOG_KEEP="${GATE_LOG_KEEP-20}"   # set but empty is a mistake, not the default
if ! [[ "$LOG_KEEP" =~ ^[1-9][0-9]*$ ]]; then
    echo "REFUSED: GATE_LOG_KEEP='$LOG_KEEP' is not a positive whole number"
    exit 2
fi

# The throttle, checked before anything runs. Set but empty is a mistake, not off.
TEST_CPUS=""
if [ -n "${GATE_TEST_CPUS+set}" ]; then
    TEST_CPUS="$GATE_TEST_CPUS"
    [ "$TEST_CPUS" = runner ] && TEST_CPUS=0.5
    if ! [[ "$TEST_CPUS" =~ ^0\.[0-9]+$ ]] || [[ "$TEST_CPUS" =~ ^0\.0+$ ]]; then
        echo "REFUSED: GATE_TEST_CPUS='$GATE_TEST_CPUS' is not a decimal strictly between 0 and 1 (e.g. 0.5), or 'runner'"
        exit 2
    fi
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-gate.XXXXXX")"
NAME="ci-gate-$(basename "$WORK" | tr -cd 'A-Za-z0-9')"
# The container writes the job's _build into the export as root; under
# rootless podman those files belong to a subordinate uid, which only
# `podman unshare' may remove. The container is named, so a run cut short by
# its timeout removes exactly the container it started and no other.
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() {
    "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$WORK" 2>/dev/null || "$ENGINE" unshare rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$WORK/src" "$WORK/carry"
git -C "$REPO" archive "$SHA" | tar -x -C "$WORK/src"

# The job script and image, from the workflow. Refuses what it cannot reproduce.
python3 - "$WORK" "$WORKFLOW" "$JOB" "$SHA" "$TEST_CPUS" <<'PY'
import sys, shlex, yaml

work, workflow, job_name, sha, test_cpus = sys.argv[1:6]
spec = yaml.safe_load(open(f"{work}/src/.github/workflows/{workflow}"))
job = (spec.get("jobs") or {}).get(job_name)
if job is None:
    sys.exit(f"REFUSED: {workflow} has no job {job_name!r} "
             f"(it has: {', '.join(sorted(spec.get('jobs') or {})) or 'none'})")
container = job.get("container")
image = container.get("image") if isinstance(container, dict) else container
if not image:
    sys.exit(f"REFUSED: job {job_name!r} has no container image; it runs on the runner's own "
             "toolchain (e.g. setup-beam on ubuntu-latest), which this gate cannot reproduce")

import re

def label_of(step):
    return step.get("name", step.get("run", step.get("uses")))

unsupported = {"shell", "continue-on-error", "timeout-minutes"}
for step in job["steps"]:
    bad = sorted(unsupported & set(step))
    if "if" in step and str(step["if"]).strip() != "always()":
        bad.append(f"if: {step['if']}")
    if bad:
        sys.exit(f"REFUSED: step {label_of(step)!r} uses {', '.join(bad)}, "
                 f"which this gate cannot reproduce")

# A ${{ }} expression is evaluated by the runner before the shell sees it; the
# gate cannot, and bash would get the literal text.
EXPR = re.compile(r"\$\{\{[^}]*\}\}")
found = (EXPR.findall(str(image))
         + [e for s in job["steps"] for e in EXPR.findall(s.get("run", ""))]
         + [e for env in [spec.get("env"), job.get("env")] + [s.get("env") for s in job["steps"]]
            for v in (env or {}).values() for e in EXPR.findall(str(v))])
if found:
    sys.exit(f"REFUSED: GitHub expressions this gate cannot evaluate: {', '.join(sorted(set(found)))}")

def exports(env):
    return "".join(f"export {k}={shlex.quote(str(v))}\n" for k, v in (env or {}).items())

def write_step(f, step):
    label = step.get("name", step["run"].splitlines()[0])
    f.write(f"echo {shlex.quote('>>> ' + label)}\n")
    f.write("(\n")
    f.write(exports(step.get("env")))
    if "working-directory" in step:
        f.write(f"cd {shlex.quote(step['working-directory'])}\n")
    f.write(step["run"] + "\n)\n")
    # What a step appended to GITHUB_PATH and GITHUB_ENV reaches the steps
    # after it, as the runner carries it (KEY=VALUE lines; the multi-line
    # heredoc form is not supported).
    # Kept in /carry too, so the throttled test pass starts where they left off.
    f.write('cat "$GITHUB_PATH" >> /carry/path; cat "$GITHUB_ENV" >> /carry/env\n')
    f.write('while IFS= read -r p; do [ -z "$p" ] || PATH="$p:$PATH"; done < "$GITHUB_PATH"\n'
            'export PATH; : > "$GITHUB_PATH"\n'
            'while IFS= read -r kv; do case "$kv" in *=*) export "${kv%%=*}=${kv#*=}";; esac; '
            'done < "$GITHUB_ENV"\n'
            ': > "$GITHUB_ENV"\n')

for step in job["steps"]:
    if "uses" in step:
        print(f"skipped: uses: {step['uses']}")
plain = [s for s in job["steps"] if "run" in s and "if" not in s]
always = [s for s in job["steps"] if "run" in s and "if" in s]

# The plain steps stop at the first failure; the always() steps run after
# them regardless, each on its own; the job fails if any of them failed.
#
# Each phase is its own bash process. `set -e' is ignored inside a compound
# command whose status is tested (`( ... ) || status=$?'), so a subshell would
# carry on past a failing step; a separate process keeps its own errexit.
import os
os.makedirs(f"{work}/gate")

# Env as CI layers it: the runner's own variables a step may read, then the
# workflow's env, then the job's, then (in write_step) the step's.
RUNNER = {"CI": "true", "GITHUB_ACTIONS": "true", "GITHUB_WORKSPACE": "/w", "GITHUB_SHA": sha,
          "GITHUB_PATH": "/tmp/ci-gate-github-path", "GITHUB_ENV": "/tmp/ci-gate-github-env"}

def phase(path, steps, replay=False):
    with open(path, "w") as f:
        f.write("set -euo pipefail\ncd /w\n")
        f.write(exports(RUNNER))
        f.write(': >> "$GITHUB_PATH"; : >> "$GITHUB_ENV"\n')
        if replay:
            f.write('cp /carry/path "$GITHUB_PATH"; cp /carry/env "$GITHUB_ENV"; : > /carry/path; : > /carry/env\n'
                    'while IFS= read -r p; do [ -z "$p" ] || PATH="$p:$PATH"; done < "$GITHUB_PATH"\n'
                    'export PATH; : > "$GITHUB_PATH"\n'
                    'while IFS= read -r kv; do case "$kv" in *=*) export "${kv%%=*}=${kv#*=}";; esac; '
                    'done < "$GITHUB_ENV"\n'
                    ': > "$GITHUB_ENV"\n')
        f.write(exports(spec.get("env")))
        f.write(exports(job.get("env")))
        for step in steps:
            write_step(f, step)

phase(f"{work}/gate/plain.sh", plain)
for i, step in enumerate(always):
    phase(f"{work}/gate/always_{i:02d}.sh", [step])
with open(f"{work}/gate/entry.sh", "w") as f:
    f.write('if [ -e /carry/throttled ]; then exec bash /gate/test.sh; else exec bash /gate/job.sh; fi\n')
with open(f"{work}/gate/job.sh", "w") as f:
    f.write("status=0\nbash /gate/plain.sh || status=$?\n")
    f.write('for f in /gate/always_*.sh; do\n'
            '  [ -e "$f" ] || continue\n'
            '  bash "$f" || { s=$?; [ "$status" -ne 0 ] || status=$s; }\n'
            'done\nexit "$status"\n')

# The throttled pass: the plain steps that run a test suite, and nothing else.
TEST = re.compile(r"\brebar3\b[^\n|;&]*\b(eunit|ct)\b|\bmix\s+test\b|\bcargo\s+(test|nextest)\b"
                  r"|\bgo\s+test\b|\bgleam\s+test\b|\bpytest\b")
if test_cpus:
    tests = [s for s in plain if TEST.search(s["run"])]
    if not tests:
        sys.exit(f"REFUSED: GATE_TEST_CPUS is set but job {job_name!r} has no test step "
                 f"(its run steps: {', '.join(repr(label_of(s)) for s in plain) or 'none'})")
    phase(f"{work}/gate/test.sh", tests, replay=True)

open(f"{work}/image", "w").write(image)
open(f"{work}/timeout", "w").write(str(job.get("timeout-minutes", "")))
PY

IMAGE="$(cat "$WORK/image")"
MINUTES="$(cat "$WORK/timeout")"
echo "image: $IMAGE"
# The job's timeout-minutes bounds the whole run, as in CI. Without one, none.
LIMIT=()
SECONDS_ALLOWED=""
if [ -n "$MINUTES" ]; then
    SECONDS_ALLOWED="$(python3 -c "print(int(float('$MINUTES') * 60) or 1)")"
    LIMIT=(timeout --kill-after=30 "$SECONDS_ALLOWED")
fi
# One pass of the job's container, bounded by the job's timeout, its output
# shown and appended to the job log. Sets STATUS. The throttled pass restarts
# the SAME container with its cap lowered, so what the job's steps installed
# outside the tree is still there, as it is for the rest of a CI job; the
# entry script picks the test steps once /carry/throttled exists. The exit
# trap removes the container.
run_pass() {
    local what="$1" started
    shift
    started=$(date +%s)
    set +e
    "${LIMIT[@]}" "$@" 2>&1 | tee -a "$WORK/job.log"
    STATUS=${PIPESTATUS[0]}
    set -e
    # Timed out is decided by the clock, not the status: TERM gives 124, an
    # escalation to KILL gives 137, and 137 is also what an OOM kill looks like.
    if [ -n "$SECONDS_ALLOWED" ] && [ "$STATUS" -ne 0 ] \
       && [ $(( $(date +%s) - started )) -ge "$SECONDS_ALLOWED" ]; then
        echo "REFUSED: $what timed out after the job's timeout-minutes ($MINUTES)" | tee -a "$WORK/job.log"
    fi
}

# --init: the job's bash is not PID 1, so the timeout's SIGTERM reaches it (a
# PID 1 without handlers ignores it, and the run waits for SIGKILL).
run_pass "the job" "$ENGINE" run --init --name "$NAME" --user 0 --cpus="$CPUS" --memory="$MEMORY" \
    -e MAKEFLAGS=-j"$CPUS" -e CMAKE_BUILD_PARALLEL_LEVEL="$CPUS" -e CARGO_BUILD_JOBS="$CPUS" \
    -v "$WORK/src:/w:Z" -v "$WORK/gate:/gate:ro,Z" -v "$WORK/carry:/carry:Z" \
    "$IMAGE" bash /gate/entry.sh
if [ "$STATUS" -eq 0 ] && [ -n "$TEST_CPUS" ]; then
    echo ">>> throttled test pass: the test steps again under --cpus=$TEST_CPUS" | tee -a "$WORK/job.log"
    touch "$WORK/carry/throttled"
    "$ENGINE" update --cpus="$TEST_CPUS" "$NAME" >/dev/null
    run_pass "the throttled test pass (--cpus=$TEST_CPUS)" "$ENGINE" start -a "$NAME"
    if [ "$STATUS" -eq 0 ]; then
        echo "throttled test pass passed under --cpus=$TEST_CPUS"
    else
        echo "throttled test pass FAILED under --cpus=$TEST_CPUS (exit $STATUS)"
    fi
fi

# A failure is named and kept: the lines that say which tests failed, and the
# whole log plus the test logs outside the workspace the exit trap removes.
# Only the newest GATE_LOG_KEEP kept runs stay; $HOME is disk, not tmpfs, but
# it is not bottomless either.
if [ "$STATUS" -ne 0 ]; then
    KEEP="$LOG_DIR/$(basename "$REPO")-${SHA:0:12}-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$KEEP"
    sed 's/\x1b\[[0-9;]*m//g' "$WORK/job.log" > "$KEEP/job.log"
    if [ -d "$WORK/src/_build/test/logs" ]; then
        cp -r "$WORK/src/_build/test/logs" "$KEEP/test-logs" 2>/dev/null \
            || "$ENGINE" unshare cp -r "$WORK/src/_build/test/logs" "$KEEP/test-logs"
    fi
    echo "failures:"
    grep -E -A2 '\*failed\*|\*timed out\*|\*\*\* .* \*\*\*|\*unexpected termination|[0-9]+ cancelled|Failed: [0-9]|[0-9]+ failures?\b|%%% .*==> |^  [0-9]+\) |^  [a-z][A-Za-z0-9_]*:[a-z][A-Za-z0-9_]*/[0-9]+|%% Unknown error' \
        "$KEEP/job.log" | head -200 || echo "(no test failure lines; see the log)"
    echo "log kept: $KEEP"
    find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn \
        | tail -n +$((LOG_KEEP + 1)) | while IFS=' ' read -r _ old; do
        rm -rf "$old" 2>/dev/null || "$ENGINE" unshare rm -rf "$old"
    done
fi
exit "$STATUS"
}

# shellcheck disable=SC2317 # main exits itself; this exit stops bash reading on
{ main "$@"; exit; }
