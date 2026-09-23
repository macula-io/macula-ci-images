#!/usr/bin/env python3
"""Print the newest dated Debian base published for a Containerfile's pinned toolchain.

This exists so a base image actually carries current Debian security updates.
The Containerfiles pin every tool (OTP, Elixir, rebar3, Rust) exactly, but the
Debian snapshot underneath has to move, or the image rots: it did, silently,
while a daily "rebuild" reproduced the same layers from cache.

Reads the Containerfile's FROM template and its ARG defaults, substitutes every
ARG except DEBIAN_VERSION, and asks Docker Hub for the newest tag matching the
template with DEBIAN_VERSION = <distro>-YYYYMMDD-slim, where <distro> comes from
the Containerfile's own DEBIAN_VERSION default (e.g. trixie).

Prints the DEBIAN_VERSION value to build with (e.g. trixie-20260918-slim).
Exits non-zero, naming what it looked for, when nothing matches: a base that
cannot be resolved must stop the build, never fall back to the old one quietly.

Usage: scripts/newest_dated_base.py Containerfile.ci-otp
"""
import json
import re
import sys
import urllib.parse
import urllib.request

ARG_RE = re.compile(r'^ARG\s+([A-Z0-9_]+)=(\S+)\s*$', re.M)
FROM_RE = re.compile(r'^FROM\s+(\S+)', re.M)


def fail(msg):
    print(f"REFUSED: {msg}", file=sys.stderr)
    sys.exit(1)


def template(containerfile):
    text = open(containerfile).read()
    args = dict(ARG_RE.findall(text))
    froms = FROM_RE.findall(text)
    if len(froms) != 1:
        fail(f"{containerfile}: expected exactly one FROM, found {len(froms)}")
    if 'DEBIAN_VERSION' not in args:
        fail(f"{containerfile}: no ARG DEBIAN_VERSION=<default> to take the distro from")
    distro = args['DEBIAN_VERSION'].split('-')[0]
    ref = froms[0]
    for name, value in args.items():
        if name != 'DEBIAN_VERSION':
            ref = ref.replace('${' + name + '}', value)
    ref = re.sub(r'^docker\.io/', '', ref)
    repo, tag_template = ref.split(':', 1)
    if '/' not in repo:
        repo = 'library/' + repo
    if tag_template.count('${DEBIAN_VERSION}') != 1 or '${' in tag_template.replace('${DEBIAN_VERSION}', ''):
        fail(f"{containerfile}: FROM tag {tag_template!r} must contain ${{DEBIAN_VERSION}} once and no other unresolved ARG")
    prefix, suffix = tag_template.split('${DEBIAN_VERSION}')
    return repo, prefix, suffix, distro


def hub_tags(repo, name_filter):
    url = (f"https://hub.docker.com/v2/repositories/{repo}/tags"
           f"?page_size=100&name={urllib.parse.quote(name_filter)}")
    while url:
        with urllib.request.urlopen(url, timeout=30) as resp:
            page = json.load(resp)
        for result in page.get('results', []):
            yield result['name']
        url = page.get('next')


def main():
    if len(sys.argv) != 2:
        fail("usage: newest_dated_base.py <Containerfile>")
    repo, prefix, suffix, distro = template(sys.argv[1])
    want = re.compile(re.escape(prefix) + '(' + re.escape(distro) + r'-(\d{8})-slim)' + re.escape(suffix) + '$')
    found = []
    for tag in hub_tags(repo, prefix + distro + '-'):
        m = want.match(tag)
        if m:
            found.append((m.group(2), m.group(1)))
    if not found:
        fail(f"no {repo}:{prefix}{distro}-YYYYMMDD-slim{suffix} tag on Docker Hub")
    print(max(found)[1])


if __name__ == '__main__':
    main()
