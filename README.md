# immich-local-nix for macOS and Linux

[Immich](https://immich.app) built and run natively with Nix, without Docker.
Apple Silicon macOS is the primary target; Linux support is experimental but
has been verified end to end. GPU-accelerated machine learning is supported on
Apple Silicon through CoreML.

This project provides a low-complexity, single-host deployment designed for
macOS and also verified on Linux. Nix supplies the build toolchain, native
libraries, PostgreSQL, and Valkey, while Immich is built from its pinned
upstream source with its own `pnpm` and `uv` workflows. Application data,
runtime state, and build outputs remain inside the repository by default.

This is an independent deployment method, not an official Immich distribution.
Upstream recommends Docker Compose for production installations.

## Design

Packaging Immich as a conventional Nix derivation would require maintaining
`pnpmDeps` hashes and a separate Python package set. It also encounters two
Darwin-specific limitations: nixpkgs marks `extism-js-core` as broken on
Darwin, and its ONNX Runtime build does not include the CoreML execution
provider. Building with upstream's package managers avoids both constraints,
at the cost of network-dependent, non-hermetic builds.

On Apple Silicon, the local machine-learning patch selects a working execution
route for each model family. In testing on an M1 Pro, smart-search indexing
reached 32–37 images per second with CoreML with the `immich-app/ViT-SO400M-16-SigLIP2-384__webli` model, compared with 3-10 images per
second on CPU. With the smaller `ViT-B-16-SigLIP2__webli` model, you can get ~120 images per second on M1 Pro. The patch also avoids an ONNX Runtime issue that can expand the
SO400M text model into a 6.5 GB CoreML program. See
[UPGRADING.md](UPGRADING.md#59-coreml-on-apple-silicon--model-specific-routing)
for the implementation rationale and measurements.

## Requirements

- [Nix](https://nixos.org/download/) with flakes enabled
- Apple Silicon macOS (supported), or aarch64/x86_64 Linux (experimental)

macOS does not require Homebrew or Xcode. System installations of Node.js and
Python are not required on either platform. Your system is not polluted.

### Installing Nix

For macOS, use the official multi-user installer:

```bash
curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install | sh
```

<details>
<summary>Linux installation</summary>

For Linux systems using systemd with SELinux disabled, use the recommended
multi-user installation:

```bash
curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install | sh -s -- --daemon
```

</details>

After installation, start a new shell and enable the Nix command interface and
flakes with the following commands:

```bash
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```

See the official [Nix download and installation
instructions](https://nixos.org/download/) for other configurations,
single-user installation, and troubleshooting.

## Installation

The repository contains pinned Immich and base-images submodules and must be
cloned recursively. A shallow clone keeps the initial download small:

```bash
git clone --depth 1 --recurse-submodules --shallow-submodules \
  https://github.com/axonasif/immich-local-nix.git
cd immich-local-nix
```



Build and start the complete stack:

```bash
nix develop
scripts/build.sh # only once
scripts/immich.sh
```

The web application is then available at <http://0.0.0.0:2283>. The initial
build downloads the nixpkgs closure and application dependencies, then compiles
`sharp` against the Nix-provided libvips. Subsequent builds reuse downloaded
dependencies and are substantially faster.

By default, the assembled application is stored in `.local/immich-app`, while
PostgreSQL, Valkey, logs, cached models, and media are stored in
`.local/immich-run`. No files are installed system-wide. Consequently, removing
the checkout also removes all data stored in these default locations.

## Operation

```bash
scripts/immich.sh status
scripts/immich.sh logs
scripts/immich.sh stop
scripts/immich.sh restart
```

The upstream CLI and administration tool are included in the build:

```bash
export PATH="$PWD/.local/immich-app/bin:$PATH"
immich --help
immich-admin --help
```

## Data locations and configuration

The default paths isolate a fresh checkout from any existing Immich
installation. To use an existing PostgreSQL cluster or media library, define
the relevant paths before starting the stack:

```bash
export IMMICH_PGDATA=/path/to/postgres
export IMMICH_MEDIA_DIR=/path/to/media
```

> [!WARNING]
> Immich runs irreversible schema migrations on first start. Create a database
> backup before using an existing cluster. The cluster's PostgreSQL major
> version must match `nix/shell.nix`, which currently provides PostgreSQL 17.

The runner supports the following configuration variables:

| Variable | Purpose | Default |
| --- | --- | --- |
| `IMMICH_PREFIX` | Assembled application path | `.local/immich-app` |
| `IMMICH_STATE_DIR` | Runtime state root | `.local/immich-run` |
| `IMMICH_PGDATA` | PostgreSQL data directory | `$IMMICH_STATE_DIR/postgres` |
| `IMMICH_PGSOCKET_DIR` | PostgreSQL Unix-socket directory | `$TMPDIR/immich-local-pgsocket` |
| `IMMICH_MEDIA_DIR` | Immich media directory | `$IMMICH_STATE_DIR/media` |
| `IMMICH_CACHE_DIR` | Machine-learning model cache | `$IMMICH_MEDIA_DIR/cache` |
| `IMMICH_HTTP_HOST`, `IMMICH_HTTP_PORT` | Server bind address and port | `0.0.0.0`, `2283` |
| `IMMICH_ML_HOST`, `IMMICH_ML_PORT` | Machine-learning bind address and port | `127.0.0.1`, `3003` |
| `IMMICH_PG_PORT` | PostgreSQL port | `5433` |
| `IMMICH_REDIS_HOST`, `IMMICH_REDIS_PORT` | Valkey bind address and port | `127.0.0.1`, `6380` |
| `IMMICH_DB_STORAGE_TYPE` | PostgreSQL tuning profile (`SSD` or `HDD`) | `SSD` |
| `IMMICH_DB_VECTOR_EXTENSION` | Force `pgvector` or `vectorchord`; unset allows Immich to auto-select VectorChord | unset |
| `IMMICH_ML_WORKERS` | Machine-learning worker count | `1` |
| `IMMICH_ML_WORKER_TIMEOUT` | Gunicorn timeout when the CoreML execution path is disabled | `300` seconds |
| `MACHINE_LEARNING_DISABLE_COREML` | Set to `1` to disable CoreML and run machine learning on CPU | unset |

## Upstream compatibility

The current revision targets **Immich v3.1.0** and was last verified against
that release on macOS on **2026-09-03** and Linux on **2026-09-04**. The status
terms distinguish components built directly from upstream (“Aligned”), native
or platform-specific implementations intended to preserve the same feature
behavior (“Adapted”), and incomplete operational parity (“Partial”). This is a
compatibility map, not a claim that the project reproduces every Docker-specific
behavior or an exhaustive test matrix.

| Area | Status | Scope and differences |
| --- | --- | --- |
| Server, API, and background workers | Aligned | Built from the pinned Immich source and run through the upstream `node dist/main` entry point. |
| Web application | Aligned | Built from the pinned Immich source and served by the Immich server. |
| Machine learning | Adapted | Uses upstream Python dependencies and CPU wheels. On Apple Silicon, a local patch routes smart search, face recognition, and OCR through model-specific CoreML representations; the SO400M text encoder remains on CPU. CoreML can be disabled. |
| Core WASM plugin | Aligned | Built from upstream source with the `extism-js` release and checksum pinned by Immich. Plugin loading must be checked after upgrades because failure is otherwise non-fatal. |
| Immich CLI and `immich-admin` | Aligned | Built from the pinned upstream source and installed with local wrappers. |
| Image and video processing | Adapted | Uses the upstream libvips build choices and loader-priority patch, plus Jellyfin FFmpeg and the required native codecs from Nix. Some library patch versions may be newer than the upstream image. |
| Reverse geocoding | Aligned | Uses the geodata payload extracted from the exact production base image pinned by the Immich release. |
| PostgreSQL and vector search | Adapted | Runs PostgreSQL 17 with pgvector and VectorChord. Upstream database settings are translated where applicable; the macOS `effective_io_concurrency` exception is retained. |
| Existing pgvector databases | Supported | Immich can retain pgvector or migrate it to VectorChord. Set `IMMICH_DB_VECTOR_EXTENSION=pgvector` to postpone migration. |
| Legacy pgvecto.rs (`vectors`) databases | Migration required | pgvecto.rs is not packaged. Such databases must follow Immich's standalone PostgreSQL migration procedure before use. |
| Valkey | Adapted | Uses the Nix-provided Valkey package with Immich's existing Redis environment contract. |
| Scheduled database backups | Adapted | Immich's Debian-specific PostgreSQL binary path is patched to use the matching Nix-provided tools on `PATH`. |
| Process lifecycle and health monitoring | Partial | The runner provides start, stop, restart, status, startup readiness checks, and logs. Docker restart policies and periodic container health checks are not reproduced. |

Platform support is narrower than the systems currently exposed by `flake.nix`:

| Platform | Status | Notes |
| --- | --- | --- |
| Apple Silicon macOS (`aarch64-darwin`) | Supported | Primary and verified target; includes CoreML acceleration. |
| Intel macOS (`x86_64-darwin`) | Not currently supported | No matching `extism-js` release artifact is pinned. |
| Linux (`aarch64-linux`, `x86_64-linux`) | Experimental (verified) | The standard installation flow above has been completed manually end to end on Linux. The flake and upstream-pinned `extism-js` artifacts cover both architectures; machine learning uses ONNX Runtime CPU. Upstream containers remain the recommended Linux deployment. |

Linux remains experimental because its platform and distribution coverage is
not exhaustive. New environments should use a fresh, disposable database first
and complete the verification checklist in
[UPGRADING.md](UPGRADING.md#4-verification-checklist). Reports should include
the architecture, Linux distribution, Nix version, and the failed command or
relevant service log.

The detailed alignment procedure, known divergences, and verification checklist
are maintained in [UPGRADING.md](UPGRADING.md). Compatibility should be
re-established whenever `immich-version`, `flake.lock`, or native library pins
change.

## Project structure

| Path | Purpose |
| --- | --- |
| `LICENSE` | GNU Affero General Public License v3.0 |
| `UPGRADING.md` | Version-alignment process, failure modes, and verification checklist |
| `immich-version` | Authoritative Immich release tag |
| `flake.nix`, `flake.lock` | Pinned nixpkgs input and development-shell outputs |
| `nix/shell.nix` | Toolchain, services, and native libraries |
| `nix/extism-js.nix` | Upstream `extism-js` release artifact used to build the WASM plugin |
| `nix/geodata.nix` | Fixed-output reverse-geocoding data from the upstream image |
| `nix/patches/` | libvips patch vendored from upstream base-images |
| `scripts/build.sh` | Source build and runtime-tree assembly |
| `scripts/immich.sh` | Native service runner |
| `scripts/patch-postgres-bin-path.py` | PostgreSQL backup-command path adaptation |
| `scripts/patch-coreml.py` | Apple Silicon CoreML routing and CPU fallback |
| `scripts/show-upstream-pins.sh` | Comparison of an Immich release with repository pins |
| `upstream/immich` | Pinned Immich source submodule used for the build |
| `upstream/base-images` | Pinned upstream native-library reference submodule |
| `.local/immich-app` | Generated application tree (ignored by Git) |
| `.local/immich-run` | Generated runtime state (ignored by Git) |

## Upgrading Immich

Read [UPGRADING.md](UPGRADING.md) before changing the version. An upgrade can
change the Node.js, pnpm, Python, `extism-js`, libvips, media-library, database,
and service-runtime contracts in addition to the Immich source tag.

Begin by comparing the target release with the repository's pins:

```bash
nix develop --command scripts/show-upstream-pins.sh v3.2.0
```

After updating `nix/` and `immich-version`, rebuild and complete the verification
checklist in `UPGRADING.md` against both a fresh database and a disposable copy
of the previous version's database. `scripts/build.sh` checks out the selected
tag in `upstream/immich`; the resulting submodule pointer must be recorded as
part of a version update.

Maintenance findings in `UPGRADING.md` are version-specific. The source tree,
base-images revision, release notes, and [official Immich
documentation](https://docs.immich.app) remain authoritative.

## License

This project is licensed under the [GNU Affero General Public License v3.0
only](LICENSE) (`AGPL-3.0-only`). Immich, base-images, and other third-party
components retain their respective copyrights and licenses.
