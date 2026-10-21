#!/usr/bin/env bash
# A C4 Context and a C4 Component diagram, in assets/, shown by a README.
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
# Exit 0 when both are there and shown, 1 naming what is missing.
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

for kind in context component; do
  svg="$(find "$ROOT/assets" -maxdepth 1 -iname "*${kind}*.svg" -print -quit 2>/dev/null)"
  if [ -z "$svg" ]; then
    echo "c4_model: no assets/*${kind}*.svg: this repository builds an executable," \
         "and its C4 ${kind} diagram is what shows what it talks to and what it is made of" >&2
    failed=1
    continue
  fi
  name="$(basename "$svg")"
  if ! shown "$name"; then
    echo "c4_model: ${svg#"$ROOT"/} is not shown by ${DOCS[*]}: a diagram nobody links is not a model" >&2
    failed=1
  fi
done

exit "$failed"
