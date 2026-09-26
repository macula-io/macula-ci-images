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
# `shell', `continue-on-error' or `timeout-minutes', a run step's `if' that
# reads anything but matrix values, literals, always() and success(), or a
# `${{ }}' expression other than `${{ matrix.X }}' in the image, env or a run
# step, stops the run before anything starts, naming what it found. `uses:'
# steps are skipped and listed, their `if' unevaluated: the export replaces
# actions/checkout, and a cache or an artifact upload only serves CI. An `if'
# with always() runs after the others even when one failed, as in CI, and the
# job's `timeout-minutes' bounds the whole run.
#
# A `strategy.matrix' job (plain axes; include/exclude and a computed matrix
# are refused) runs once per combination, in the matrix's order, each on its
# own fresh export and container, as CI runs each as its own job, with
# `${{ matrix.X }}' substituted and each step's `if' evaluated for it. Every
# combination runs even after one fails (CI's fail-fast would cancel the
# rest and hide a second failure), one line per combination is printed, and
# the gate fails if any did. GATE_MATRIX='check=eunit' (one value per axis,
# comma-separated) runs only that one. Every combination is checked before
# any runs. GATE_DRY_RUN=1 prints what each combination would run and runs
# nothing.
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
# GATE_LOG_KEEP (20) kept runs stay. Runs go in GATE_LOG_DIR/runs, pruning
# touches only the gate's own run names there, and GATE_LOG_DIR at / or $HOME
# is refused.
#
# Uses podman (on host00, `docker' is rootless podman's compat API, which
# gives containers pids.max=1). Override with ENGINE=docker elsewhere.
# Needs git, python3 with PyYAML.
#
# Usage: scripts/ci_gate.sh <repo> <sha> [workflow file, default lint.yml] [job, default check]
#   e.g. scripts/ci_gate.sh ~/work/github.com/macula-services/mcl-om a340c1e lint-and-test.yml
#   GATE_CPUS=4 GATE_MEMORY=8g ENGINE=podman GATE_TEST_CPUS=runner|0.5
#   GATE_LOG_DIR=~/.cache/ci-gate GATE_LOG_KEEP=20
#   GATE_MATRIX=check=eunit GATE_DRY_RUN=1
#   e.g. GATE_TEST_CPUS=runner scripts/ci_gate.sh ~/work/github.com/macula-io/macula <sha> test.yml test
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
# The gate writes and prunes under LOG_DIR/runs; a slip that points it at / or
# $HOME is refused, not trusted to the prune's own guards.
case "$(realpath -m "$LOG_DIR")" in
    / | "$(realpath -m "$HOME")")
        echo "REFUSED: GATE_LOG_DIR='$LOG_DIR' is / or \$HOME; give the gate a directory of its own"
        exit 2;;
esac
RUNS="$LOG_DIR/runs"

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

if [ -n "${GATE_DRY_RUN+set}" ] && [ "$GATE_DRY_RUN" != 1 ]; then
    echo "REFUSED: GATE_DRY_RUN='$GATE_DRY_RUN'; set it to 1 or leave it unset"
    exit 2
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

import re, os, copy, itertools

def label_of(step):
    return step.get("name", step.get("run", step.get("uses")))

unsupported = {"shell", "continue-on-error", "timeout-minutes"}
for step in job["steps"]:
    bad = sorted(unsupported & set(step))
    if bad:
        sys.exit(f"REFUSED: step {label_of(step)!r} uses {', '.join(bad)}, "
                 f"which this gate cannot reproduce")

# The matrix: plain axes only, each a list of scalars. A combination is one
# value per axis; the gate runs each on its own fresh export, as CI runs each
# as its own job. include/exclude and a computed matrix are refused.
def sv(v):
    return {True: "true", False: "false"}.get(v, str(v)) if isinstance(v, bool) else str(v)

strategy = job.get("strategy") or {}
matrix = strategy.get("matrix")
axes = {}
if matrix is not None:
    if not isinstance(matrix, dict):
        sys.exit(f"REFUSED: job {job_name!r} has a computed matrix {matrix!r}, which this gate cannot reproduce")
    for key, values in matrix.items():
        if key in ("include", "exclude"):
            sys.exit(f"REFUSED: job {job_name!r} uses matrix {key}, which this gate cannot reproduce")
        if not isinstance(values, list) or not values \
           or not all(isinstance(v, (str, int, float, bool)) for v in values):
            sys.exit(f"REFUSED: matrix axis {key!r} of job {job_name!r} is not a list of plain values: {values!r}")
        if any("," in sv(v) or "=" in sv(v) for v in values):
            sys.exit(f"REFUSED: matrix axis {key!r} has a value with ',' or '=': {values!r}")
        axes[key] = values
combos = [dict(zip(axes, vs)) for vs in itertools.product(*axes.values())] if axes else [{}]

def combo_str(c):
    return ",".join(f"{k}={sv(v)}" for k, v in c.items())

requested = os.environ.get("GATE_MATRIX")
child = os.environ.get("GATE_MATRIX_CHILD") == "1"
dry = os.environ.get("GATE_DRY_RUN") == "1"
selected = None
if requested is not None:
    if not axes:
        sys.exit(f"REFUSED: GATE_MATRIX={requested!r} but job {job_name!r} has no matrix")
    pairs = [p.split("=", 1) for p in requested.split(",")] if requested else [[""]]
    keys = [p[0] for p in pairs]
    valid = ", ".join(combo_str(c) for c in combos)
    if any(len(p) != 2 for p in pairs) or len(set(keys)) != len(keys) or set(keys) != set(axes):
        sys.exit(f"REFUSED: GATE_MATRIX={requested!r} is not one value for each of {', '.join(axes)} "
                 f"(the combinations: {valid})")
    given = dict(pairs)
    matches = [c for c in combos if all(sv(c[k]) == given[k] for k in axes)]
    if not matches:
        sys.exit(f"REFUSED: GATE_MATRIX={requested!r} is not a combination of this matrix (they are: {valid})")
    selected = matches[0]

# A step's `if', for one combination, with GitHub's expression semantics.
# What it may read: matrix values (typed as the YAML has them), string and
# number literals, true/false, always() and success(), joined by ==, !=, !,
# && and || with parentheses; precedence ! > ==/!= > && > ||. == between two
# strings ignores case; between different types it compares as numbers (true
# is 1, '' is 0, a string that is not a number is NaN, which equals nothing).
# A bare value is truthy unless it is false, 0, '' or NaN. Anything else
# (failure(), steps.*, github.*, functions) is refused by name on a run step.
# A uses: step is skipped, so its if is not evaluated at all.
TOKEN = re.compile(r"\s*(?:(\(|\)|&&|\|\||!=|==|!)|(always\(\)|success\(\))|(true|false)\b"
                   r"|'((?:[^']|'')*)'|(-?\d+(?:\.\d+)?)\b|matrix\.([A-Za-z_][A-Za-z0-9_-]*))")

def number(v):
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(v.strip()) if v.strip() else 0.0
    except ValueError:
        return float("nan")

def equal(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    if isinstance(a, bool) and isinstance(b, bool):
        return a == b
    return number(a) == number(b)   # NaN == anything is False

def truthy(v):
    if isinstance(v, str):
        return v != ""
    return v == v and v != 0        # False, 0, 0.0 and NaN are falsy

def evaluate(step, combo):
    text = str(step["if"]).strip()
    whole = re.fullmatch(r"\$\{\{(.*)\}\}", text, re.S)
    body = (whole.group(1) if whole else text).strip()
    refuse = f"REFUSED: step {label_of(step)!r} uses if: {step['if']}, which this gate cannot reproduce"
    tokens, pos, status = [], 0, False
    while pos < len(body):
        m = TOKEN.match(body, pos)
        if not m or m.end() == pos:
            sys.exit(refuse)
        op, fn, lit, string, num, key = m.groups()
        if op:
            tokens.append(("op", op))
        elif fn:
            status = status or fn == "always()"
            tokens.append(("val", True))
        elif lit:
            tokens.append(("val", lit == "true"))
        elif string is not None:
            tokens.append(("val", string.replace("''", "'")))
        elif num:
            tokens.append(("val", float(num)))
        else:
            if key not in combo:
                sys.exit(refuse)
            tokens.append(("val", combo[key]))
        pos = m.end()
    tokens.append(("end", None))
    at = [0]
    def peek():
        return tokens[at[0]]
    def take(kind, value=None):
        t = tokens[at[0]]
        if t[0] != kind or (value is not None and t[1] != value):
            sys.exit(refuse)
        at[0] += 1
        return t[1]
    def primary():
        if peek() == ("op", "("):
            take("op", "(")
            v = disjunction()
            take("op", ")")
            return v
        return take("val")
    def unary():
        if peek() == ("op", "!"):
            take("op", "!")
            return not truthy(unary())
        return primary()
    def comparison():
        v = unary()
        if peek() in (("op", "=="), ("op", "!=")):
            op = take("op")
            w = unary()
            return equal(v, w) == (op == "==")
        return v
    def conjunction():
        v = comparison()
        while peek() == ("op", "&&"):
            take("op", "&&")
            w = comparison()
            v = w if truthy(v) else v
        return v
    def disjunction():
        v = conjunction()
        while peek() == ("op", "||"):
            take("op", "||")
            w = conjunction()
            v = v if truthy(v) else w
        return v
    result = disjunction()
    take("end")
    return truthy(result), status

# ${{ matrix.X }} is substituted for the combination; any other ${{ }} is
# evaluated by the runner before the shell sees it, which the gate cannot do,
# and bash would get the literal text.
MATRIX_EXPR = re.compile(r"\$\{\{\s*matrix\.([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}")
EXPR = re.compile(r"\$\{\{[^}]*\}\}")

def substitute(value, combo):
    return MATRIX_EXPR.sub(lambda m: sv(combo[m.group(1)]) if m.group(1) in combo else m.group(0), str(value))

TEST = re.compile(r"\brebar3\b[^\n|;&]*\b(eunit|ct)\b|\bmix\s+test\b|\bcargo\s+(test|nextest)\b"
                  r"|\bgo\s+test\b|\bgleam\s+test\b|\bpytest\b")

def plan_for(combo):
    steps = copy.deepcopy(job["steps"])
    envs = [copy.deepcopy(spec.get("env") or {}), copy.deepcopy(job.get("env") or {})]
    img = substitute(image, combo)
    for env in envs + [s.setdefault("env", {}) for s in steps if "run" in s]:
        for k in env:
            env[k] = substitute(env[k], combo)
    for s in steps:
        for k in ("run", "working-directory"):
            if k in s:
                s[k] = substitute(s[k], combo)
    found = (EXPR.findall(img)
             + [e for s in steps for k in ("run", "working-directory") for e in EXPR.findall(s.get(k, ""))]
             + [e for env in envs + [s.get("env") or {} for s in steps] for v in env.values()
                for e in EXPR.findall(str(v))])
    if found:
        sys.exit(f"REFUSED: GitHub expressions this gate cannot evaluate: {', '.join(sorted(set(found)))}")
    plan = {"image": img, "env": envs, "plain": [], "always": [], "not_run": [], "uses": [], "order": []}
    for s in steps:
        if "uses" in s:
            plan["uses"].append(s)
            continue
        runs, always_ = evaluate(s, combo) if "if" in s else (True, False)
        kind = "not_run" if not runs else "always" if always_ else "plain"
        plan[kind].append(s)
        plan["order"].append((kind, s))
    plan["tests"] = [s for s in plan["plain"] if TEST.search(s["run"])]
    return plan

# Every combination is checked before any runs, so a matrix the gate cannot
# reproduce is refused whole, before anything starts.
plans = {combo_str(c): plan_for(c) for c in combos}

if axes and selected is None:
    if test_cpus and not any(p["tests"] for p in plans.values()):
        sys.exit(f"REFUSED: GATE_TEST_CPUS is set but no combination of job {job_name!r} has a test step")
    open(f"{work}/fanout", "w").write("".join(f"{c}\n" for c in plans))
    sys.exit(0)

plan = plans[combo_str(selected or {})]
image = plan["image"]
if axes:
    print(f"matrix: {combo_str(selected)}")
for step in plan["uses"]:
    print(f"skipped: uses: {step['uses']}")
if dry:
    words = {"plain": "run", "always": "always", "not_run": "not run"}
    for kind, step in plan["order"]:
        print(f"  {words[kind]}: {label_of(step)}")

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

plain = plan["plain"]
always = plan["always"]

# The plain steps stop at the first failure; the always() steps run after
# them regardless, each on its own; the job fails if any of them failed.
#
# Each phase is its own bash process. `set -e' is ignored inside a compound
# command whose status is tested (`( ... ) || status=$?'), so a subshell would
# carry on past a failing step; a separate process keeps its own errexit.
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
        f.write(exports(plan["env"][0]))
        f.write(exports(plan["env"][1]))
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
# A combination the gate fanned out that has none is noted and skipped; the
# fan-out already refused a matrix where no combination has one.
if test_cpus:
    tests = plan["tests"]
    if tests:
        phase(f"{work}/gate/test.sh", tests, replay=True)
        if dry:
            print(f"  test steps: {', '.join(label_of(s) for s in tests)}")
    elif child:
        print("  test steps: none in this combination; no throttled pass")
    else:
        sys.exit(f"REFUSED: GATE_TEST_CPUS is set but job {job_name!r} has no test step "
                 f"(its run steps: {', '.join(repr(label_of(s)) for s in plain) or 'none'})")

open(f"{work}/image", "w").write(image)
open(f"{work}/timeout", "w").write(str(job.get("timeout-minutes", "")))
PY

# A matrix job with no GATE_MATRIX: every combination, each a gate run of its
# own (fresh export, fresh container), then one line per combination. The gate
# fails if any combination failed, as the workflow does; unlike CI's default
# fail-fast, every combination runs, so one failure does not hide another.
if [ -e "$WORK/fanout" ]; then
    local status=0 results=() c s
    # The list is read on fd 3 and each child gets /dev/null on stdin: a
    # child's run (podman start -a, in the throttled pass) otherwise reads the
    # rest of the list to EOF, and the gate ran one combination and reported
    # green.
    while IFS= read -r c <&3; do
        set +e
        GATE_MATRIX="$c" GATE_MATRIX_CHILD=1 bash "${BASH_SOURCE[0]}" "$@" </dev/null
        s=$?
        set -e
        if [ "$s" -eq 0 ] && [ "${GATE_DRY_RUN:-}" = 1 ]; then
            results+=("matrix ${c}: planned")
        elif [ "$s" -eq 0 ]; then
            results+=("matrix ${c}: passed")
        else
            results+=("matrix ${c}: FAILED (exit $s)")
            [ "$status" -ne 0 ] || status=$s
        fi
    done 3< "$WORK/fanout"
    printf '%s\n' "${results[@]}"
    # Guard the outcome as well as the cause: a fan-out that reports fewer
    # combinations than it planned is refused, never green.
    local planned
    planned=$(grep -c . "$WORK/fanout")
    if [ "${#results[@]}" -ne "$planned" ]; then
        echo "REFUSED: the matrix planned $planned combinations but ${#results[@]} reported"
        exit 1
    fi
    exit "$status"
fi

IMAGE="$(cat "$WORK/image")"
MINUTES="$(cat "$WORK/timeout")"
echo "image: $IMAGE"
if [ "${GATE_DRY_RUN:-}" = 1 ]; then
    echo "dry run: nothing ran"
    exit 0
fi
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
if [ "$STATUS" -eq 0 ] && [ -n "$TEST_CPUS" ] && [ -e "$WORK/gate/test.sh" ]; then
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
# it is not bottomless either. Runs live in LOG_DIR/runs, and the prune
# touches only names of the shape written here: GATE_LOG_DIR may be shared.
if [ "$STATUS" -ne 0 ]; then
    # A combination is part of the name, so two combinations of one commit
    # failing in the same second keep two runs, not one.
    KEEP="$RUNS/$(basename "$REPO")${GATE_MATRIX:+.$(tr -c 'A-Za-z0-9._=,-' _ <<<"$GATE_MATRIX" | head -c -1)}-$(git -C "$REPO" rev-parse "$SHA^{commit}" | head -c 12)-$(date -u +%Y%m%dT%H%M%SZ)"
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
    # Two guards, so neither alone keeps the invariant: only under RUNS, and
    # only names of exactly the shape the line above writes.
    find "$RUNS" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[^/]+-[0-9a-f]{12}-[0-9]{8}T[0-9]{6}Z' -printf '%T@ %p\n' | sort -rn \
        | tail -n +$((LOG_KEEP + 1)) | while IFS=' ' read -r _ old; do
        rm -rf "$old" 2>/dev/null || "$ENGINE" unshare rm -rf "$old"
    done
fi
exit "$STATUS"
}

# shellcheck disable=SC2317 # main exits itself; this exit stops bash reading on
{ main "$@"; exit; }
