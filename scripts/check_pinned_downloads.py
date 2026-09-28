#!/usr/bin/env python3
"""Is every file a Containerfile downloads verified against a pinned checksum?

A base image is only as trustworthy as what goes into it. apt packages are
verified by Debian's signatures, and the base images are pinned by date (and
stamped by digest). Anything else fetched over the network must be checked
against a checksum written in this repository, so a release or a compromise
upstream cannot change an image without a commit here. rustup's installer was
piped straight into sh, unpinned and unchecked, until this check existed.

For every RUN instruction (continuation lines joined):
  - a download piped into a shell (curl ... | sh, wget ... | bash) is REFUSED;
  - a download must write to a file (curl -o FILE / --output FILE,
    wget -O FILE / --output-document FILE), and that same RUN must check
    FILE with
    `sha256sum -c` or `sha512sum -c`; otherwise REFUSED.

Exit 0 when every download is verified; otherwise name each unverified one
(file and line) and exit 1.

Usage: scripts/check_pinned_downloads.py [Containerfile ...]
  (default: every Containerfile.* in the current directory)
"""
import glob
import re
import shlex
import sys

FETCHERS = {"curl", "wget"}
SHELLS = {"sh", "bash", "dash", "zsh"}
CHECKERS = ("sha256sum", "sha512sum")


def run_instructions(path):
    """Yield (first_line_number, joined_text) for every RUN instruction."""
    lines = open(path).read().splitlines()
    i = 0
    while i < len(lines):
        if re.match(r"^\s*RUN\s", lines[i]):
            start, parts = i + 1, [lines[i]]
            while parts[-1].rstrip().endswith("\\") and i + 1 < len(lines):
                i += 1
                parts.append(lines[i])
            text = " ".join(p.rstrip().rstrip("\\") for p in parts)
            yield start, re.sub(r"^\s*RUN\s+", "", text)
        i += 1


def commands(text):
    """Split a shell line into pipelines of simple commands (as word lists).

    Tokenised as a shell would, quotes first, so a | or && inside a quoted
    string is never taken for an operator."""
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    pipelines, stages, words = [], [], []
    for tok in lexer:
        if tok in ("&&", "||", ";", "&"):
            stages.append(words)
            pipelines.append([s for s in stages if s])
            stages, words = [], []
        elif tok == "|":
            stages.append(words)
            words = []
        elif set(tok) <= set("()<>|&;"):
            continue
        else:
            words.append(tok)
    stages.append(words)
    pipelines.append([s for s in stages if s])
    return [p for p in pipelines if p]


# The flag that names the downloaded file, per fetcher (wget's -o is its log).
OUTPUT_FLAGS = {"curl": ("-o", "--output"), "wget": ("-O", "--output-document")}


def output_file(words):
    flags = OUTPUT_FLAGS[words[0]]
    for flag in flags:
        if flag in words[:-1]:
            return words[words.index(flag) + 1]
    for w in words:
        for flag in flags:
            if flag.startswith("--") and w.startswith(flag + "="):
                return w.split("=", 1)[1]
    return None


def checked_files(text):
    """Files a sha*sum -c in this RUN verifies: `echo "SUM  FILE" | shaNsum -c -`."""
    files = set()
    for m in re.finditer(r'echo\s+"[^"]*?\s+([^"\s]+)"\s*\|\s*sha(?:256|512)sum\s+-c', text):
        files.add(m.group(1))
    return files


def problems_in(path):
    found = []
    for line, text in run_instructions(path):
        try:
            pipelines = commands(text)
        except ValueError as exc:
            found.append(f"{path}:{line}: cannot parse RUN ({exc}); refuse rather than guess")
            continue
        verified = checked_files(text)
        for pipeline in pipelines:
            for n, words in enumerate(pipeline):
                if words[0] not in FETCHERS:
                    continue
                later = [w[0] for w in pipeline[n + 1:]]
                if any(s in SHELLS for s in later):
                    found.append(f"{path}:{line}: {words[0]} piped into a shell (download it, check a pinned sha256, then run it)")
                    continue
                target = output_file(words)
                if target is None:
                    found.append(f"{path}:{line}: {words[0]} without {OUTPUT_FLAGS[words[0]][0]} FILE, so nothing can be checked")
                elif target not in verified:
                    found.append(f"{path}:{line}: {target} is downloaded but not checked with sha256sum/sha512sum -c in the same RUN")
    return found


def main():
    paths = sys.argv[1:] or sorted(glob.glob("Containerfile.*"))
    if not paths:
        print("REFUSED: no Containerfile to check")
        sys.exit(1)
    found = [p for path in paths for p in problems_in(path)]
    if found:
        print("REFUSED: downloads that no pinned checksum verifies")
        for p in found:
            print(f"  {p}")
        sys.exit(1)
    print(f"OK: every download in {len(paths)} Containerfiles is checked against a pinned checksum")


if __name__ == "__main__":
    main()
