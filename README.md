# gnu-cross

Prebuilt x86-64 Linux glibc GCC toolchains. Each archive is built from the
pinned crosstool-NG commit in `targets/x86_64-unknown-linux-gnu/versions`,
checked before publication, and published as a directory tarball plus a
SHA-256 sidecar.

The compiler host and the target C library are different compatibility
boundaries. Pick the variant whose host libraries match the machine that runs
the compiler. The variant name selects the target glibc ABI; it does not make
the compiler a static host binary, and it does not lower the target's minimum
Linux kernel below 5.4.302.

Contents: Overview · Targets & Component Matrix · Install · Usage · Build & Automated Release · Repository Layout · License

## Overview

These toolchains compile C and C++ for `x86_64-unknown-linux-gnu`. Four host
profiles pin four target glibc ABIs so a program built for an older profile
does not require a newer target libc. Rust's standard library is installed
separately; pointing Cargo at this GCC does not rebuild it.

## Targets & Component Matrix

| Target | Host variant | Target glibc |
|---|---|---|
| `x86_64-unknown-linux-gnu` | `centos7` | 2.17 |
| `x86_64-unknown-linux-gnu` | `amazonlinux2` | 2.26 |
| `x86_64-unknown-linux-gnu` | `alinux3` | 2.32 |
| `x86_64-unknown-linux-gnu` | `ubuntu22` | 2.34 |

| Component | Version |
|---|---|
| GCC | Accepted version in `versions` |
| binutils | 2.47 |
| Linux headers / minimum kernel | 5.4.302 |
| mold | Accepted version in `versions` |

Accepted identities live in [`targets/x86_64-unknown-linux-gnu/versions`](targets/x86_64-unknown-linux-gnu/versions). Scheduled updates may advance GCC and mold only. The four glibc ABIs and the 5.4 kernel baseline stay put.

## Install

`v0.0.1` is replaced after a fully verified build. Record the source revision and the artifact SHA-256 if you need a reproducible download. The sidecar is a bare digest.

```sh
RELEASE_TAG=v0.0.1
TARGET=x86_64-unknown-linux-gnu
VARIANT=ubuntu22
ARCHIVE="${TARGET}-${VARIANT}.tar.xz"
BASE="https://github.com/trunkszi/gnu-cross/releases/download/${RELEASE_TAG}"

curl -fL "${BASE}/${ARCHIVE}" -o "${ARCHIVE}"
curl -fL "${BASE}/${ARCHIVE}.sha256" -o "${ARCHIVE}.sha256"
EXPECTED=$(awk 'NR == 1 { print $1 }' "${ARCHIVE}.sha256")
printf '%s  %s\n' "${EXPECTED}" "${ARCHIVE}" | sha256sum --check -

INSTALL_ROOT="${HOME}/.local/opt/gnu-cross/${VARIANT}"
mkdir -p "${INSTALL_ROOT}"
tar -xJf "${ARCHIVE}" -C "${INSTALL_ROOT}"
export TOOLCHAIN="${INSTALL_ROOT}/${TARGET}"
export PATH="${TOOLCHAIN}/bin:${PATH}"
```

Each archive has one top-level `x86_64-unknown-linux-gnu/` directory. Keep variants in separate parents. Reject a missing or non-64-hex digest before extraction.

## Usage

```sh
TARGET=x86_64-unknown-linux-gnu
"${TOOLCHAIN}/bin/${TARGET}-gcc" -O2 hello.c -o hello-c
"${TOOLCHAIN}/bin/${TARGET}-g++" -O2 -std=c++20 hello.cpp -o hello-cpp
"${TOOLCHAIN}/bin/${TARGET}-g++" -O2 -fuse-ld=mold hello.cpp -o hello-mold
```

```toml
[target.x86_64-unknown-linux-gnu]
linker = "/absolute/path/to/x86_64-unknown-linux-gnu/bin/x86_64-unknown-linux-gnu-gcc"
```

```sh
rustup target add x86_64-unknown-linux-gnu
cargo build --release --target x86_64-unknown-linux-gnu
```

For native code built by Cargo build scripts, also set `CC_x86_64_unknown_linux_gnu`, `CXX_x86_64_unknown_linux_gnu`, and `AR_x86_64_unknown_linux_gnu`.

## Build & Automated Release

```sh
git clone --recurse-submodules https://github.com/trunkszi/gnu-cross.git
cd gnu-cross
./scripts/build-with-docker.sh x86_64-unknown-linux-gnu ubuntu:22.04 ubuntu22
./scripts/make x86_64-unknown-linux-gnu
```

`scripts/make` installs host packages, builds the pinned crosstool-NG tree, selects the host's glibc ABI, and runs `scripts/verify-toolchain.sh` before packaging. `scripts/build-with-docker.sh` runs that build in a container with `seccomp` unconfined so the TSan check can disable ASLR.

`.github/workflows/release.yaml` runs every day at 02:20 UTC and on manual dispatch. The scheduled run reads the latest stable `crosstool-ng/releases` tag, compares its peeled commit with `versions`, and builds only when that commit changes. An update may select a newer stable GCC and mold. It does not switch this tree to musl, and it does not raise the four target glibc versions or the Linux 5.4 baseline. After all four host builds and their runtime checks pass, the workflow uploads replacement assets to `v0.0.1` and only then moves that tag. A patch that does not apply with `--fuzz=0` stops the run before any release write and sends the failure mail when SMTP secrets are configured. Manual dispatch can rebuild the accepted lock, or set `check_upstream` to run the same resolver.

Preparation bundles one complete source tree, including the target metadata and
builder gitlink. All host builds and publication restore that same tree. Each
archive has a provenance manifest binding its source revision, metadata hashes,
host and digest to the original workflow run. An upstream update creates a root
commit authored and committed by Nathan Shea, with message `first commit`.
After remote asset verification, Git transfers that commit and updates `main`
and the release tag. Asset replacement is not atomic: a failed upload or ref
update requires checking the release for a partial update.

`source_run_id` reuses only a completed, successful release workflow on `main`
in this repository. Its original head SHA and bundled candidate remain the
artifact identities; reuse does not roll `main` back. Failure reports identify
preflight, build or publication and include the run URL and upstream versions.

Run `bash tests/run.sh` for offline contract regressions. The patch test uses a
temporary functions fixture when no optional sibling builder source is present;
it never initializes this repository's `builder/`.

## Repository Layout

- `builder/` — pinned crosstool-NG submodule. It is not initialized in a fresh checkout until a build asks for it.
- `scripts/` — container build, host packages, upstream sync, and toolchain verification.
- `targets/` — the glibc target config, component versions, and local patches.
- `tests/` — contract tests for config, scripts, upstream sync, and release publication.
- `.github/workflows/` — scheduled and manual release workflow.

## License

This repository does not declare one license for the combined tree. There is no top-level `LICENSE` file that covers the wrapper scripts and target files.

crosstool-NG is covered by its own `COPYING` terms and file-specific exceptions. GCC, glibc, binutils, the Linux headers, mold, and their dependencies keep their upstream licenses. Publishing them in one archive does not replace those terms.
