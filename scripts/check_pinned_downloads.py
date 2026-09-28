#!/usr/bin/env python3
"""Is every file a Containerfile downloads verified against a pinned checksum?

A base image is only as trustworthy as what goes into it. apt packages are
verified by Debian's signatures, and the base images are pinned by digest.
Anything else fetched over the network must be checked against a checksum
written in this repository, so a release or a compromise upstream cannot change
an image without a commit here. rustup's installer was piped straight into sh,
unpinned and unchecked, until this check existed.

For every RUN instruction (continuation lines joined, tokenised as a shell
would, and the string of every `sh -c` / `bash -c` checked the same way):

  - curl or wget (by basename, so /usr/bin/curl counts) anywhere in a RUN
    makes it a downloading RUN, and must be the first word of its command:
    `env curl`, `timeout 60 wget`, `bash < <(curl ...)` are REFUSED;
  - a download (curl, wget) piped into anything is REFUSED;
  - a download inside a command substitution ($(...) or backticks) is REFUSED;
  - a download must write to a file (curl -o/--output, wget -O/--output-document);
  - the command right after it, joined by &&, must be exactly
        echo "SUM  FILE" | sha256sum -c -     (or sha512sum)
    for that FILE, where SUM is a literal hex digest of the right length or a
    bare ${ARG} declared with a default in the Containerfile (ARG NAME=value),
    so it is pinned there: nothing may run the file first, and the sum cannot
    be fetched;
  - a RUN that downloads is one && chain: no ||, ;, & or ( ), so a failed
    check always fails the build and can never be skipped or ignored.

Exit 0 when every download is verified; otherwise name each unverified one
(file and line) and exit 1.

Usage: scripts/check_pinned_downloads.py [Containerfile ...]
  (default: every Containerfile.* in the current directory)
"""
import glob
import os
import re
import shlex
import sys

FETCHERS = {"curl", "wget"}
SHELLS = {"sh", "bash", "dash", "zsh"}
# The flag that names the downloaded file, per fetcher (wget's -o is its log).
OUTPUT_FLAGS = {"curl": ("-o", "--output"), "wget": ("-O", "--output-document")}
DIGEST_LEN = {"sha256sum": 64, "sha512sum": 128}
ARG_REF = re.compile(r"^\$\{[A-Za-z_][A-Za-z0-9_]*\}$")
OPERATORS = {"&&", "||", ";", "&", "|"}
FORBIDDEN_IN_DOWNLOAD_RUN = {"||", ";", "&", "(", ")"}
# Commands whose arguments name packages, not fetches: `apt-get install curl`
# installs curl, Debian's signatures cover what it downloads.
PACKAGE_MANAGERS = {"apt-get", "apt"}


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


def tokens(text):
    """Shell tokens, quotes first, so a | or && inside quotes is a word."""
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def chain(toks):
    """Split tokens into [(pipeline, operator_after)], a pipeline being a list
    of commands (word lists) joined by |. Parentheses are kept as words so the
    caller can refuse them."""
    out, pipeline, words = [], [], []
    for tok in toks:
        if tok == "|":
            pipeline.append(words)
            words = []
        elif tok in OPERATORS:
            pipeline.append(words)
            out.append(([c for c in pipeline if c], tok))
            pipeline, words = [], []
        else:
            words.append(tok)
    pipeline.append(words)
    out.append(([c for c in pipeline if c], None))
    return [(p, op) for p, op in out if p]


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


def fetcher(word):
    """curl or wget, however it is spelled (a full path counts)."""
    base = os.path.basename(word)
    return base if base in FETCHERS else None


def pinned_args(path):
    """ARG names declared with a default: the values pinned in this file."""
    return set(re.findall(r'^\s*ARG\s+([A-Za-z_][A-Za-z0-9_]*)=\S', open(path).read(), re.M))


def is_check_of(pipeline, target, pinned):
    """Is this pipeline exactly `echo "SUM  target" | shaNsum -c -` with a pinned SUM?"""
    if not any(c[0] in DIGEST_LEN for c in pipeline):
        return False, f"{target} is downloaded but not checked by the next command (the command after the download is not sha256sum/sha512sum -c)"
    if len(pipeline) != 2:
        return False, "the check must be exactly: echo \"SUM  FILE\" | sha256sum -c -"
    echo, checker = pipeline
    if checker[0] not in DIGEST_LEN or "-c" not in checker[1:]:
        return False, "the check must be exactly: echo \"SUM  FILE\" | sha256sum -c -"
    if echo[0] != "echo" or len(echo) != 2:
        return False, "the check must read its line from a single echo \"SUM  FILE\""
    parts = echo[1].strip().rsplit(None, 1)
    if len(parts) != 2 or parts[1] != target:
        return False, f"the check does not name {target}"
    digest = parts[0]
    literal = re.fullmatch(r"[0-9a-f]{%d}" % DIGEST_LEN[checker[0]], digest)
    if not (literal or ARG_REF.match(digest)):
        return False, f"the sum '{digest}' is not pinned (a literal {DIGEST_LEN[checker[0]]}-hex digest or a bare ${{ARG}})"
    if not literal and digest[2:-1] not in pinned:
        return False, f"the sum {digest} names no ARG declared with a default in this Containerfile"
    return True, ""


def problems_in_text(path, line, text, found, pinned):
    try:
        toks = tokens(text)
    except ValueError as exc:
        found.append(f"{path}:{line}: cannot parse RUN ({exc}); refuse rather than guess")
        return
    for tok in toks:
        if any(f in tok for f in FETCHERS) and ("$(" in tok or "`" in tok):
            found.append(f"{path}:{line}: a download inside a command substitution")
    links = chain(toks)
    downloads = any(
        fetcher(w)
        for pipeline, _op in links
        for words in pipeline
        if os.path.basename(words[0]) not in PACKAGE_MANAGERS
        for w in words
    )
    for n, (pipeline, op) in enumerate(links):
        for words in pipeline:
            if os.path.basename(words[0]) in PACKAGE_MANAGERS:
                continue
            if os.path.basename(words[0]) in SHELLS and "-c" in words[:-1]:
                problems_in_text(path, line, words[words.index("-c") + 1], found, pinned)
            for w in words[1:]:
                if fetcher(w):
                    found.append(f"{path}:{line}: {w} is a download not at the head of its command (a wrapper, a path argument or a process substitution)")
        first = pipeline[0]
        if not any(fetcher(c[0]) for c in pipeline):
            continue
        if not fetcher(first[0]) or len(pipeline) > 1:
            found.append(f"{path}:{line}: {'/'.join(sorted({fetcher(c[0]) for c in pipeline if fetcher(c[0])}))} piped into another command (download it to a file, check a pinned sha256, then use it)")
            continue
        name = fetcher(first[0])
        target = output_file([name] + first[1:])
        if target is None:
            found.append(f"{path}:{line}: {name} without {OUTPUT_FLAGS[name][0]} FILE, so nothing can be checked")
            continue
        if op != "&&" or n + 1 >= len(links):
            found.append(f"{path}:{line}: {target} is downloaded but not checked by the next command in an && chain")
            continue
        ok, why = is_check_of(links[n + 1][0], target, pinned)
        if not ok:
            found.append(f"{path}:{line}: {target}: {why}")
    if downloads:
        bad = sorted({t for t in toks if t in FORBIDDEN_IN_DOWNLOAD_RUN})
        if bad:
            found.append(f"{path}:{line}: a RUN that downloads must be one && chain; it uses {' '.join(bad)}, which can skip or ignore a failed check")


def problems_in(path):
    found = []
    pinned = pinned_args(path)
    for line, text in run_instructions(path):
        problems_in_text(path, line, text, found, pinned)
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
