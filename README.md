# immich-native-nix

Run [Immich](https://immich.app) natively on macOS — no Docker, no VM.

**The goal is low complexity and low effort.** Immich's own recommendation is
docker-compose, which on macOS means running a Linux VM and paying its
virtualisation and filesystem overhead. This gets you a working Immich on the
Mac itself with a handful of commands, and keeps the moving parts few enough
that upgrading is editing one version file and rebuilding.

Nix supplies the toolchain and native libraries; Immich is built from source
with its own `pnpm` and `uv`. That split is deliberate — packaging Immich as a
full Nix derivation means maintaining `pnpmDeps` hashes and a Python package
set, and on Darwin it hits two walls: nixpkgs marks `extism-js-core` broken (so
Immich 3.x's WASM plugin cannot build at all), and Nix-built `onnxruntime` has
no CoreML support.

Building with upstream's own tooling avoids both, and machine learning gets
**CoreML acceleration** from the upstream wheels.

Also works on Linux, though there you may as well use upstream's containers.

## Requirements

- [Nix](https://nixos.org/download/) with flakes enabled
- macOS on Apple Silicon (or Linux)

Nothing else — no Homebrew, no Xcode, no Node or Python on your system.

## Setup

This repo uses git submodules (a pinned checkout of Immich, which is what gets
built, plus upstream's base-images for reference), so **clone recursively**:

```bash
git clone --recurse-submodules https://github.com/<you>/immich-native-nix
cd immich-native-nix
```

Already cloned without `--recurse-submodules`? Fetch them after the fact:

```bash
git submodule update --init --depth 1
```

Then build and run:

```bash
nix develop                # enter the toolchain shell
scripts/build.sh           # build immich into .local/immich-app  (slow first time)
scripts/immich.sh start    # start postgres, redis, ML and the server
```

Then open <http://127.0.0.1:2283> and create your admin account.

The first build downloads a lot (nixpkgs closure, pnpm and Python deps) and
compiles `sharp` against the Nix libvips; later builds are much faster.

Everything lands under `.local/` — the built app in `.local/immich-app`, and
postgres, redis, logs and media in `.local/immich-run`. Nothing is installed
system-wide, and removing the repo removes the install.

## Day-to-day

```bash
scripts/immich.sh status
scripts/immich.sh logs
scripts/immich.sh stop
scripts/immich.sh restart
```

The Immich CLI and admin tool are built too:

```bash
export PATH="$PWD/.local/immich-app/bin:$PATH"
immich --help          # upload CLI
immich-admin --help    # list-users, grant-admin, reset passwords, ...
```

## Layout

| Path | Contents |
| --- | --- |
| `UPGRADING.md` | maintenance knowledge: pins, failure modes, verification |
| `immich-version` | the Immich tag to build — the single version pin |
| `nix/shell.nix` | toolchain and native libraries |
| `nix/extism-js.nix` | upstream `extism-js` release binary (builds the WASM plugin) |
| `nix/geodata.nix` | reverse-geocoding data, as a fixed-output derivation |
| `nix/patches/` | libvips patch vendored from upstream's base-images |
| `scripts/patch-postgres-bin-path.py` | drops Immich's hardcoded Debian postgres path |
| `scripts/show-upstream-pins.sh` | read every upstream pin out of an Immich tag |
| `upstream/immich` | **submodule** — Immich source; this is what gets built |
| `upstream/base-images` | **submodule** — upstream's native-library builds, for reference |
| `.local/immich-app` | built application, incl. `bin/immich` and `bin/immich-admin` (gitignored) |
| `.local/immich-run` | runtime state: postgres, redis, logs, media (gitignored) |

## Pointing at existing data

Defaults keep everything under `.local/` so a fresh checkout never touches an
existing install. To use real data, set these before starting:

```bash
export IMMICH_PGDATA=/path/to/postgres
export IMMICH_MEDIA_DIR=/path/to/media
```

> **Immich runs irreversible schema migrations on first start.** Back up the
> database before pointing this at a cluster you care about, and note that the
> cluster's PostgreSQL major version must match the one in `nix/shell.nix`
> (currently 17).

Other knobs: `IMMICH_HTTP_HOST`, `IMMICH_HTTP_PORT`, `IMMICH_ML_HOST`,
`IMMICH_ML_PORT`, `IMMICH_PG_PORT`, `IMMICH_REDIS_PORT`,
`IMMICH_DB_STORAGE_TYPE` (`SSD` by default, or `HDD`),
`IMMICH_DB_VECTOR_EXTENSION` (`vectorchord` is auto-selected; set `pgvector`
to postpone migration), `IMMICH_ML_WORKERS`.

## Upgrading Immich

**Read [UPGRADING.md](UPGRADING.md) first.** Bumping the tag alone is usually
not enough: Immich releases move `sharp` (which gates on a specific libvips
version at compile time), `extism-js`, and the toolchain versions, and each has
a counterpart in `nix/`.

Bumping the tag also moves the `upstream/immich` submodule — `scripts/build.sh`
checks it out to match `immich-version`, so commit the submodule pointer
afterwards to record it.

Start by diffing the new tag's requirements against what this repo pins:

```bash
nix develop --command scripts/show-upstream-pins.sh v3.2.0
```

That reads the pins straight out of the tag — toolchain versions from
`mise.toml`, `extism-js` from `mise.lock`, sharp's libvips requirement from
npm, and the native library versions from
[immich-app/base-images](https://github.com/immich-app/base-images), resolved
to the base image your tag actually uses.

Update `nix/` and `immich-version` accordingly, rebuild, then work through the
verification checklist in UPGRADING.md — in particular the core-plugin check,
which is the one thing that regresses **silently**.

> Findings in UPGRADING.md were verified against v3.1.0 on 2026-09-03 and will
> go stale. Always confirm against upstream — the immich repo at your tag,
> base-images, and <https://docs.immich.app>.
