# macula-ci-images

> Base images for Macula CI and runtime, so that **no pipeline builds a
> toolchain**.

Two images, published to `ghcr.io/macula-io`:

| Image | For | Contains |
|---|---|---|
| `macula-ci-pq` | CI build and test, **mix** services | Elixir 1.18.4 / OTP 28.1.1 on Debian trixie, OpenSSL 3.5+, hex, rebar3, Rust |
| `macula-ci-otp` | CI build and test, **rebar3** services | OTP **28.4.3** (the team standard) on Debian trixie-20260918, OpenSSL 3.5+, rebar3 **3.27.0** (sha256-checked), Rust **1.98.1**, all pinned exactly |
| `macula-pq-runtime` | release runtime stage | Debian trixie, OpenSSL 3.5+, the runtime libraries a release links |

## Why this repo exists

`macula-realm`'s CI used to build **OpenSSL 3.6.4, OTP 28.1 and Elixir 1.18.4
from source on every cold run**, about 15 minutes, to reach a toolchain that a
`docker pull` already provides. It did that because `setup-beam`'s prebuilt OTP
pins its own OpenSSL, which predates ML-DSA and does not move with
`LD_LIBRARY_PATH`. The answer is not to build OTP differently; it is to start
from a base whose OpenSSL is new enough.

It is a separate repo rather than a Containerfile inside a service, because the
image is a **cross-repo dependency**. Living inside one consumer, every other
consumer would wait on that repo's branch state and permissions for a toolchain
bump, and its rebuild trigger (a base OS security update) has nothing to do with
that repo's code.

## ⚠ Trixie is load-bearing

The 11.x wire signs with ML-DSA-87/ML-KEM, which arrived in **OpenSSL 3.5**.
Bookworm ships 3.0, where the crypto NIF dies with `evp.c "Bad key type"` on the
first post-quantum keygen. Both images assert this at build time and **fail the
build** rather than publish an image that would take every consumer's CI green
while the wire fails.

## Using them

```dockerfile
FROM ghcr.io/macula-io/macula-ci-pq:latest AS builder
# ...
FROM ghcr.io/macula-io/macula-pq-runtime:latest
```

In a workflow, as a container job:

```yaml
jobs:
  test:
    runs-on: [self-hosted, pq]
    container:
      image: ghcr.io/macula-io/macula-ci-pq:latest
    steps:
      - uses: actions/checkout@v4   # required: see below
      - run: mix test
```

⚠ A `uses:` step is **load-bearing on podman runners**, not decoration. The
runner bind-mounts `_work/_actions` into the container; Docker silently creates
a missing bind-mount source, podman refuses with
`statfs ... no such file or directory`. With no action to download, `_actions`
is never populated and `docker create` fails.

## Rebuilds

**Daily** (04:00 UTC), plus on change and on demand. The schedule is the point:
built only on change, a base image rots quietly while the OS it carries ships
security fixes nobody picks up.

Hourly was considered and rejected on evidence rather than cost. The build is
free and takes ~60s, so cost is not the constraint; upstream and GitHub are.
Debian's archive does not move hourly, and GitHub delays or drops scheduled runs
under load with hourly its least reliable tier — so an hourly cron neither runs
hourly nor finds anything new most of the time. Daily is where the cadence stops
buying anything. To pick up a specific CVE sooner, `workflow_dispatch` is
immediate and exact.

⚠ **What the rebuild actually does today, measured 2026-09-23:** every step
is served from the build cache (`cache-from: type=gha`), and the base image is
pinned to a dated Debian snapshot, so a scheduled rebuild reproduces the same
LAYERS and picks up no package updates. Only the build-date label changes,
which gives each rebuild a new digest. The `macula-ci-otp` images tagged
20260920-2117 and 20260923-0912 have identical layers. Whether the rebuild
should refresh packages is an open decision, not something this file claims.

Each build publishes `:latest` and a `:YYYYMMDD-HHmm` tag. **Consumers pin
`:YYYYMMDD-HHmm@sha256:<digest>`, never `:latest`**: the tag says when, the
digest makes it immutable, and a new toolchain reaches a consumer only through
a commit in that consumer. The tools inside `macula-ci-otp` are pinned
exactly in `Containerfile.ci-otp`, and the build fails rather than publish a
different one.

The tag carries the time, not just the date, and that is **not** about the
schedule: push and `workflow_dispatch` builds land on the same day as the
scheduled one, so a date-only tag would be claimed by several builds and
silently overwritten. A moving tag that looks immutable is worse than no tag at
all, at any cadence.
