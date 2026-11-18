#!/usr/bin/env python3
"""The wall-to-tree check: a Division's tree holds exactly the folders its wall
asks for.

Usage: wall_tree.py --root ROOT --corpus CORPUS

ROOT is the Division's repository (the checkout a caller's pipeline runs on);
CORPUS is an mcl-corpus checkout at a pinned sha, whose assets/folders_from_wall.py
holds the rule and assets/check_wall_schema.py the schema's reader. Neither is
restated here: this script imports both.

First it holds wall.json to wall_schema.json, refusing by JSON path anything
that is not a name (a pipeline, a field type, a status flag — Demon 75). Then
it maps the wall to the folders its three applications must have, lists the
folders they actually have under apps/{host,project,query}_<division>/src/, and
fails naming every note whose folder is missing and every folder no note asks
for. Hot spots and clock notes never need a folder, because the rule gives them
none.

Exit 0 when the wall and the tree agree, 1 naming what does not.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys


def _app_srcs(root: pathlib.Path, division: str) -> dict[str, pathlib.Path]:
    return {
        "cmd": root / "apps" / f"host_{division}" / "src",
        "prj": root / "apps" / f"project_{division}" / "src",
        "qry": root / "apps" / f"query_{division}" / "src",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--corpus", required=True)
    args = parser.parse_args()

    root = pathlib.Path(args.root)
    corpus = pathlib.Path(args.corpus)
    sys.path.insert(0, str(corpus / "assets"))

    from check_wall_schema import check_wall_schema  # noqa: E402
    from folders_from_wall import folders_from_wall  # noqa: E402

    wall_path = root / "wall.json"
    if not wall_path.is_file():
        print("wall_tree: no wall.json at the repository root", file=sys.stderr)
        return 1

    try:
        wall = json.loads(wall_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"wall_tree: wall.json is not valid JSON: {exc}", file=sys.stderr)
        return 1

    # The wall holds names only (mcl-whiteboard#14, Demon 75): the schema's
    # reader refuses anything else, by JSON path, before the rule runs.
    refusals = check_wall_schema(wall)
    if refusals:
        for refusal in refusals:
            print(f"wall_tree: {refusal}", file=sys.stderr)
        return 1

    try:
        expected = folders_from_wall(wall)
    except ValueError as exc:
        print(f"wall_tree: {exc}", file=sys.stderr)
        return 1

    division = wall["division"]
    failures: list[str] = []
    for app, src in _app_srcs(root, division).items():
        actual = {p.name for p in src.iterdir() if p.is_dir()} if src.is_dir() else set()
        want = set(expected[app])
        for folder in sorted(want - actual):
            failures.append(f"{src.relative_to(root)}/{folder}: a note asks for this folder and it is missing")
        for folder in sorted(actual - want):
            failures.append(f"{src.relative_to(root)}/{folder}: a folder no note asks for")

    if failures:
        for failure in failures:
            print(f"wall_tree: {failure}", file=sys.stderr)
        return 1
    print("wall_tree: the wall and the tree agree")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
