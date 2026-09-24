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
# What it cannot reproduce it refuses rather than approximates: a step using
# `if', `shell', `continue-on-error' or `timeout-minutes' stops the run before
# anything starts, naming the key. `uses:' steps are skipped and listed: the
# export replaces actions/checkout, and a cache only makes CI faster.
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

REPO="${1:?usage: $0 <repo> <sha> [workflow file] [job]}"
SHA="${2:?commit sha}"
WORKFLOW="${3:-lint.yml}"
JOB="${4:-check}"
ENGINE="${ENGINE:-podman}"
CPUS="${GATE_CPUS:-4}"
MEMORY="${GATE_MEMORY:-8g}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-gate.XXXXXX")"
# The container writes the job's _build into the export as root; under
# rootless podman those files belong to a subordinate uid, which only
# `podman unshare' may remove.
cleanup() {
    rm -rf "$WORK" 2>/dev/null || "$ENGINE" unshare rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$WORK/src"
git -C "$REPO" archive "$SHA" | tar -x -C "$WORK/src"

# The job script and image, from the workflow. Refuses what it cannot reproduce.
python3 - "$WORK" "$WORKFLOW" "$JOB" <<'PY'
import sys, shlex, yaml

work, workflow, job_name = sys.argv[1:4]
spec = yaml.safe_load(open(f"{work}/src/.github/workflows/{workflow}"))
job = spec["jobs"][job_name]
image = job["container"]["image"] if isinstance(job["container"], dict) else job["container"]

unsupported = {"if", "shell", "continue-on-error", "timeout-minutes"}
for step in job["steps"]:
    bad = sorted(unsupported & set(step))
    if bad:
        sys.exit(f"REFUSED: step {step.get('name', step.get('run', step.get('uses')))!r} "
                 f"uses {', '.join(bad)}, which this gate cannot reproduce")

def exports(env):
    return "".join(f"export {k}={shlex.quote(str(v))}\n" for k, v in (env or {}).items())

with open(f"{work}/job.sh", "w") as f:
    f.write("set -euo pipefail\ncd /w\n")
    f.write(exports(job.get("env")))
    for step in job["steps"]:
        if "uses" in step:
            print(f"skipped: uses: {step['uses']}")
            continue
        label = step.get("name", step["run"].splitlines()[0])
        f.write(f"echo {shlex.quote('>>> ' + label)}\n")
        f.write("(\n")
        f.write(exports(step.get("env")))
        if "working-directory" in step:
            f.write(f"cd {shlex.quote(step['working-directory'])}\n")
        f.write(step["run"] + "\n)\n")
        # Actions installed into $HOME/.cargo/bin reach later steps via
        # GITHUB_PATH in CI; here, through PATH.
        f.write('[ -d "$HOME/.cargo/bin" ] && export PATH="$HOME/.cargo/bin:$PATH" || true\n')

open(f"{work}/image", "w").write(image)
PY

IMAGE="$(cat "$WORK/image")"
echo "image: $IMAGE"
"$ENGINE" run --rm --user 0 --cpus="$CPUS" --memory="$MEMORY" \
    -e MAKEFLAGS=-j"$CPUS" -e CMAKE_BUILD_PARALLEL_LEVEL="$CPUS" -e CARGO_BUILD_JOBS="$CPUS" \
    -v "$WORK/src:/w:Z" -v "$WORK/job.sh:/job.sh:ro,Z" \
    "$IMAGE" bash /job.sh
