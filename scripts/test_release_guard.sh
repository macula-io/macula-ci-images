#!/usr/bin/env bash
# Does the release guard refuse a tag outside the default branch, and a release whose
# versions disagree, and leave everything else alone?
#
# The cases run against the guard AS EMBEDDED IN THE WORKFLOW, which is the copy a
# caller actually executes: a reusable workflow runs in the caller's repository, so the
# block travels inside release-guard.yml rather than being read from a path the caller
# would have to supply. The copy is extracted from the workflow by its markers, so the
# few lines that extract it are the only part of this file that a green run does not
# cover. Three checks first say that the embedded block is the script in this
# directory, that it parses, and that attest-image.yml embeds the same bytes.
#
# Then it builds throwaway git repositories and fixtures under a temporary directory: a
# tag on a side-branch commit and a tag on the default branch, a BEAM tree that is
# consistent and one whose relx release drifts from its app, a package.json that
# matches and one that does not, manifests that name no literal version, and refs that
# are not release tags. Each case states the exit code the guard must return, so a run
# is green only when every refusal and every pass happens for the right reason.
#
# Usage: scripts/test_release_guard.sh [--verbose]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$HERE/release_guard.sh"
GUARD_WORKFLOW="$ROOT/.github/workflows/release-guard.yml"
ATTEST_WORKFLOW="$ROOT/.github/workflows/attest-image.yml"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
GUARD="$WORK/release_guard.sh"

failures=0
cases=0

# run_case <name> <expected exit> <command...>
# Prints the case, its exit code and the guard's own output; counts a failure when the
# exit code is not the one the case states.
run_case() {
  local name="$1" expected="$2" out status
  shift 2
  cases=$((cases + 1))
  out="$("$@" 2>&1)"
  status=$?
  if [ "$status" -eq "$expected" ]; then
    printf 'ok   %-58s exit %s\n' "$name" "$status"
  else
    printf 'FAIL %-58s exit %s, expected %s\n' "$name" "$status" "$expected"
    failures=$((failures + 1))
  fi
  if [ "$VERBOSE" -eq 1 ] || [ "$status" -ne "$expected" ]; then
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

# check <name> <command...>
# For the invariants that are not an exit code from the guard.
check() {
  local name="$1"
  shift
  cases=$((cases + 1))
  if "$@" > /dev/null 2>&1; then
    printf 'ok   %-58s\n' "$name"
  else
    printf 'FAIL %-58s\n' "$name"
    failures=$((failures + 1))
  fi
}

# extract_script <workflow>
# Prints the guard block a workflow writes to the runner, with the indentation that YAML
# strips taken off, so the result is the file the runner gets.
extract_script() {
  awk -v open_mark="<<'RELEASE_GUARD_SCRIPT'" -v close_mark="RELEASE_GUARD_SCRIPT" '
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
  ' "$1"
}

extract_script "$GUARD_WORKFLOW" > "$GUARD"
chmod +x "$GUARD"
ATTESTED="$WORK/release_guard-attest-image.sh"
extract_script "$ATTEST_WORKFLOW" > "$ATTESTED"

check "the block in release-guard.yml is scripts/release_guard.sh" cmp -s "$SOURCE" "$GUARD"
check "the block in release-guard.yml parses" bash -n "$GUARD"
check "attest-image.yml embeds the same block" cmp -s "$GUARD" "$ATTESTED"

# --- a repository with a side branch, for the ancestry check ----------------------
REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email guard@example.invalid
git -C "$REPO" config user.name "release guard test"
printf 'one\n' > "$REPO/file"
git -C "$REPO" add file
git -C "$REPO" commit -q -m "the only commit on main"
ON_MAIN="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" switch -q -c side
printf 'side\n' >> "$REPO/file"
git -C "$REPO" commit -qam "a commit only the side branch has"
OFF_MAIN="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" switch -q main
# The guard reads origin/<default>, as it does in a CI checkout.
git -C "$REPO" remote add origin "$REPO"
git -C "$REPO" fetch -q origin "+refs/heads/*:refs/remotes/origin/*"

run_case "tag on a commit that is only on the side branch is refused" 1 \
  env -C "$REPO" "$GUARD" on-branch refs/tags/v1.2.3 "$OFF_MAIN" main
run_case "tag on a commit that is on the default branch passes" 0 \
  env -C "$REPO" "$GUARD" on-branch refs/tags/v1.2.3 "$ON_MAIN" main
run_case "a branch ref is not a release and passes" 0 \
  env -C "$REPO" "$GUARD" on-branch refs/heads/main "$OFF_MAIN" main

NODEFAULT="$WORK/repo-without-origin"
git init -q -b main "$NODEFAULT" && touch "$NODEFAULT/file"
run_case "a checkout without the default branch cannot be checked" 2 \
  env -C "$NODEFAULT" "$GUARD" on-branch refs/tags/v1.2.3 "$OFF_MAIN" main

# --- fixtures for the version check ----------------------------------------------
beam() { # beam <dir> <app vsn> <relx version>
  mkdir -p "$1/apps/mcl_thing/src"
  printf '{application, mcl_thing,\n [{vsn, "%s"},\n  {modules, []}]}.\n' "$2" \
    > "$1/apps/mcl_thing/src/mcl_thing.app.src"
  printf '{deps, []}.\n{relx, [{release, {mcl_thing, "%s"},\n         [mcl_thing]}]}.\n' "$3" \
    > "$1/rebar.config"
}

beam "$WORK/beam-ok" 0.6.1 0.6.1
run_case "a BEAM release whose app and relx agree passes" 0 \
  "$GUARD" versions refs/tags/v0.6.1 "$WORK/beam-ok"

beam "$WORK/beam-stale-relx" 0.6.1 0.4.2
run_case "a stale relx release version is refused" 1 \
  "$GUARD" versions refs/tags/v0.6.1 "$WORK/beam-stale-relx"

beam "$WORK/beam-stale-app" 0.6.0 0.6.1
run_case "an app vsn that disagrees with the tag is refused" 1 \
  "$GUARD" versions refs/tags/v0.6.1 "$WORK/beam-stale-app"

# The shape mcl-fovea v0.6.1 had: a release app beside a helper app at its own
# version. Only the app the release names is what a box reports, so the helper is not
# the guard's business.
beam "$WORK/beam-helper" 0.6.1 0.6.1
mkdir -p "$WORK/beam-helper/apps/observe_claims/src"
printf '{application, observe_claims, [{vsn, "0.1.0"}]}.\n' \
  > "$WORK/beam-helper/apps/observe_claims/src/observe_claims.app.src"
run_case "a helper app at its own version is not checked" 0 \
  "$GUARD" versions refs/tags/v0.6.1 "$WORK/beam-helper"
printf '{deps, []}.\n{relx, [{release, {mcl_thing, "0.4.2"},\n         [mcl_thing, sasl]}]}.\n' \
  > "$WORK/beam-helper/rebar.config"
run_case "a release naming an OTP app and a stale relx is refused" 1 \
  "$GUARD" versions refs/tags/v0.6.1 "$WORK/beam-helper"

mkdir -p "$WORK/beam-no-vsn/apps/x/src"
printf '{application, x, [{description, "no vsn"}]}.\n' > "$WORK/beam-no-vsn/apps/x/src/x.app.src"
run_case "an app.src that names no literal vsn is refused" 1 \
  "$GUARD" versions refs/tags/v1.0.0 "$WORK/beam-no-vsn"

mkdir -p "$WORK/beam-mix"
printf 'defmodule Thing.MixProject do\n  def project do\n    [app: :thing,\n     version: "0.2.0"]\n  end\nend\n' \
  > "$WORK/beam-mix/mix.exs"
run_case "a mix project whose version agrees passes" 0 \
  "$GUARD" versions refs/tags/v0.2.0 "$WORK/beam-mix"
run_case "a mix project whose version disagrees is refused" 1 \
  "$GUARD" versions refs/tags/v0.2.1 "$WORK/beam-mix"

# A library: rebar.config, no relx release, so the app's own vsn is what ships.
mkdir -p "$WORK/beam-library/src"
printf '{erl_opts, [debug_info]}.\n' > "$WORK/beam-library/rebar.config"
printf '{application, thing, [{vsn, "1.0.0"}]}.\n' > "$WORK/beam-library/src/thing.app.src"
run_case "a library with no relx release checks its app vsn" 0 \
  "$GUARD" versions refs/tags/v1.0.0 "$WORK/beam-library"
run_case "a library whose app vsn disagrees is refused" 1 \
  "$GUARD" versions refs/tags/v1.0.1 "$WORK/beam-library"

# A release tuple that is commented out is not the release this repository publishes.
mkdir -p "$WORK/beam-commented/src"
printf '{erl_opts, [debug_info]}.\n%% {relx, [{release, {thing, "0.4.2"}, [thing]}]}.\n' \
  > "$WORK/beam-commented/rebar.config"
printf '{application, thing, [{vsn, "1.0.0"}]}.\n' > "$WORK/beam-commented/src/thing.app.src"
run_case "a commented-out relx release is not read" 0 \
  "$GUARD" versions refs/tags/v1.0.0 "$WORK/beam-commented"

# relx builds the first release tuple when a config names several, so that is the one
# a box reports, and the second one's version is not what ships.
mkdir -p "$WORK/beam-two-releases/apps/mcl_thing/src"
printf '{application, mcl_thing, [{vsn, "0.6.1"}]}.\n' \
  > "$WORK/beam-two-releases/apps/mcl_thing/src/mcl_thing.app.src"
printf '{deps, []}.\n{relx, [{release, {mcl_thing, "0.6.1"}, [mcl_thing]},\n         {release, {mcl_thing_demo, "0.4.2"}, [mcl_thing]}]}.\n' \
  > "$WORK/beam-two-releases/rebar.config"
run_case "the first relx release is the one checked" 0 \
  "$GUARD" versions refs/tags/v0.6.1 "$WORK/beam-two-releases"

# An app the release names is found by name, not only at the two paths relx usually
# uses: a tree laid out another way passes its version check by being read, not by
# being missed.
mkdir -p "$WORK/beam-odd-layout/lib/mcl_thing/src"
printf '{application, mcl_thing, [{vsn, "0.6.0"}]}.\n' \
  > "$WORK/beam-odd-layout/lib/mcl_thing/src/mcl_thing.app.src"
printf '{deps, []}.\n{relx, [{release, {mcl_thing, "0.6.1"}, [mcl_thing]}]}.\n' \
  > "$WORK/beam-odd-layout/rebar.config"
run_case "a named app in another layout is still checked" 1 \
  "$GUARD" versions refs/tags/v0.6.1 "$WORK/beam-odd-layout"

# A relx release it will not spell out is refused, not treated as absent.
mkdir -p "$WORK/beam-unspelled/src"
printf '{erl_opts, []}.\n{relx, [{release, {thing, ?VSN}, [thing]}]}.\n' > "$WORK/beam-unspelled/rebar.config"
printf '{application, thing, [{vsn, "1.0.0"}]}.\n' > "$WORK/beam-unspelled/src/thing.app.src"
run_case "a relx release with no literal version is refused" 1 \
  "$GUARD" versions refs/tags/v1.0.0 "$WORK/beam-unspelled"

mkdir -p "$WORK/npm-ok"
printf '{\n  "name": "thing",\n  "version": "0.31.0",\n  "dependencies": {"dep": "1.0.0"}\n}\n' > "$WORK/npm-ok/package.json"
run_case "a package.json that agrees passes" 0 \
  "$GUARD" versions refs/tags/v0.31.0 "$WORK/npm-ok"
run_case "a package.json that disagrees is refused" 1 \
  "$GUARD" versions refs/tags/v0.31.1 "$WORK/npm-ok"

mkdir -p "$WORK/npm-prerelease"
printf '{\n  "version": "0.31.0-rc.6"\n}\n' > "$WORK/npm-prerelease/package.json"
run_case "a pre-release tag compares as the tag spells it" 0 \
  "$GUARD" versions refs/tags/v0.31.0-rc.6 "$WORK/npm-prerelease"

mkdir -p "$WORK/cargo"
printf '[package]\nname = "thing"\nversion = "1.4.0"\n\n[dependencies]\nserde = { version = "1" }\n' > "$WORK/cargo/Cargo.toml"
run_case "a Cargo package version that agrees passes" 0 \
  "$GUARD" versions refs/tags/v1.4.0 "$WORK/cargo"
run_case "a Cargo package version that disagrees is refused" 1 \
  "$GUARD" versions refs/tags/v1.4.1 "$WORK/cargo"

mkdir -p "$WORK/py"
printf '[project]\nname = "thing"\nversion = "2.0.0"\n' > "$WORK/py/pyproject.toml"
run_case "a pyproject version that agrees passes" 0 \
  "$GUARD" versions refs/tags/v2.0.0 "$WORK/py"

mkdir -p "$WORK/net"
printf '<Project>\n  <PropertyGroup>\n    <Version>3.1.0</Version>\n  </PropertyGroup>\n</Project>\n' > "$WORK/net/Thing.csproj"
run_case "a .csproj version that agrees passes" 0 \
  "$GUARD" versions refs/tags/v3.1.0 "$WORK/net"

mkdir -p "$WORK/nothing"
run_case "a release with no version source anywhere is refused" 1 \
  "$GUARD" versions refs/tags/v1.0.0 "$WORK/nothing"

run_case "a branch ref publishes no version and passes" 0 \
  "$GUARD" versions refs/heads/main "$WORK/beam-stale-relx"

mkdir -p "$WORK/unrelated-tag"
cp "$WORK/npm-ok/package.json" "$WORK/unrelated-tag/package.json"
run_case "a tag that is not v<version> publishes nothing and passes" 0 \
  "$GUARD" versions refs/tags/ip2asn-20261006T090019Z "$WORK/unrelated-tag"

printf '\n%s cases, %s failed\n' "$cases" "$failures"
[ "$failures" -eq 0 ]
