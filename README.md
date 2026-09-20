# macula-ci-images

> Base images for Macula CI and runtime, so that **no pipeline builds a
> toolchain**.

Two images, published to `ghcr.io/macula-io`:

| Image | For | Contains |
|---|---|---|
| `macula-ci-pq` | CI build and test | Elixir/OTP on Debian trixie, OpenSSL 3.5+, hex, rebar3, a Rust-capable build environment |
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

**Daily** (04:00 UTC) plus on change and on demand. The schedule is the point:
built only on change, a base image rots quietly while the OS it carries ships
security fixes nobody picks up.

Daily rather than weekly because it costs nothing (public repo, free unlimited
hosted minutes, ~60s per build) and Debian ships security updates continuously.
It does **not** churn consumers daily: layers are content-addressed and cached,
so a day where nothing moved upstream reproduces the same digest and nobody
re-pulls. A new image reaches consumers exactly when a package actually
changed.

Each build publishes `:latest` and a `:YYYYMMDD` tag, so a consumer that needs
to escape a bad rebuild has something to pin to. Pinning to a digest is
stricter and also works.
