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
With --pinned it prints three space-separated fields instead: that value, the
FROM reference it gives (every ARG substituted), and the same reference pinned
to the digest Docker Hub reports for that tag (ref:tag@sha256:...). The build
uses the pinned one as the FROM image and stamps it on the image, so what an
image was built on is exact, not just a tag that could be pushed again. A tag
without a digest is refused.
Exits non-zero, naming what it looked for, when nothing matches: a base that
cannot be resolved must stop the build, never fall back to the old one quietly.

Docker Hub is asked with bounded retries: a timeout, a dropped connection, a
429, a 5xx or a body cut off mid-read is retried with backoff, up to
NEWEST_BASE_ATTEMPTS (5) attempts; after the last one the build fails, naming
the URL and the last error. A 4xx other than 429 is Docker Hub's answer, not a
hiccup, and fails at once. One read timeout, with no retry, failed the daily
build on 2026-09-26.

Usage: scripts/newest_dated_base.py [--pinned] Containerfile.ci-otp
  NEWEST_BASE_ATTEMPTS=5 NEWEST_BASE_BACKOFF=2 (seconds, doubling)
  NEWEST_BASE_TIMEOUT=30 (seconds per attempt)
  NEWEST_BASE_HUB=https://hub.docker.com (the tests point it at a fake)
"""
import http.client
import json
import math
import os
import re
import sys
import time
import urllib.error
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
    from_template = ref
    ref = re.sub(r'^docker\.io/', '', ref)
    repo, tag_template = ref.split(':', 1)
    if '/' not in repo:
        repo = 'library/' + repo
    if tag_template.count('${DEBIAN_VERSION}') != 1 or '${' in tag_template.replace('${DEBIAN_VERSION}', ''):
        fail(f"{containerfile}: FROM tag {tag_template!r} must contain ${{DEBIAN_VERSION}} once and no other unresolved ARG")
    prefix, suffix = tag_template.split('${DEBIAN_VERSION}')
    return repo, prefix, suffix, distro, from_template


def setting(name, default, kind):
    raw = os.environ.get(name, default)
    try:
        value = kind(raw)
    except ValueError:
        value = None
    if value is None or not math.isfinite(value) or value <= 0:
        fail(f"{name}={raw!r} is not a positive {kind.__name__}")
    return value


def fetch_json(url):
    attempts = setting('NEWEST_BASE_ATTEMPTS', '5', int)
    backoff = setting('NEWEST_BASE_BACKOFF', '2', float)
    timeout = setting('NEWEST_BASE_TIMEOUT', '30', float)
    last = None
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code != 429 and e.code < 500:
                fail(f"{url} answered {e.code} {e.reason}")
            last = f"{e.code} {e.reason}"
        # A body cut off mid-read (IncompleteRead) or a 200 carrying truncated
        # JSON is the same kind of hiccup; neither is an OSError.
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError,
                http.client.HTTPException, json.JSONDecodeError) as e:
            last = f"{type(e).__name__}: {getattr(e, 'reason', e)}"
        if attempt < attempts:
            print(f"attempt {attempt} of {attempts} failed ({last}); retrying", file=sys.stderr)
            time.sleep(backoff * 2 ** (attempt - 1))
    fail(f"{url} failed after {attempts} attempts; the last error: {last}")


def hub_tags(repo, name_filter):
    hub = os.environ.get('NEWEST_BASE_HUB', 'https://hub.docker.com').rstrip('/')
    url = (f"{hub}/v2/repositories/{repo}/tags"
           f"?page_size=100&name={urllib.parse.quote(name_filter)}")
    while url:
        page = fetch_json(url)
        for result in page.get('results', []):
            yield result['name'], result.get('digest')
        url = page.get('next')


def main():
    args = sys.argv[1:]
    pinned = args[:1] == ['--pinned']
    if pinned:
        args = args[1:]
    if len(args) != 1:
        fail("usage: newest_dated_base.py [--pinned] <Containerfile>")
    repo, prefix, suffix, distro, from_template = template(args[0])
    want = re.compile(re.escape(prefix) + '(' + re.escape(distro) + r'-(\d{8})-slim)' + re.escape(suffix) + '$')
    found = []
    for tag, digest in hub_tags(repo, prefix + distro + '-'):
        m = want.match(tag)
        if m:
            found.append((m.group(2), m.group(1), digest))
    if not found:
        fail(f"no {repo}:{prefix}{distro}-YYYYMMDD-slim{suffix} tag on Docker Hub")
    _day, debian, digest = max(found)
    if not pinned:
        print(debian)
        return
    if not (isinstance(digest, str) and re.fullmatch(r'sha256:[0-9a-f]{64}', digest)):
        fail(f"{repo}:{prefix}{debian}{suffix} has no digest on Docker Hub ({digest!r}); refusing to build on a tag alone")
    from_ref = from_template.replace('${DEBIAN_VERSION}', debian)
    print(f"{debian} {from_ref} {from_ref}@{digest}")


if __name__ == '__main__':
    main()
