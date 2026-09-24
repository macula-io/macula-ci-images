# macula-ci-images

> Base images for Macula CI and runtime, so that **no pipeline builds a
> toolchain**.

Two images, published to `ghcr.io/macula-io`:

| Image | For | Contains |
|---|---|---|
| `macula-ci-pq` | CI build and test, **mix** services | Elixir **1.19.6** / OTP **28.4.3** on Debian trixie, OpenSSL 3.5+, hex **2.5.1** (sha512-checked, built for OTP 28), rebar3 **3.27.0** (the one mix uses too), Rust **1.98.1**, all pinned exactly |
| `macula-ci-pq:ex118-*` | CI build, test and **release** for mix services that cannot release on Elixir 1.19 yet (macula-realm, macula-portal) | Elixir **1.18.4 compiled on OTP 28.4.3** (hexpm publishes no such pair), Debian trixie, OpenSSL 3.5+, hex **2.5.1**, rebar3 **3.27.0**, Rust **1.98.1**, all pinned. Temporary: Elixir 1.19's `mix release` fails "Unknown application :erts" when a dep lists erts (horus). Goes away when that is fixed upstream |
| `macula-ci-otp` | CI build and test, **rebar3** services | OTP **28.4.3** (the team standard) on Debian trixie-20260918, OpenSSL 3.5+, rebar3 **3.27.0** (sha256-checked), Rust **1.98.1**, all pinned exactly |
| `macula-pq-runtime` | release runtime stage | Debian trixie, OpenSSL 3.5+, the runtime libraries a release links |
| `macula-ci-otp-rocksdb` | CI build, rebar3 services that link erlang **rocksdb** (barrel_docdb via mcl-om) | `macula-ci-otp` plus a prebuilt shared **librocksdb 11.1.2** (the tree erlang rocksdb 3.1.2 bundles) in `/usr/local`, and `ERLANG_ROCKSDB_OPTS=-DWITH_SYSTEM_ROCKSDB=ON`: a build compiles only the NIF |
| `macula-pq-runtime-rocksdb` | release runtime stage for those services | `macula-pq-runtime` plus `librocksdb.so.11` and its compression libraries |
| `macula-ci-pq-ex118-rocksdb` | CI build, **mix** services on Elixir 1.18 that link erlang rocksdb (macula-portal, via barrel_docdb) | `macula-ci-pq` ex118 plus the same librocksdb and env; runs on `macula-pq-runtime-rocksdb` |

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

## The rocksdb pair

`Containerfile.rocksdb` builds RocksDB **once**, on a GitHub-hosted runner, so no
service compiles it again (10-20 minutes of every core per build; four at once
put host00 at load 93 on 2026-09-24). A service that links erlang `rocksdb`
builds in `macula-ci-otp-rocksdb` (rebar3) or `macula-ci-pq-ex118-rocksdb` (mix, Elixir
1.18) and runs on `macula-pq-runtime-rocksdb`:

```dockerfile
FROM ghcr.io/macula-io/macula-ci-otp-rocksdb@sha256:<digest> AS builder
# ... rebar3 as_prod release: the NIF links /usr/local/lib/librocksdb.so.11
FROM ghcr.io/macula-io/macula-pq-runtime-rocksdb@sha256:<digest>
```

⛔ **The pair goes together.** A release built in the rocksdb CI image carries
a NIF that needs `librocksdb.so.11` at run time; on plain `macula-pq-runtime`
it fails at the first rocksdb call, not at boot.

Both are derived from `macula-ci-otp` and `macula-pq-runtime` **by digest**, in
a job that runs after those are rebuilt, so they follow every security rebuild.
Each image refuses to publish unless its self-test passes: the CI image compiles
the real binding against the library, checks the NIF links it, and writes and
reads a database; the runtime checks the library resolves with nothing missing.

## Gating a commit locally, the way CI runs it

`scripts/ci_gate.sh <repo> <sha> [workflow, default lint.yml] [job, default check]`
runs every `run:` step of a job inside that job's own pinned image, as root, on
a `git archive` of the commit, and exits with the job's status. Env layers as
CI layers it (the runner's `CI`, `GITHUB_*`, then workflow, job and step
`env`), and what a step writes to `GITHUB_PATH` / `GITHUB_ENV` reaches the next
steps. An `if: always()` step runs after a failure; the job's
`timeout-minutes` bounds the run. It refuses what it cannot reproduce (any
other `if`, `shell`, `continue-on-error`, a step's `timeout-minutes`, and
`${{ }}` expressions), lists the `uses:` steps it skips, caps the container at
`GATE_CPUS` (4) and `GATE_MEMORY` (8g), and removes its workspace on exit:
`/tmp` on host00 is a shared tmpfs. `scripts/test_ci_gate.sh` is its test.

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

**How the base stays current.** Every build resolves the newest dated Debian
snapshot published for the image's exact pinned toolchain
(`scripts/newest_dated_base.py`, e.g. `hexpm/erlang:28.4.3-debian-trixie-YYYYMMDD-slim`),
builds on it, and stamps it on the image as the `io.macula.debian-base` label.
The Containerfile's own `DEBIAN_VERSION` is only the default for local builds.
The daily build is cache-served, so it reproduces the same layers until the
base moves; a weekly build (Sunday 03:00 UTC) runs uncached. A base that cannot
be resolved fails the build rather than falling back to the old one.

`scripts/test_new_base_changes_layers.sh` is the proof that this moves
anything: it builds one Containerfile on two dated bases and refuses unless both
pass their tool assertions and every layer, base included, differs. (Before
this, the scheduled rebuild reproduced identical layers from cache every day:
the ci-otp images tagged 20260920-2117 and 20260923-0912 were layer-for-layer
the same.)

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
