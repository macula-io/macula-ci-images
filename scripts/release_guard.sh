#!/usr/bin/env bash
# Refuse a release that must not happen. Two checks, both only for a v* tag, so a
# repository that builds on every main push keeps building:
#
#   on-branch <ref> <sha> <default-branch>
#       the tagged commit is an ancestor of origin/<default-branch>, so a release can
#       never again sit on a side branch while the default branch is behind it
#       (mcl_om 1.0.0, tagged on wire1-macula15, two commits ahead of main);
#
#   versions <ref> [root]
#       the tag's version is the version the repository will publish: every .app.src
#       vsn, the relx release version and mix.exs (BEAM), or the manifest the release
#       publishes (Cargo.toml, package.json, pyproject.toml, *.csproj). A box that
#       reports its release reads these, so a stale one publishes a lie (mcl-fovea
#       0.6.1 reporting 0.4.2).
#
# A ref that is not a tag named v<version> is not a release: both checks print that
# and exit 0. A release-only workflow that must refuse anything else asks for it with
# the workflow's `require-tag' input, not here.
#
# Exit: 0 pass, 1 refused, 2 the check could not be made.
#
# The version is compared as the tag spells it minus the leading v, so a pre-release
# tag v0.31.0-rc.6 matches an app version of 0.31.0-rc.6 and nothing else.
set -uo pipefail

prog="$(basename "$0")"
usage() {
  echo "usage: $prog on-branch <ref> <sha> <default-branch>" >&2
  echo "       $prog versions <ref> [root]" >&2
  exit 2
}

# The version a ref names, or non-zero when the ref is not a release tag.
tag_version() {
  local ref="$1"
  case "$ref" in
    refs/tags/v*) printf '%s\n' "${ref#refs/tags/v}" ;;
    *) return 1 ;;
  esac
}

# The value after the last "=" or ":"-style separator on a matched pattern, used by
# the manifest readers below so each one stays a single sed or awk expression.
first_line() { head -1; }

# Every version source found, one "file<TAB>source<TAB>version" line each. A source
# that exists but names no literal version is printed with an empty version, so the
# check refuses it instead of silently passing.
read_versions() {
  local root="$1" beam=0 f v relx_version="" relx_apps="" flat rest app

  if [ -f "$root/rebar.config" ]; then
    beam=1
    # One line, so a release tuple spread over several lines still reads whole, and
    # with the Erlang comments gone, so a tuple that was commented out is not read as
    # the release this repository publishes. `%' runs to the end of its line, so the
    # lines are stripped before they are joined.
    flat="$(sed 's/%.*//' "$root/rebar.config" | tr '\n' ' ')"
    # {relx, [{release, {name, "x.y.z"}, [app1, app2]}, ...]}: the FIRST tuple, which
    # is the one relx builds when the config names several.
    rest="${flat#*'{release,'}"
    relx_version="$(printf '%s' "$rest" | sed -n 's/^[[:space:]]*{[^,}]*,*[[:space:]]*"\([^"]*\)".*/\1/p')"
    relx_apps="$(printf '%s' "$rest" | sed -n 's/^[[:space:]]*{[^,}]*,*[[:space:]]*"[^"]*"[[:space:]]*}[[:space:]]*,[[:space:]]*\[\([^]]*\)\].*/\1/p')"
    # A library has no relx release and publishes its app's own vsn; a rebar.config
    # that names a release it will not spell as a literal is refused rather than
    # treated as absent.
    if [ -n "$relx_version" ] || printf '%s' "$flat" | grep -q '{release,'; then
      printf '%s\trelx release\t%s\n' rebar.config "$relx_version"
    fi
  fi

  # The apps the release names, when it names any: an umbrella app beside the release
  # (a helper at 0.1.0) is not what a box reports, and is not checked. Apps the relay
  # names that this tree does not hold (sasl, kernel) are OTP's and are skipped. The
  # file is found by name rather than at the two paths relx usually uses, so an app in
  # a tree laid out another way is still checked instead of quietly passing.
  if [ -n "$relx_apps" ]; then
    for app in $(printf '%s' "$relx_apps" | tr ',' ' '); do
      [ "$app" = "" ] && continue
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        v="$(sed -n 's/.*{vsn,[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | first_line)"
        printf '%s\tapp.src vsn\t%s\n' "${f#"$root"/}" "$v"
      done < <(find "$root" -name "$app.app.src" \
                 -not -path '*/.git/*' -not -path '*/_build/*' \
                 -not -path '*/deps/*' -not -path '*/_checkouts/*' \
                 -not -path '*/node_modules/*' | sort)
    done
  else
    while IFS= read -r f; do
      beam=1
      v="$(sed -n 's/.*{vsn,[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | first_line)"
      printf '%s\tapp.src vsn\t%s\n' "${f#"$root"/}" "$v"
    done < <(find "$root" -name '*.app.src' \
               -not -path '*/.git/*' -not -path '*/_build/*' \
               -not -path '*/deps/*' -not -path '*/_checkouts/*' -not -path '*/node_modules/*' | sort)
  fi

  if [ -f "$root/mix.exs" ]; then
    beam=1
    v="$(awk '/def project/ { seen = 1 }
              seen && match($0, /version:[[:space:]]*"[^"]*"/) {
                s = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", s); sub(/"$/, "", s)
                print s; exit }' "$root/mix.exs")"
    printf '%s\tmix project version\t%s\n' mix.exs "$v"
  fi

  # Other stacks only when the tree is not a BEAM release: a docs site's package.json
  # in a BEAM repository is not what the release publishes.
  if [ "$beam" -eq 0 ]; then
    if [ -f "$root/Cargo.toml" ]; then
      v="$(awk '/^\[package\]/ { p = 1 } p && /^[[:space:]]*version[[:space:]]*=/ {
                s = $0; sub(/^[^"]*"/, "", s); sub(/".*/, "", s); print s; exit }' "$root/Cargo.toml")"
      printf '%s\tpackage version\t%s\n' Cargo.toml "$v"
    fi
    if [ -f "$root/package.json" ]; then
      v="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$root/package.json" | first_line)"
      printf '%s\tpackage version\t%s\n' package.json "$v"
    fi
    if [ -f "$root/pyproject.toml" ]; then
      v="$(awk '/^[[:space:]]*version[[:space:]]*=/ {
                s = $0; sub(/^[^"]*"/, "", s); sub(/".*/, "", s); print s; exit }' "$root/pyproject.toml")"
      printf '%s\tproject version\t%s\n' pyproject.toml "$v"
    fi
    while IFS= read -r f; do
      v="$(sed -n 's/.*<Version>[[:space:]]*\([^<]*\)<.*/\1/p' "$f" | first_line)"
      printf '%s\tassembly version\t%s\n' "${f#"$root"/}" "$v"
    done < <(find "$root" -name '*.csproj' -not -path '*/.git/*' -not -path '*/bin/*' -not -path '*/obj/*' | sort)
  fi
}

check_on_branch() {
  local ref="$1" sha="$2" default="$3" version default_ref

  if ! version="$(tag_version "$ref")"; then
    echo "release guard: $ref is not a release tag, so the commit may be anywhere"
    return 0
  fi

  # The full ref, never the short origin/<default>. Git looks for refs/tags/<name>
  # before refs/remotes/<name>, and a checkout with fetch-depth: 0 brings every tag, so
  # a tag pushed as origin/main would be read as the default branch: the commit would
  # then be an ancestor of itself, the guard would print ok, and the release would be
  # signed. Naming the remote-tracking ref in full leaves nothing to shadow it: neither
  # refs/tags nor refs/heads is consulted for a name that starts with refs/.
  default_ref="refs/remotes/origin/$default"

  if ! git rev-parse --verify --quiet "$default_ref^{commit}" > /dev/null; then
    echo "release guard: origin/$default is not in this checkout; fetch the default" >&2
    echo "release guard: branch with fetch-depth: 0 before calling the guard" >&2
    return 2
  fi

  if git merge-base --is-ancestor "$sha" "$default_ref"; then
    echo "release guard: ok, $sha is on origin/$default (tag v$version)"
    return 0
  fi

  echo "release guard: REFUSED, tag v$version names $sha, which is not an ancestor of"
  echo "release guard: origin/$default. A release built from a side branch leaves the"
  echo "release to be cut again from the default branch:"
  git log --oneline "$default_ref..$sha" | sed 's/^/release guard:   only on the tag: /'
  printf '%s is not on origin/%s\n' "${sha:0:12}" "$default"
  return 1
}

check_versions() {
  local ref="$1" root="${2:-.}" version lines found=0 bad=0 file source found_version

  if ! version="$(tag_version "$ref")"; then
    echo "release guard: $ref is not a release tag, so no version is published"
    return 0
  fi

  lines="$(read_versions "$root")"
  if [ -z "$lines" ]; then
    echo "release guard: REFUSED, v$version names a release but $root holds no version" >&2
    echo "release guard: (no .app.src, rebar.config relx, mix.exs, Cargo.toml," >&2
    echo "release guard: package.json, pyproject.toml or *.csproj)" >&2
    return 1
  fi

  while IFS=$'\t' read -r file source found_version; do
    found=$((found + 1))
    if [ -z "$found_version" ]; then
      echo "release guard: FAIL $file names no literal $source"
      bad=$((bad + 1))
    elif [ "$found_version" = "$version" ]; then
      echo "release guard: ok   $file $source $found_version"
    else
      echo "release guard: FAIL $file $source $found_version, tag says $version"
      bad=$((bad + 1))
    fi
  done <<< "$lines"

  if [ "$bad" -ne 0 ]; then
    printf 'v%s disagrees with %s of %s version sources\n' "$version" "$bad" "$found"
    return 1
  fi
  echo "release guard: ok, v$version is what all $found version sources publish"
  return 0
}

case "${1:-}" in
  on-branch) shift; [ $# -eq 3 ] || usage; check_on_branch "$@" ;;
  versions)  shift; [ $# -ge 1 ] && [ $# -le 2 ] || usage; check_versions "$@" ;;
  *) usage ;;
esac
