# Upgrading and maintaining this repo

Everything learned while getting Immich to build and run natively on
aarch64-darwin. Read this before changing `immich-version` or `nix/`.

---

## 0. Read upstream first — this document goes stale

> **Findings here were verified on 2026-09-03 against Immich v3.1.0, macOS
> 25.5.0 (Apple Silicon), nixpkgs `nixos-unstable` @ 2026-08-31. Immich moves
> fast. Treat everything below as a starting point and a record of *why*
> decisions were made — not as current fact.**

**Always re-derive the specifics from upstream.** During the initial work,
three confident conclusions turned out to be wrong or version-specific:

| Believed | Actually |
| --- | --- |
| Immich doesn't need `insightface` | True in 3.2, **false in 3.1.0** — read the tag you're building |
| sharp needs libvips ≥ 8.18.3 | True for sharp 0.35.3 (3.2), **not** 0.34.5 (3.1.0) |
| libvips 8.18 breaks thumbnails (per nixpkgs) | **Contradicted** — Immich v3.1.0 officially ships libvips 8.18.4 (§2.1) |

Each mistake came from trusting a secondary source (nixpkgs' package, a stale
checkout) instead of the tag being built.

### Where to look

| Question | Authoritative source |
| --- | --- |
| How is the server built? | [`server/Dockerfile`](https://github.com/immich-app/immich/blob/main/server/Dockerfile) in immich |
| How is ML built? | [`machine-learning/Dockerfile`](https://github.com/immich-app/immich/blob/main/machine-learning/Dockerfile) |
| **Which native library versions?** | [**immich-app/base-images**](https://github.com/immich-app/base-images) — `server/sources/*.json` |
| Build tool versions | `mise.toml` + `mise.lock` in immich |
| Plugin build steps | `mise.toml` → `[tasks.plugins]` |
| Runtime paths | `server/src/repositories/config.repository.ts` (`resourcePaths`) |
| Env vars (code) | `server/src/dtos/env.dto.ts` |
| Env vars (prose) | [docs.immich.app/install/environment-variables](https://docs.immich.app/install/environment-variables) |
| Deployment shape, PG image | [docs.immich.app/install/docker-compose](https://docs.immich.app/install/docker-compose/), `docker/docker-compose.yml` |
| Release/breaking changes | [Immich releases](https://github.com/immich-app/immich/releases) |

Read the source **at the tag you are building**, not `main`:

```bash
git -C work/immich show v3.1.0:server/Dockerfile
```

`scripts/show-upstream-pins.sh <tag>` automates most of this.

### Cross-checking against nixpkgs

nixpkgs' [`immich` package](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/im/immich/package.nix)
is a **useful but secondary** reference. It solves the same problems, so its
`buildInputs` are a good checklist. But its dependency list drifts from
upstream's, its comments describe the Immich version *it* packages, and some
of its pins are workarounds for how nixpkgs builds things rather than Immich
requirements. Verify anything you take from it.

---

## 1. Why the repo is shaped this way

Immich is built **from source using upstream's own tooling** (`pnpm`, `uv`).
Nix supplies only the toolchain, native libraries, and two pinned data/binary
artifacts. Immich is *not* packaged as a Nix derivation.

That is a deliberate reversal of the obvious approach. Two alternatives were
tried and rejected:

### Rejected: Docker / docker-compose (upstream's recommendation)

Works, but needs a Linux VM on macOS. The virtualisation and filesystem
overhead was the reason for going native in the first place.

### Rejected: nixpkgs' `immich` derivation (+ a patched fork)

This is what the predecessor repo did — a forked nixpkgs with Darwin patches,
rebased on each upgrade. It collapsed on Immich 3.x for reasons that are
**structural, not incidental**:

1. **`extism-js-core` is marked `broken` on Darwin in nixpkgs.**
   Immich 3.x compiles a core plugin to WASM with `extism-js`, so this blocks
   the build outright. The failure is not the wasm cross-compile — it is the
   *host-side* build script for `rquickjs-sys` failing to link:

   ```
   ld: library not found for -liconv
   error: could not compile `rquickjs-sys` (build script)
   ```

   nixpkgs sets `broken = stdenv.buildPlatform.isDarwin` and references a
   failed fix attempt (NixOS/nixpkgs#523442).

2. **Nix-built `onnxruntime` has no CoreML execution provider**, so ML runs
   CPU-only. Upstream's PyPI wheel ships CoreML — a real hardware-acceleration
   difference on Apple Silicon.

Plus ongoing costs: `pnpmDeps` hashes to re-derive per version, a Python
package set to keep working, and a nixpkgs fork to rebase. During the attempt,
nixpkgs' own `insightface` 1.0.1 also failed to build for an unrelated reason
(`FileNotFoundError: 'which'` in its PEP 517 backend).

**Consequence of the current approach:** builds need network access and are not
hermetic. Reproducibility comes from pinned versions and checksums, not from
the Nix sandbox. Accepted trade for a personal deployment.

---

## 2. Pins that must be kept in sync

Run `scripts/show-upstream-pins.sh <tag>` to read most of these out of any
Immich tag.

| Pin | Lives in | Upstream source of truth | Breaks if wrong |
| --- | --- | --- | --- |
| Immich version | `immich-version` | — | — |
| **libvips** | `nix/shell.nix` (`vips_8_17`) | sharp's `config.libvips` (floor) + base-images (what upstream ships) | **Build fails, or silently wrong runtime** — §5.1 |
| `extism-js` version + sha256 | `nix/extism-js.nix` | `mise.lock`, `github:extism/js-pdk` | Plugin build fails |
| Node major | `nix/shell.nix` (`nodejs_24`) | `mise.toml` | Build errors |
| pnpm major | `nix/shell.nix` (`pnpm_11`) | `mise.toml` / `packageManager` | §5.6 |
| Python | `nix/shell.nix` (`python312`) | `machine-learning/pyproject.toml` + ML Dockerfile | `uv sync` fails |
| imagemagick, libheif, libraw | `nix/shell.nix` | **base-images** `server/sources/*.json` | Format support gaps |
| ffmpeg | `nix/shell.nix` (`jellyfin-ffmpeg`) | base-images `server/packages/ffmpeg.json` | Transcoding issues |
| PostgreSQL major | `nix/shell.nix` (`postgresql_17`) | — (your existing cluster) | **Cluster won't start** — §6.1 |
| geodata snapshot | `nix/geodata.nix` | — (Internet Archive) | Reverse geocoding empty |

### 2.1 Finding the native library versions upstream actually uses

This is the part `show-upstream-pins.sh` cannot fully automate, and the part
most likely to drift.

Immich's `server/Dockerfile` builds `FROM ghcr.io/immich-app/base-server-dev:<datestamp>`.
That datestamp identifies a point in the **base-images** repo:

```bash
# 1. which base image does this tag use?
git -C work/immich show v3.1.0:server/Dockerfile | grep base-server-dev
#    -> base-server-dev:202607211135      (i.e. 2026-07-21 11:35)

# 2. what did base-images pin at that time?
curl -s "https://api.github.com/repos/immich-app/base-images/commits?path=server/sources/libvips.json&until=2026-07-21T11:35:00Z&per_page=1" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['sha'])"
# then fetch server/sources/libvips.json at that sha
```

Files to check: `server/sources/{libvips,imagemagick,libheif,libraw,libjxl,jpegli}.json`
and `server/packages/ffmpeg.json`.

`scripts/show-upstream-pins.sh` now does this resolution for you.

**Result for v3.1.0 (verified 2026-09-03), and how we compare:**

| Library | Upstream (v3.1.0) | This repo | |
| --- | --- | --- | --- |
| libvips | **8.18.4** | 8.17.3 | older — see §2.2 |
| imagemagick | 7.1.2-21 | 7.1.2-29 | newer |
| libheif | 1.21.2 | 1.23.1 | newer |
| libraw | 0.22.1 | 0.22.1 | match |
| jellyfin-ffmpeg | 7.1.4-3 | 7.1.4-3 | match |
| libjxl | 0.11.2 | (via nixpkgs vips) | JXL verified working |

> Note how much this differs from base-images `main` (libvips 8.18.5, libheif
> 1.23.2, libraw 0.22.2-1, libjxl 0.12.0). **Always resolve by datestamp** —
> reading `main` gives you the versions for Immich `main`, not your tag. This
> exact mistake was made while first writing this document.

### 2.2 Known divergence from upstream — libvips

`nix/shell.nix` currently supplies **libvips 8.17.3** (`vips_8_17`, with
`-Dtiff=disabled`), inherited from nixpkgs' Immich package and its comment
`# thumbnail generation fails with vips 8.18`.

**That comment is contradicted by upstream**, which ships v3.1.0 against
libvips 8.18.4. sharp 0.34.5 requires only `>=8.17.3`, so both satisfy the
gate — but our combination is *not* the one upstream tests.

It works (verified: HEIF, JXL and WebP all functional, thumbnails generated).
Left as-is because it is proven here, but:

- Treat nixpkgs' 8.18 warning as **unverified and probably nixpkgs-specific**.
- Moving to `vips` (8.18.x) to match upstream is a reasonable follow-up, and is
  required anyway for Immich 3.2 (sharp 0.35.3 needs `>=8.18.3`).
- `-Dtiff=disabled` is a separate nixpkgs workaround for raw thumbnails failing
  with `tiff2vips: samples_per_pixel not a whole number of bytes`. Also
  unverified against current upstream; test raw photos if you change it.

Other libraries diverge by patch level in the *other* direction — we take
nixpkgs defaults, which are mostly newer than upstream's pins (§2.1). No
problems observed. If a specific image format misbehaves, compare against
base-images first.

---

## 3. Upgrade procedure

```bash
# 1. See what the new tag requires
nix develop --command scripts/show-upstream-pins.sh v3.2.0

# 2. Check native libraries against base-images for that tag (§2.1)

# 3. Read the release notes for breaking changes
#    https://github.com/immich-app/immich/releases

# 4. Compare against nix/shell.nix and nix/extism-js.nix; edit as needed

# 5. Bump the version pin
echo v3.2.0 > immich-version

# 6. Build
nix develop --command scripts/build.sh

# 7. Verify (§4) BEFORE pointing at real data
nix develop --command scripts/immich.sh start
```

`build.sh` re-checks out the pinned tag but preserves `node_modules`
(`git clean -e node_modules`). If a build fails in a way that smells like stale
dependencies, delete `work/immich` entirely.

### Known upcoming change: Immich 3.2

Verified by running the pins script against `v3.2.0-rc.2` (2026-09-03):

| | v3.1.0 | v3.2.0-rc.2 |
| --- | --- | --- |
| sharp | 0.34.5 | 0.35.3 |
| **required libvips** | **>=8.17.3** | **>=8.18.3** |
| extism-js | 1.6.0 | **1.7.0** (new sha256) |
| pnpm | 11.13.1 | 11.22.0 |
| insightface | required | **dropped** |

So 3.2 needs `vips_8_17` → `vips` (8.18.x) in `nix/shell.nix`, plus a new
`extism-js` version and checksum. Re-verify against the real tag when it ships —
release candidates change.

---

## 4. Verification checklist

After any upgrade, confirm all of these. Each has caught a real problem.

```bash
# libvips actually linked (NOT sharp's bundled copy -- see §5.1)
cd .local/immich-app/server && node -p 'require("sharp").versions.vips'
# expect the version from nix/shell.nix, e.g. 8.17.3

# image formats present
node -p 'const s=require("sharp");[!!s.format.heif,!!s.format.jxl,!!s.format.webp].join()'
# expect: true,true,true

# CoreML available (Apple Silicon)
.local/immich-app/machine-learning/.venv/bin/python \
  -c 'import onnxruntime; print(onnxruntime.get_available_providers())'
# expect CoreMLExecutionProvider first

# server reports the right version
curl -s localhost:2283/api/server/version        # {"major":3,"minor":1,...}

# web UI is served
curl -so /dev/null -w '%{http_code}\n' localhost:2283/     # 200

# ML answers
curl -s localhost:3003/ping                      # pong

# THE CORE PLUGIN LOADED -- this is the one that regresses silently
grep -i 'Imported plugin' .local/immich-run/log/server.log
# expect: Imported plugin immich-plugin-core@X (N methods)
```

The plugin check matters most: if the WASM build fails, Immich **still starts
normally** and only logs a warning (`importFolder` swallows errors). You lose
workflow templates — smart albums, screenshot archiving — with no other signal.

Beyond these, exercise a real photo: upload one, confirm a thumbnail is
generated, and confirm face detection runs. The checks above prove the
components load, not that image processing is correct end to end.

Benign log lines, safe to ignore: `ExperimentalWarning: WASI`, `Table
smart_search does not exist` (new instance only), `Unsupported route path:
"/api/*"` (upstream path-to-regexp deprecation), `Failed to read
.../build-lock.json` if that file is absent.

---

## 5. Failure modes and their causes

### 5.1 sharp uses the wrong libvips — silently

**The most dangerous failure in this repo**, because nothing errors.

`sharp` ships prebuilt binaries (`@img/sharp-darwin-arm64` +
`@img/sharp-libvips-darwin-arm64`) as **optional dependencies**, bundling their
own libvips. If those get installed, sharp uses them and ignores the Nix one.
Observed: sharp reporting vips **8.18.3** while `nix/shell.nix` supplied 8.17.3.

Two things must both hold:

- `--no-optional` on install/deploy, keeping the prebuilts out of the tree
- `SHARP_FORCE_GLOBAL_LIBVIPS=1` (set by `nix/shell.nix`), making the source
  build use the system libvips

`scripts/build.sh` does both and asserts the result. **Do not remove either.**
Upstream does the same in `server/Dockerfile` — check there if the mechanism
changes.

Note `npm install --build-from-source` does *not* work — npm reports
`Unknown cli config "--build-from-source"` and installs the prebuilt anyway.

If it fails to compile with:

```
error: "libvips version 8.18.3+ is required"
```

then the vips in `nix/shell.nix` is older than sharp's `config.libvips`. Get
the required range with `npm view sharp@<version> config.libvips`.

Building sharp also needs `node-addon-api` and `node-gyp`. In a bare `npm`
project you must add them explicitly (`sharp: Please add node-addon-api to your
dependencies`); inside Immich's pnpm workspace they resolve automatically.

### 5.2 extism-js / the WASM plugin

`nix/extism-js.nix` fetches upstream's release binary rather than building from
source, because nixpkgs' `extism-js-core` is broken on Darwin (§1). Immich does
the same thing via `mise`, so this matches upstream's own build.

The binary self-reports `extism-js 1.5.1` regardless of actual version — an
upstream quirk, not a wrong download. (nixpkgs patches the same string:
`--replace-fail '1.5.1' '${version}'`.) Trust the URL, not `--version`.

If the plugin build fails after an upgrade, re-copy the version **and sha256**
from the new tag's `mise.lock`. If nixpkgs ever unbreaks `extism-js-core` on
Darwin, switching to it would remove a prebuilt binary from the closure.

### 5.3 PostgreSQL major version mismatch

PostgreSQL refuses to start a data directory created by a different major
version. nixpkgs' default `postgresql` moved 17 → 18 between the pinned
nixpkgs revisions, which would have silently broken an existing cluster.

`nix/shell.nix` therefore pins `postgresql_17` explicitly. See §6.1.

Note upstream's compose file uses its own Postgres image
(`ghcr.io/immich-app/postgres:14-vectorchord...` as of 3.1.0), so upstream's
major version is not a constraint on ours — but check
[docs.immich.app](https://docs.immich.app/install/docker-compose/) for the
minimum Immich supports.

### 5.4 `insightface` — depends on the Immich version

- v3.1.0: **required** (`insightface>=0.7.3,<2.0`), installs cleanly as a wheel
- v3.2.0-rc: **dropped** — vendored into `immich_ml/models/facial_recognition/_ops.py`

Only a string enum (`INSIGHTFACE = "insightface"`) and an attribution comment
remain in 3.2. Do not infer the dependency from a grep of the source tree —
read `machine-learning/pyproject.toml` at the tag.

Via `uv` this is a non-issue either way. It only mattered for the nixpkgs
approach, where the derivation needed `mxnet` patched out and then failed on a
missing `which`.

### 5.5 `HF_HUB_DISABLE_XET=1`

Set by `scripts/immich.sh` for the ML service. HuggingFace's xet transfer
backend is unreliable on Darwin; without this, model downloads can hang. Carried
over from the predecessor repo, where it was needed. Worth re-testing
occasionally — it may become unnecessary.

### 5.6 pnpm self-switches version

Immich's `package.json` has `packageManager: pnpm@<version>`, and pnpm 10+
honours it by default (`manage-package-manager-versions`). Observed: the shell
provided pnpm 11.22.0, but builds ran under 11.13.1, downloaded on demand.

This is **desirable** — the JS build matches upstream exactly — but it means:
- builds need network for the pnpm download
- `pnpm_11` in `nix/shell.nix` only needs to be the right *major*

### 5.7 Nix `revCount` error with a shallow git input

Only relevant if pointing the flake at a local nixpkgs checkout:

```
error: '/path/to/nixpkgs' is a shallow Git repository, so 'revCount' is not available
```

Fix by appending `?shallow=1` to the flake input URL. Not an issue with the
current `github:` input.

### 5.8 Python version

`nix/shell.nix` uses `python312`; `pyproject.toml` allows `>=3.11,<4.0`.
Upstream's CPU image builds on **python 3.11**. Divergence has caused no
problems, but if a wheel fails to resolve, matching upstream's minor version is
the first thing to try.

---

## 6. Pointing at real data

Defaults keep everything in `.local/`. Switching to a real install is
deliberate and **not fully reversible**.

### 6.1 Check the PostgreSQL major version first

```bash
cat /path/to/pgdata/PG_VERSION      # must match postgresql_17 in nix/shell.nix
```

If they differ, either pin the matching `postgresql_NN` in `nix/shell.nix`, or
run `pg_upgrade` deliberately. Do not just try to start it.

### 6.2 Back up before first start

Immich runs **irreversible schema migrations** on first start of a new version.
With the cluster stopped, a cold copy is sufficient:

```bash
cp -Rp /path/to/pgdata ~/immich-backups/postgres-pre-<version>
```

macOS metadata dirs (`.fseventsd`, `.Spotlight-V100`) will fail to copy on
volume roots — that is harmless, they are not part of the cluster. Verify by
comparing file counts excluding those paths.

Check the release notes for migration guidance before large version jumps, and
skipping major versions is generally not supported — upgrade through them.

### 6.3 Then

```bash
export IMMICH_PGDATA=/path/to/pgdata
export IMMICH_MEDIA_DIR=/path/to/media
nix develop --command scripts/immich.sh start
```

`DB_VECTOR_EXTENSION=pgvector` remains valid in 3.x (`server/src/dtos/env.dto.ts`
accepts `pgvector | vectorchord`), so a pgvector-based cluster carries over.
Upstream now defaults to VectorChord — check the docs if search behaves oddly.

---

## 7. Traps when investigating

- **Check which tag you are reading.** `work/immich` may sit on any tag, and a
  stray checkout of a different version caused two wrong conclusions during the
  initial work (insightface's presence, and sharp's libvips requirement). Prefer
  `git show <tag>:<path>` over reading the working tree.
- **nixpkgs is a secondary source.** See §0.
- **base-images is a separate repo on its own release cadence.** Its `main`
  reflects Immich `main`, not the tag you are building. Resolve via the base
  image datestamp (§2.1).
- **`work/immich`'s `origin` may not be GitHub** if it was cloned from a local
  mirror. The scripts fetch tags from `$IMMICH_UPSTREAM` explicitly.
- **Release candidates are not releases.** `v3.2.0-rc.2` figures may differ from
  `v3.2.0`.

---

## 8. Reference: runtime layout

Under `IMMICH_BUILD_DATA` (see `resourcePaths` in `config.repository.ts`):

```
build/
  www/                                   web build
  plugins/immich-plugin-core/            dist/plugin.wasm + manifest.json
  geodata/                               cities500.txt, admin1CodesASCII.txt,
                                         admin2Codes.txt, geodata-date.txt,
                                         ne_10m_admin_0_countries.geojson
  build-lock.json                        optional; version-display fallback only
```

Prior art for native installs: [arter97/immich-native](https://github.com/arter97/immich-native)
(Linux, systemd), [4v3ngR/immich-native-macos](https://github.com/4v3ngR/immich-native-macos)
(macOS, Homebrew + full Xcode, no hardware acceleration). Both are useful
cross-checks when a build step stops working.
