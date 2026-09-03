# immich-native-nix

Runs [Immich](https://immich.app) natively on macOS (Apple Silicon) and Linux —
no Docker, no VM.

Nix supplies the toolchain and native libraries; Immich itself is built from
source with its own `pnpm` and `uv`. That split is deliberate: packaging Immich
as a full Nix derivation means maintaining `pnpmDeps` hashes and a Python
package set, and on Darwin it hits two hard walls — `extism-js-core` is marked
broken (so the WASM plugin can't build at all), and the Nix-built `onnxruntime`
has no CoreML support.

Building from source with upstream's own tooling avoids both, and the machine
learning component gets **CoreML acceleration** from the upstream wheels.

## Requirements

- Nix with flakes enabled
- macOS on Apple Silicon, or Linux

## Usage

```bash
nix develop                # enter the toolchain shell
scripts/build.sh           # build immich into .local/immich-app
scripts/immich.sh start    # start postgres, redis, ML and the server
```

Then open <http://127.0.0.1:2283>.

Other commands:

```bash
scripts/immich.sh status
scripts/immich.sh logs
scripts/immich.sh stop
scripts/immich.sh restart
```

## Layout

| Path | Contents |
| --- | --- |
| `immich-version` | the Immich tag to build — the single version pin |
| `nix/shell.nix` | toolchain and native libraries |
| `nix/extism-js.nix` | upstream `extism-js` release binary (builds the WASM plugin) |
| `nix/geodata.nix` | reverse-geocoding data, as a fixed-output derivation |
| `work/immich` | Immich source checkout (gitignored) |
| `.local/immich-app` | built application (gitignored) |
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
`IMMICH_DB_VECTOR_EXTENSION`, `IMMICH_ML_WORKERS`.

## Upgrading Immich

Change the tag in `immich-version`, then:

```bash
nix develop --command scripts/build.sh
```

Two things to check when moving to a new release:

- **`sharp` and libvips.** Immich pins a `sharp` version that requires a
  specific libvips; `nix/shell.nix` must match. v3.1.0 uses sharp 0.34.5
  (libvips 8.17). Immich 3.2 moves to sharp 0.35.3, which requires libvips
  ≥ 8.18.3 — the pin has to move with it.
- **`extism-js`.** `nix/extism-js.nix` pins a version and checksum copied from
  Immich's own `mise.lock`. Re-copy them from the new tag.
