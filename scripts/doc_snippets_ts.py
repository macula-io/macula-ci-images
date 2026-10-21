#!/usr/bin/env python3
"""Every TypeScript or JavaScript code block a package publishes type-checks
against its own code.

Usage: doc_snippets_ts.py ROOT

ROOT is an npm package (package.json at its root) whose dependencies are
installed (npm ci) and whose source is TypeScript. The docs read are the ones a
package publishes: README*.md and guides/**.md at any depth, and docs/**.md
without design records, plans, reports, backlogs or registers. The blocks read
are the ones fenced ts, typescript, tsx, js, javascript, mjs or jsx.

Each block is a module file of its own, as it stands (an ES module takes a
top-level await, and its imports and exports where the doc puts them), and tsc
reads them all with the package's own name mapped to its source, so the package
need not be built. JavaScript blocks are checked as JavaScript (checkJs), against the same
types. Each error names the doc and its own line.

What a block leaves to the reader is not an error: a name it uses and does not
declare (a realm, a stationId the prose has made), a name it declares twice by
listing alternatives, and a return with no function around it. Everything about the package is: an export, a property,
a method, an argument or a type it does not have, a module it cannot find, the
syntax. A property of a name the block does not declare cannot be checked: its
type is not known.

Markers, an HTML comment on the line before the fence:

  <!-- doc_snippets: skip <reason> -->   not checked; the reason is required

Exit 0 when every block type-checks, 1 when any fails (path:line: message), 2
when the check cannot run (no package.json, no tsc).
"""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

SKIP_DIRS = {".git", "node_modules", "_build", "deps", "target", "dist", ".venv", "build",
             "coverage"}
SHIPPED_DOCS = re.compile(
    r"^(?!(?:.*/)?(?:fixtures|testdata|vectors?)/)"
    r"(?!docs/(?:design|adr|adrs|decisions|plans?|reports?|research)/)"
    r"(?!docs/(?:.*/)?[^/]*(?:backlog|register)[^/]*$)"
    r"(?:(?:.*/)?README[^/]*\.md|(?:.*/)?guides/.+\.md|docs/.+\.md)$", re.I)
MARKER = re.compile(r"^\s*<!--\s*doc_snippets:\s*(\S+)\s*(.*?)\s*-->\s*$")
FENCE = re.compile(r"^(\s*)(`{3,}|~{3,})\s*([^`\s]*)")
LANGUAGES = {"ts": ".ts", "typescript": ".ts", "tsx": ".tsx",
             "js": ".js", "javascript": ".js", "mjs": ".js", "jsx": ".jsx"}
ERROR = re.compile(r"^(?P<file>[^()]+)\((?P<line>\d+),\d+\): error (?P<code>TS\d+): (?P<msg>.*)$")

# What only a block of a doc produces: a name the prose made, a name a block of
# alternatives declares twice.
FRAGMENT_ONLY = {
    "TS2304",  # Cannot find name 'x'.
    "TS2552",  # Cannot find name 'x'. Did you mean 'y'?
    "TS2451",  # Cannot redeclare block-scoped variable 'x'.
    "TS2300",  # Duplicate identifier 'x'.
    "TS18004",  # No value exists in scope for the shorthand property 'x'.
    "TS1108",  # A 'return' statement can only be used within a function body.
}


def docs(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS
                             and not d.startswith("_doc_snippets"))
        for name in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
            if SHIPPED_DOCS.search(rel):
                found.append(rel)
    return found


def blocks(text):
    """Every fenced block: (fence line, language word, marker, [(line, text)])."""
    lines, out, i, previous = text.split("\n"), [], 0, None
    while i < len(lines):
        opened = FENCE.match(lines[i])
        if not opened:
            if lines[i].strip():
                previous = lines[i]
            i += 1
            continue
        indent, fence = len(opened.group(1)), opened.group(2)
        word = opened.group(3).strip("{}.").split(",")[0].lower()
        mark = MARKER.match(previous) if previous else None
        start, body, i = i + 1, [], i + 1
        while i < len(lines):
            close = lines[i].strip()
            if close.startswith(fence[0] * len(fence)) and not close.strip(fence[0]):
                break
            line = lines[i]
            body.append((i + 1, line[indent:] if line[:indent].strip() == "" else line))
            i += 1
        out.append((start, word, (mark.group(1), mark.group(2)) if mark else None, body))
        previous, i = None, i + 1
    return out


def entry_of(root, manifest):
    """The source file the package's own name resolves to: the types entry's
    .ts twin under src/, src/index.ts, or the main entry."""
    candidates = []
    for field in ("types", "typings", "main", "module"):
        value = manifest.get(field)
        if isinstance(value, str):
            stem = re.sub(r"\.(d\.ts|js|mjs|cjs|ts)$", "", value)
            stem = re.sub(r"^\./?(dist|lib|build|out)/", "src/", stem)
            candidates += [stem + ".ts", stem + ".tsx"]
    candidates += ["src/index.ts", "index.ts"]
    for c in candidates:
        if (root / c).is_file():
            return "./" + c.lstrip("./")
    return None


def tsc_command(root):
    local = root / "node_modules" / ".bin" / "tsc"
    if local.exists():
        return [str(local)]
    found = shutil.which("tsc")
    return [found] if found else None


def main(argv):
    if len(argv) != 2:
        print("usage: doc_snippets_ts.py ROOT", file=sys.stderr)
        return 2
    root = Path(argv[1]).resolve()
    if not (root / "package.json").is_file():
        print(f"doc_snippets: no package.json in {root}", file=sys.stderr)
        return 2
    tsc = tsc_command(root)
    if not tsc:
        print("doc_snippets: no tsc (node_modules/.bin/tsc or on the PATH)", file=sys.stderr)
        return 2
    manifest = json.loads((root / "package.json").read_text())
    name, entry = manifest.get("name"), entry_of(root, manifest)

    failures, files = [], {}
    work = root / f"_doc_snippets_{os.getpid()}"
    work.mkdir()
    try:
        for doc in docs(root):
            for start, word, marker, body in blocks((root / doc).read_text(errors="replace")):
                if word not in LANGUAGES:
                    continue
                if marker and marker[0] == "skip":
                    if not marker[1]:
                        failures.append((doc, start, "skip gives no reason"))
                    continue
                if marker:
                    failures.append((doc, start, f"unknown marker '{marker[0]}'"))
                    continue
                if not any(t.strip() and not t.strip().startswith("//") for _, t in body):
                    continue
                # The block is a module file as it stands: an ES module takes a
                # top-level await, an import and an export where the doc put
                # them. `export {}` makes it a module when it names no import.
                rows = [(n, t) for n, t in body] + [(None, "export {};")]
                filename = f"snippet_{len(files)}{LANGUAGES[word]}"
                (work / filename).write_text("".join(t + "\n" for _, t in rows))
                files[filename] = (doc, [n for n, _ in rows])
        if files:
            # Paths are relative to the tsconfig's own directory (no baseUrl:
            # TypeScript 6 removed it).
            paths = {name: ["./" + os.path.relpath(root / entry, work)],
                     f"{name}/*": ["./" + os.path.relpath(root / "src", work) + "/*"]} \
                if name and entry else {}
            types = ["node"] if (root / "node_modules" / "@types" / "node").is_dir() else []
            (work / "tsconfig.json").write_text(json.dumps({
                "compilerOptions": {
                    "target": "ES2022", "module": "ESNext", "moduleResolution": "Bundler",
                    "lib": ["ES2022", "DOM"], "types": types, "noEmit": True,
                    "skipLibCheck": True, "esModuleInterop": True, "allowJs": True,
                    "checkJs": True, "jsx": "preserve", "strict": False,
                    "paths": paths,
                },
                "files": sorted(files),
            }, indent=2))
            out = subprocess.run(tsc + ["-p", str(work / "tsconfig.json"), "--pretty", "false"],
                                 cwd=root, capture_output=True, text=True)
            foreign = []
            for line in (out.stdout + out.stderr).splitlines():
                error = ERROR.match(line.strip())
                if not error:
                    continue
                if os.path.basename(error.group("file")) not in files:
                    # An error in the generated tsconfig or in the package's own
                    # source means the blocks were not read: never a clean run.
                    foreign.append(line.strip())
                    continue
                doc, where = files[os.path.basename(error.group("file"))]
                at = int(error.group("line")) - 1
                doc_line = where[at] if 0 <= at < len(where) else None
                if doc_line is None or error.group("code") in FRAGMENT_ONLY:
                    continue
                failures.append((doc, doc_line, f"{error.group('code')}: {error.group('msg')}"))
            if foreign or out.returncode not in (0, 1, 2) or (out.returncode and not any(
                    ERROR.match(l.strip()) for l in (out.stdout + out.stderr).splitlines())):
                print(f"doc_snippets: tsc could not run: {(out.stdout + out.stderr).strip()}",
                      file=sys.stderr)
                return 2
    finally:
        shutil.rmtree(work, ignore_errors=True)

    for path, line, message in sorted(set(failures)):
        print(f"{path}:{line}: {message}")
    print(f"doc_snippets: {len(set(failures))} failure(s) in {len(files)} block(s)", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
