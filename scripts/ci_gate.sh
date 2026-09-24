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
# Uses podman (on host00, `docker' is rootless podman's compat API, which
# gives containers pids.max=1). Override with ENGINE=docker elsewhere.
# Needs git, python3 with PyYAML.
#
# Usage: scripts/ci_gate.sh <repo> <sha> [workflow file, default lint.yml] [job, default check]
#   e.g. scripts/ci_gate.sh ~/work/github.com/macula-services/mcl-om a340c1e lint-and-test.yml
#   GATE_CPUS=4 GATE_MEMORY=8g ENGINE=podman
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

mkdir -p "$WORK/src"
git -C "$REPO" archive "$SHA" | tar -x -C "$WORK/src"

# The job script and image, from the workflow. Refuses what it cannot reproduce.
python3 - "$WORK" "$WORKFLOW" "$JOB" "$SHA" <<'PY'
import sys, shlex, yaml

work, workflow, job_name, sha = sys.argv[1:5]
spec = yaml.safe_load(open(f"{work}/src/.github/workflows/{workflow}"))
job = spec["jobs"][job_name]
image = job["container"]["image"] if isinstance(job["container"], dict) else job["container"]

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

def phase(path, steps):
    with open(path, "w") as f:
        f.write("set -euo pipefail\ncd /w\n")
        f.write(exports(RUNNER))
        f.write(': >> "$GITHUB_PATH"; : >> "$GITHUB_ENV"\n')
        f.write(exports(spec.get("env")))
        f.write(exports(job.get("env")))
        for step in steps:
            write_step(f, step)

phase(f"{work}/gate/plain.sh", plain)
for i, step in enumerate(always):
    phase(f"{work}/gate/always_{i:02d}.sh", [step])
with open(f"{work}/gate/job.sh", "w") as f:
    f.write("status=0\nbash /gate/plain.sh || status=$?\n")
    f.write('for f in /gate/always_*.sh; do\n'
            '  [ -e "$f" ] || continue\n'
            '  bash "$f" || { s=$?; [ "$status" -ne 0 ] || status=$s; }\n'
            'done\nexit "$status"\n')

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
STARTED=$(date +%s)
set +e
# --init: the job's bash is not PID 1, so the timeout's SIGTERM reaches it (a
# PID 1 without handlers ignores it, and the run waits for SIGKILL).
"${LIMIT[@]}" "$ENGINE" run --rm --init --name "$NAME" --user 0 --cpus="$CPUS" --memory="$MEMORY" \
    -e MAKEFLAGS=-j"$CPUS" -e CMAKE_BUILD_PARALLEL_LEVEL="$CPUS" -e CARGO_BUILD_JOBS="$CPUS" \
    -v "$WORK/src:/w:Z" -v "$WORK/gate:/gate:ro,Z" \
    "$IMAGE" bash /gate/job.sh
STATUS=$?
set -e
# Timed out is decided by the clock, not the status: TERM gives 124, an
# escalation to KILL gives 137, and 137 is also what an OOM kill looks like.
if [ -n "$SECONDS_ALLOWED" ] && [ "$STATUS" -ne 0 ] \
   && [ $(( $(date +%s) - STARTED )) -ge "$SECONDS_ALLOWED" ]; then
    echo "REFUSED: the job timed out after its timeout-minutes ($MINUTES)"
fi
exit "$STATUS"
}

# shellcheck disable=SC2317 # main exits itself; this exit stops bash reading on
{ main "$@"; exit; }
