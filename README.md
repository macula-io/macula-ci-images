# macula-ci-images

> Base images for Macula CI and runtime, so that **no pipeline builds a
> toolchain**.

Two images, published to `ghcr.io/macula-io`:

| Image | For | Contains |
|---|---|---|
| `macula-ci-pq` | CI build and test, **mix** services | Elixir **1.19.6** / OTP **28.4.3** on Debian trixie, OpenSSL 3.5+, hex **2.5.1** (sha512-checked, built for OTP 28), rebar3 **3.27.0** (the one mix uses too), Rust **1.98.1** (rustup-init sha256-checked), all pinned exactly |
| `macula-ci-pq:ex118-*` | CI build, test and **release** for mix services that cannot release on Elixir 1.19 yet (macula-realm, macula-portal) | Elixir **1.18.4 compiled on OTP 28.4.3** (hexpm publishes no such pair), Debian trixie, OpenSSL 3.5+, hex **2.5.1**, rebar3 **3.27.0**, Rust **1.98.1**, all pinned. Temporary: Elixir 1.19's `mix release` fails "Unknown application :erts" when a dep lists erts (horus). Goes away when that is fixed upstream |
| `macula-ci-otp` | CI build and test, **rebar3** services | OTP **28.4.3** (the team standard) on Debian trixie-20260918, OpenSSL 3.5+, rebar3 **3.27.0** (sha256-checked), Rust **1.98.1**, all pinned exactly |
| `macula-ci-gleam` | CI build, test and **release** for the **Gleam** services (mcl-bookclub-gleam) | **Gleam 1.18.1** (sha256-checked) on OTP **28.4.3**, Debian trixie, OpenSSL 3.5+, rebar3 **3.27.0**, Rust **1.98.1**, all pinned. Tags are `gleam118-*` so a pinned toolchain cannot drift when the image later moves to a newer Gleam |
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
steps. A step whose `if` has `always()` runs after a failure; the job's
`timeout-minutes` bounds the run. A `strategy.matrix` job runs once per
combination, each on a fresh export and container, with `${{ matrix.X }}`
substituted and each step's `if` evaluated for it (matrix values, literals,
`==`, `!=`, `!`, `&&`, `||`, `always()`, `success()`). Every combination runs
even after one fails, and the gate fails if any did, or if fewer combinations
report than it planned (on 2026-09-27 a throttled fan-out ran one combination of
four and reported green; fixed in 2e65f81); `GATE_MATRIX=check=eunit`
runs one, and `GATE_DRY_RUN=1` prints each combination's plan and runs
nothing. It refuses what it cannot reproduce (an `if` on a run step reading
anything else, such as `failure()` or `steps.*`; matrix `include`/`exclude`;
`shell`, `continue-on-error`, a step's `timeout-minutes`; and any other
`${{ }}` expression), lists the `uses:` steps it skips, caps the container at
`GATE_CPUS` (4) and `GATE_MEMORY` (8g), and removes its workspace on exit:
`/tmp` on host00 is a shared tmpfs. `scripts/test_ci_gate.sh` is its test.

**Before any release tag, gate with `GATE_TEST_CPUS=runner`.** After the job
passes, it restarts the same container with its cap lowered to half a CPU and
re-runs only the test steps (`rebar3 eunit`/`ct`, `mix test`, `cargo test`,
`go test`, `gleam test`, `pytest`), and the report names the cap. A
GitHub-hosted runner's core is slower than host00's, and how much slower
depends on the machine you get. A test that only fits its timeout on a fast
core passes here and fails on CI; mcl-om 9c576f0 did exactly that. `--cpus=1`
cannot show it, because one host00 core is about as fast as a typical runner.
`runner` means 0.5, the largest cap that is at least as slow as the slowest
runner's p90 on 2026-09-26:

| 20 pq_hybrid keygens | p90 (ms) |
|---|---|
| GitHub runner, 9 benches (EPYC 7763 / 9V45) | 570 to 1290 |
| host00, uncapped / 1.0 / 0.5 / 0.25 | 525 / 669 / 1519 / 2295 |

It detects tails, it does not prove their absence: 9c576f0 went red at 0.5 in
2 of 3 runs. Any other value must be a decimal strictly between 0 and 1. The
gate refuses a malformed value, and refuses a job with no test step. Without
`GATE_TEST_CPUS`, the gate is the CI job and nothing more.

A failed run keeps its output and `_build/test/logs` under `GATE_LOG_DIR`
(`~/.cache/ci-gate`), outside the workspace it cleans, and prints the failing
tests' lines under `failures:`: eunit's failed, timed-out and cancelled
(`Pending:`) tests with their reason, rebar3's `Failures:` entries, ct's
`==>` lines, and the totals. A failure that does not come back on a rerun is
still named. Runs go in `GATE_LOG_DIR/runs`, and only the newest
`GATE_LOG_KEEP` (20) stay. Pruning touches only the gate's own run names
there, since `GATE_LOG_DIR` may be shared, and `/` or `$HOME` is refused.

## Signing an image: `attest-image.yml`

A reusable workflow every image build calls after it pushes, so a box can refuse any
digest that did not come from our CI on our commit. For one digest it:

1. signs it with cosign, **keyless**: GitHub's OIDC token gets a short-lived Fulcio
   certificate for this workflow's identity, and the signature goes to the **public**
   Rekor log. There is no key to leak or rotate.
2. attests its **SBOM** (syft, SPDX JSON, read from the registry, not a local daemon);
3. attests its **provenance** (SLSA v1: repository, ref, commit, calling workflow, run);
4. verifies all three with the identity a box checks, so a green job means a verifier
   accepts the digest.

```yaml
attest:
  needs: build-and-push
  permissions: { contents: read, packages: write, id-token: write }
  uses: macula-io/macula-ci-images/.github/workflows/attest-image.yml@<full commit sha>
  with:
    image: ghcr.io/<org>/<name>
    digest: ${{ needs.build-and-push.outputs.digest }}
    runs-on: '["self-hosted","host00"]'   # private repos; public ones omit it (ubuntu-latest)
```

Call it by **full commit sha**, never `@main`: the signing identity is this file at the
ref the caller names. What a verifier checks: issuer
`https://token.actions.githubusercontent.com`, identity matching
`^https://github\.com/macula-io/macula-ci-images/\.github/workflows/attest-image\.yml@`,
and the certificate's GitHub workflow repository equal to the calling repository.

`attest-image-selftest.yml` proves any change to it on a throwaway one-file image
(`ghcr.io/macula-io/attest-image-selftest`) before a service calls it.

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
builds on exactly the digest Docker Hub reports for that tag (the resolver's
`--pinned` mode, passed to the build as a named context, so a tag pushed again
cannot change the base unseen), and stamps both on the image: the tag as the
`io.macula.debian-base` label, the digest-pinned reference as
`io.macula.base-image`. A tag with no digest is refused.
The Containerfile's own `DEBIAN_VERSION` is only the default for local builds.
The daily build is cache-served, so it reproduces the same layers until the
base moves; a weekly build (Sunday 03:00 UTC) runs uncached. A base that cannot
be resolved fails the build rather than falling back to the old one. Docker
Hub is asked with bounded retries (5 attempts, doubling backoff) for timeouts,
dropped connections, bodies cut off mid-read, 429 and 5xx; after the last
attempt the build fails, naming the URL and the last error, and a 4xx fails
at once.
`scripts/test_newest_dated_base.sh` is its test; no workflow runs it, so run
it before changing the resolver, as `scripts/test_ci_gate.sh` before changing
the gate.

**Every download is checked.** Anything a Containerfile fetches besides apt
packages (which Debian's signatures cover) is downloaded to a file and checked
against a checksum pinned in the Containerfile, in the same `RUN`: rebar3, hex,
the Elixir source, Gleam, erlang-rocksdb, and rustup's installer (`rustup-init`
**1.29.1** from `static.rust-lang.org/rustup/archive`, sha256-checked; it was
piped from `sh.rustup.rs` unchecked before). `scripts/check_pinned_downloads.py`
refuses a download piped into anything or made inside `$(...)`, and requires
the very next command in an `&&` chain to be `echo "SUM  FILE" | sha256sum -c -`
(or sha512sum) for that file, with SUM a literal digest or a bare `${ARG}`
declared with a default in the Containerfile; curl and wget must head their
command (no `env curl`, `/usr/bin/curl | sh` or `bash < <(curl ...)`); a RUN that downloads may not use `||`, `;`, `&`
or a subshell, so a failed check always fails the build, and `sh -c` strings
are checked the same way. build.yml runs it,
after its own test (`scripts/test_check_pinned_downloads.sh`), before any image
is built. rustup then downloads the pinned Rust toolchain itself and checks it
against the hashes in Rust's release manifest, fetched over TLS from the same
host: pinned by version, not by a checksum of ours.

**The builds are reproducible.** Two uncached builds of the same inputs give
the same manifest digest: identical layers AND an identical config. So a
rebuild that changes nothing inside publishes the same digest, and a consumer
pinning by digest can tell a real change (a new Debian package, a new
toolchain, a new base) from a timestamp. `SOURCE_DATE_EPOCH` is midnight UTC of
the resolved Debian base's date, never the commit time (the rocksdb images read
it from their base's `io.macula.debian-base` label), and the published image
rewrites every file's time to it. Every label is a function of the inputs
(`scripts/image_labels.sh`): `org.opencontainers.image.created` is the epoch,
and there is no build time and no commit sha in the config (the
`:YYYYMMDD-HHmm` tag names the build, outside the digest). The Containerfiles
remove what records a time or an order: apt, dpkg and ldconfig logs and caches,
hex's `cache.ets`, mix's `/tmp` lock and pubsub files; they sort rustup's
`components` list (downloaded concurrently, listed as each lands) and check
rustup still reads it; and Elixir's own build in ex118 is compiled
`deterministic` with the epoch as its build date. BuildKit itself is pinned
by version and digest in both workflows, because its exporter decides the
compressed blobs: a BuildKit bump can move every digest with nothing inside
changing, so it is a deliberate change, never a silent one.
`.github/workflows/reproducibility.yml` proves it: every image, the three
rocksdb ones included, under the names build.yml publishes them by (the name
is in the digest; `scripts/check_workflow_matrices_agree.py` refuses a
matrix that drifts), built twice uncached with the labels build.yml
publishes with, pushed to a registry that lives only inside the job, and the
two manifest digests compared (`scripts/compare_pushed_images.sh`). A mismatch
names its cause: the files that differ, or the config fields and history
entries (`scripts/compare_image_layers.sh`, tested by
`scripts/test_compare_image_layers.sh` in the same workflow). It runs on every
change to a Containerfile, the build, the labels, the comparator or the
resolver, and weekly after the uncached build.

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
