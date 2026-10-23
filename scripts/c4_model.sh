#!/usr/bin/env bash
# A C4 Context and a C4 Component diagram, in assets/, shown by a README, and a
# front page a reader can reach them from.
#
# Usage: c4_model.sh [ROOT]
#
# ROOT is a repository that builds an executable, which this does not decide:
# macula-codebase-checks' c4_model class does, from the repository itself, and
# holds the whole rule (macula-codebase-checks#10). This is the gate that keeps
# the two files there once the class has drawn them, so the next commit cannot
# drop a diagram or stop showing it.
#
# A diagram is a file in assets/ whose name holds `context` or `component` (the
# names are not fixed: mcl-fovea has c4-context.svg and c4-components.svg). It
# is shown when a README a reader reaches from the front page links it by file
# name: the root README.md, or the architecture/README.md a service keeps its
# whole model in.
#
# Two more readings, from macula-codebase-checks#26:
#
#   the model is REACHED      when the repository keeps an architecture/README.md,
#                             the front page README.md must link it. A model a
#                             reader landing on the repository cannot find is a
#                             diagram nobody reads.
#   one logo                  the README's header (everything above the first
#                             `## ` heading) carries at most one <picture> block.
#                             Two marks above the fold is a page that copied two
#                             templates.
#
# Exit 0 when all of it holds, 1 naming what is missing.
set -uo pipefail

ROOT="${1:-.}"
DOCS=(README.md architecture/README.md)
failed=0

shown() {
  local name="$1" doc
  for doc in "${DOCS[@]}"; do
    [ -f "$ROOT/$doc" ] || continue
    grep -qF "$name" "$ROOT/$doc" && return 0
  done
  return 1
}

# The model is reached from the front page: a markdown link TARGET that is the
# architecture README or its directory. The link text is free, and so is a
# `./`, a trailing `#anchor` or a `?query`.
if [ -f "$ROOT/architecture/README.md" ] \
   && ! grep -qE '\]\([[:space:]]*(\./)?architecture(/README\.md)?/?([#?][^)]*)?[[:space:]]*\)' \
        "$ROOT/README.md" 2>/dev/null; then
  echo "c4_model: README.md does not link architecture/README.md: a reader landing on" \
       "the repository cannot reach its C4 model" >&2
  failed=1
fi

# The header is what a visitor sees before the first section, and it carries one
# mark. A <picture> below the first `## ` heading is a screenshot, not a logo.
header="$(awk '/^## /{exit} {print}' "$ROOT/README.md" 2>/dev/null)"
pictures="$(grep -ci '<picture' <<< "$header" || true)"
pictures="${pictures:-0}"
if [ "$pictures" -gt 1 ]; then
  echo "c4_model: README.md shows ${pictures} <picture> blocks in its header: one logo," \
       "so the page carries a single mark above the fold" >&2
  failed=1
fi

for kind in context component; do
  svgs=()
  while IFS= read -r svg; do
    [ -n "$svg" ] && svgs+=("$svg")
  done < <(find "$ROOT/assets" -maxdepth 1 -iname "*${kind}*.svg" 2>/dev/null | sort)
  if [ "${#svgs[@]}" -eq 0 ]; then
    echo "c4_model: no assets/*${kind}*.svg: this repository builds an executable," \
         "and its C4 ${kind} diagram is what shows what it talks to and what it is made of" >&2
    failed=1
    continue
  fi
  # EVERY one, not the first: a second diagram nobody links is a diagram a
  # reader cannot reach, and the sweep's class asks for the same.
  for svg in "${svgs[@]}"; do
    name="$(basename "$svg")"
    if ! shown "$name"; then
      echo "c4_model: ${svg#"$ROOT"/} is not shown by ${DOCS[*]}: a diagram nobody links is not a model" >&2
      failed=1
    fi
  done
done


exit "$failed"
