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

**On a box whose CI runners live under a slice, gate under the same slice.**
`GATE_CGROUP_PARENT=ci-runners.slice` (msi00, with plain podman as `ENGINE`)
puts the gate's container under that slice (`--cgroup-parent`), so it gets the
same memory ceiling as the runner; without it the container sits in its own
scope under `user.slice`, outside the ceiling, even when the gate is launched
from inside the slice. Anything but one slice name is refused. It is the
gate's own variable: Terra's docker shim reads `CI_RUNNER_CGROUP_PARENT`, sets
the slice itself and refuses a caller's `--cgroup-parent`, so the gate refuses
the two together. Either plain podman with `GATE_CGROUP_PARENT`, or the shim
as `ENGINE` with `CI_RUNNER_CGROUP_PARENT` alone.

**A reserved host refuses the gate.** While `~/.host00-slot` (`GATE_SLOT_FILE`) exists,
the gate refuses to start unless `GATE_SLOT_OWNER` equals its `owner=` line, and names
the owner. The owner is whatever the caller says it is: this guards against a gate
started by mistake during someone's measurement slot, not against intent.

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
    runs-on: '["self-hosted","pq"]'   # private repos (msi00; host00 takes no CI); public ones omit it (ubuntu-latest)
```

Call it by **full commit sha**, never `@main`: the signing identity is this file at the
ref the caller names. What a verifier checks: issuer
`https://token.actions.githubusercontent.com`, identity matching
`^https://github\.com/macula-io/macula-ci-images/\.github/workflows/attest-image\.yml@`,
and the certificate's GitHub workflow repository equal to the calling repository.
**Verify with cosign v3.** The workflow signs and attests with cosign v3.1.3, in v3's
bundle format; a cosign v2 verifier (v2.5.3 tried) reports "no signatures found" and
"no matching attestations" on a correctly signed image. With v3 (for example
`ghcr.io/sigstore/cosign/cosign@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8`),
the flags are those of the workflow's own verify step: `--certificate-oidc-issuer`,
`--certificate-identity-regexp`, `--certificate-github-workflow-repository <org>/<repo>` and
`--certificate-github-workflow-sha <commit>`, for `verify`, then `verify-attestation`
with `--type spdxjson` and with `--type slsaprovenance1`.

`attest-image-selftest.yml` proves any change to it on a throwaway one-file image
(`ghcr.io/macula-io/attest-image-selftest`) before a service calls it.

## Refusing a bad release: `release-guard.yml`

A reusable workflow that refuses a `v*` tag which must not be released. It runs in
`attest-image.yml` before anything is signed, so every image release gets it, and a
release-only workflow (hex, crates.io, npm, PyPI, NuGet) can call it as its first job.
Any other ref passes untouched, so a repository that builds on every `main` push keeps
building.

1. **The tag is on the default branch.** The tagged commit must be an ancestor of
   `origin/<default branch>`. `mcl_om` 1.0.0, the version every service depends on, was
   tagged on a side branch two commits ahead of `main`, and nothing noticed. A hotfix
   on an older line may instead sit on that line's maintenance branch,
   `release-<major>.<minor>`, which the tag itself names: `v0.10.4` passes on
   `release-0.10` (macula-station) and `v0.3.15` on `release-0.3` (macula-realm), and
   nothing else does. The caller cannot name another branch.
2. **The tag is the version the repository publishes.** BEAM: the relx release version
   and the `vsn` of every app the release names (a helper app beside the release is not
   checked). Elsewhere: the manifest the release publishes, `Cargo.toml` (`[package]`
   version, or `[workspace.package]` version for a crate that inherits it; a virtual
   workspace root also has every member crate read, since it publishes them all),
   `package.json`, `pyproject.toml` or every `*.csproj` that packs (`<Version>`, or
   `<VersionPrefix>` plus any `<VersionSuffix>`, from the project or the nearest
   `Directory.Build.props` above it, the one MSBuild imports; a project with
   `<IsPackable>false</IsPackable>` is not read). `mcl-fovea` 0.6.1 shipped a relx
   version of 0.4.2, so a box reporting its release reported the wrong one.

```yaml
guard:
  permissions: { contents: read }
  uses: macula-io/macula-ci-images/.github/workflows/release-guard.yml@<full commit sha>
  with:
    require-tag: true                          # release-only workflows; optional
    runs-on: '["self-hosted","pq"]'            # private repos; public ones omit it
    version-root: system                       # versions below the root; optional
```

`version-root` names the directory that holds the version sources when it is not the
repository root: macula-portal keeps its umbrella `mix.exs` in `system/`. Read from the
root, that tree holds no version and the release is refused. `attest-image.yml` takes
the same input.

`tag-prefix` names what a release tag starts with, `v` unless set: macula-rust's FFI
crate releases from `ffi-v<version>` tags, so its release workflow passes
`tag-prefix: ffi-v` (with `version-root: macula-rust-ffi`) and those tags are checked
rather than passed as not being releases. A prefix is letters, digits, `.`, `_` and
`-`; anything else stops the guard.

`versions: none` is a declaration, for a repository whose version is the tag itself and
appears in no file: a Go module (macula-go, mcl-fovea-keeper), where `go.mod` names no
version. The version check then prints that the caller declared it and passes; the tag
must still be on its branch. It is never a default: a Go tree that does not say so is
refused for holding no version, and any value other than `check` or `none` stops the
guard. `attest-image.yml` takes the same input, and the caller passes it to both.

The checks are `scripts/release_guard.sh`, which prints every version source it read
and every one that disagreed. They travel inside the workflow rather than being read
from the caller's tree: a reusable workflow runs in the caller's repository, so
`./scripts/release_guard.sh` would be missing in every other repository and, worse, a
tag that skipped review could carry its own copy and choose its own guard.
`scripts/embed_release_guard.sh` writes the block into `release-guard.yml` and
`attest-image.yml`, and `scripts/test_release_guard.sh` extracts the block and runs
every case against it, failing if the two files differ by a byte.
`release-guard-selftest.yml` runs it on every change, plus one call of the workflow
itself.

The version check fails closed on a source it cannot read a literal version from: an
Elixir project whose `version:` is a module attribute, a relx release whose version is
a macro, a manifest with no literal version, and an umbrella whose root names no
version at all are all refused rather than passed. BEAM is detected by a
`rebar.config` or `mix.exs` in the root, and only then are `.app.src` files read (an
Erlang helper below a Rust tree is not what it releases), so a BEAM repository that also carries a
`package.json` is checked against its Erlang or Elixir versions only. When a
`rebar.config` names several relx releases, the first one is what relx builds, so it is
the one checked.

Two BEAM shapes escape the version check, both by being read as something other than
what they are. An app named as a tuple in the release list (`{mnesia, load}`) is
skipped, so its version is not compared. And because the first tuple in the file is the
one read, a release declared inside a `profiles` block is treated as the top-level
release, which can refuse a good release or check the wrong one.

## Checking a doc's Erlang blocks: `doc-snippets-erlang.yml`

This exists so a reader who copies an Erlang example from a README or a guide gets
code that works, and an example that stops working fails its repository's CI before
it ships (macula-codebase-checks#8).

A reusable workflow that compiles the caller's rebar3 project and then reads every
block fenced `erlang` or `erl` in the docs the package ships (`README*.md` and
`guides/**.md` at any depth, `docs/**.md` without design records, plans, reports,
backlogs and registers):

| A block that is | is checked by |
|---|---|
| a module (`-module(...)`) | compiling it as it stands, and loading it unless the repository already has a module of that name |
| forms without a module (functions, records, specs) | compiling them in a module of their own. A local function they call and do not define is the reader's own and gets a placeholder, so a misspelt local call is a placeholder too and nothing catches it in a forms block; a spec listing compiles once its types resolve |
| expressions, or a shell session (`1>` prompts; output lines are not code) | compiling each block as a function whose parameters are the variables it uses and does not bind, so a fragment that uses a `Client` the prose made is checked for its calls and syntax as it stands. A misspelt variable is a parameter too, and a local function the block calls is the reader's own, with a placeholder: only a `run` block, compiled with neither, catches those |

Every remote call with a literal module and function must then reach an exported
function on the code path, which the compiler alone does not check: an example that
calls an API that is gone fails here. A record a block uses comes from the header that
defines it, the repository's or a dependency's, so the check needs no `-include`; a
reader pasting that block into a shell still needs `rr/1` or an `-include_lib`, so the
doc should say which. A module block is compiled as it stands, with its own includes.

Two markers, as an HTML comment on the line before the fence, which every renderer
hides:

```markdown
<!-- doc_snippets: skip a counter-example: this call crashes the gateway worker -->
<!-- doc_snippets: run -->
```

A skip needs its reason. `run` compiles the doc's session blocks up to and including
the last run-marked one, in order, as one function body, where a variable must be bound by an
earlier block, and executes it:
an exception or a timeout (`timeout`, default 120 s) fails the job. Every guide should carry a run block
that reaches the real thing the way the repository's tests do, so an example that
compiles but never fires is caught too.

```yaml
  docs:
    permissions: { contents: read }
    uses: macula-io/macula-ci-images/.github/workflows/doc-snippets-erlang.yml@<full sha>
```

Pin it by full commit, put it where the publish waits on it, and keep `**.md` and
`guides/**` out of its workflow's `paths-ignore`. macula-codebase-checks' `doc_snippets`
class reports a publishing repository where any of that is missing. As with the release
guard, the check travels inside the workflow, written there from
`scripts/doc_snippets_erlang.escript` by `scripts/embed_doc_snippets.sh`;
`scripts/test_doc_snippets_erlang.sh` runs its cases against the embedded copy.

## Checking a doc's Go blocks: `doc-snippets-go.yml`

The same end for a Go module: every block fenced `go` or `golang` in its shipped docs
builds against the module. A block with a package clause is a file and is built as it
stands; any other block is a fragment, compiled as top-level functions plus a function
body in a package that is not `main`, with its missing imports supplied by goimports.
`go build -gcflags=-e` reports every error, at the doc's own line.

What a fragment leaves to the reader is not an error: an identifier it uses and does
not declare, a variable or import it does not use, a return with no function around it,
a name bound twice by a block of alternatives, and `...` for elided code. Everything
about the module is: a function, field, method or type it does not have, a wrong
argument, the syntax, and a package of the module named with a member it does not have.
A method on an identifier the block does not declare cannot be checked, since its type
is not known.

```yaml
  docs:
    permissions: { contents: read }
    uses: macula-io/macula-ci-images/.github/workflows/doc-snippets-go.yml@<full sha>
```

`skip` is the one marker. The script is `scripts/doc_snippets_go.py`, embedded by
`scripts/embed_doc_snippets.sh` and tested as embedded by `scripts/test_doc_snippets_go.sh`.

## Checking a doc's Python blocks: `doc-snippets-python.yml`

The same end for a typed Python package: every block fenced `python`, `py`, `python3`
or `pycon` in its shipped docs type-checks against the package. Each block is the body
of an async function of its own (a top-level `await` is valid), carrying the imports the
doc's earlier blocks made, and mypy reads it against the package's source without
installing it. Syntax is checked first, so one broken block cannot hide the rest.

What a block leaves to the reader is not an error: an undefined name, a name bound twice,
a return value, `...`. An attribute, method, argument, keyword or import the package does
not have is, so is a wrong type against its hints, and a package of its own used and never
imported. A method on an undefined name cannot be checked.

```yaml
  docs:
    permissions: { contents: read }
    uses: macula-io/macula-ci-images/.github/workflows/doc-snippets-python.yml@<full sha>
```

`skip` is the one marker. The script is `scripts/doc_snippets_python.py`, tested as embedded
by `scripts/test_doc_snippets_python.sh`.

## Checking a doc's TypeScript blocks: `doc-snippets-ts.yml`

The same end for an npm package written in TypeScript: every block fenced `ts`,
`typescript`, `tsx`, `js`, `javascript`, `mjs` or `jsx` in its shipped docs type-checks
against the package. Each block is a module file of its own as it stands (a top-level
`await` is valid), and tsc reads them with the package's own name mapped to its source
after `npm ci`, so nothing is built first. JavaScript is checked as JavaScript.

What a block leaves to the reader is not an error: an undeclared name, a name declared
twice, a return with no function. A misspelt name is reported when tsc's suggestion is a
name the block imports or declares, or a common global, unless the two differ only in
case: `tally` beside the imported `Tally` is an instance of its class, not a
misspelling. An export, property, method, argument or type the package does not have is,
so is a module it cannot find. An error outside the blocks (the package's own source,
the generated configuration) fails the run as one that could not be made.

```yaml
  docs:
    permissions: { contents: read }
    uses: macula-io/macula-ci-images/.github/workflows/doc-snippets-ts.yml@<full sha>
```

`skip` is the one marker. The script is `scripts/doc_snippets_ts.py`, tested as embedded
by `scripts/test_doc_snippets_ts.sh`.

## Checking a doc's C# blocks: `doc-snippets-csharp.yml`

The same end for a .NET package: every block fenced `csharp`, `cs`, `c#` or `dotnet` in its
shipped docs compiles against the package's own source, in one generated project that
ProjectReferences it, with implicit usings and nullable on as `dotnet new` writes them. A
block that declares a type is a file compiled as it stands; any other block is a fragment
whose statements become the body of an async method of its own, carrying the usings the
doc's earlier blocks made, and a `#line` directive reports every error at the doc's own line.

What a fragment leaves to the reader is not an error: a free name, an unused variable, a
name a block of alternatives binds twice, a return where the wrapping method has none to
give, and a deconstruction a free name caused. Everything about the package is: a type, a
member, an argument, the syntax, and a capitalised name used as a type that nothing
declares, which is how `Session.New()` fails now that `Pool` is the name. A method on a name
the block does not declare cannot be checked, since its type is not known.

```yaml
  docs:
    permissions: { contents: read }
    uses: macula-io/macula-ci-images/.github/workflows/doc-snippets-csharp.yml@<full sha>
    # with:
    #   dotnet-version: 10.0.x
```

`skip` is the one marker. The script is `scripts/doc_snippets_csharp.py`, embedded by
`scripts/embed_doc_snippets.sh` and tested as embedded by
`scripts/test_doc_snippets_csharp.sh`.

## Checking a doc's PHP blocks: `doc-snippets-php.yml`

The same end for a Composer package: every block fenced `php` in its shipped docs parses
under `php -l` and type-checks under PHPStan against the package's own autoloader. A block
that opens with `<?php` or declares a namespace is a file read as it stands; a block of
types is that declaration; any other block is a fragment whose statements become the body of
a function of its own, carrying the `use` statements the doc's earlier blocks made. Every
reported line is mapped back to the doc line it came from.

What a fragment leaves to the reader is not an error: an undefined variable, and a bare call
to a function the package and the standard library do not have, which is the reader's own.
Everything about the package is: a class, a member, a method, an argument count, a call to a
qualified function, the syntax. Nothing is put in a namespace, so a doc's `Macula\Pool` still
means what it says.

```yaml
  docs:
    permissions: { contents: read }
    uses: macula-io/macula-ci-images/.github/workflows/doc-snippets-php.yml@<full sha>
    # with:
    #   php-version: 8.3
    #   phpstan-version: 2.3.1
```

`skip` is the one marker. The script is `scripts/doc_snippets_php.py`, embedded by
`scripts/embed_doc_snippets.sh` and tested as embedded by `scripts/test_doc_snippets_php.sh`.

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
