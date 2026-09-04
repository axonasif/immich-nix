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
| libvips 8.18 breaks thumbnails (per nixpkgs) | **Wrong diagnosis** — Immich v3.1.0 ships 8.18.4; 8.18 just needs upstream's loader-priority patch (§2.2) |

Each mistake came from trusting a secondary source (nixpkgs' package, a stale
checkout) instead of the tag being built.

A fourth came from reading *our* config instead of upstream's build system:
`-Dspng=enabled` looked like it enabled spng, and silently did nothing, because
vips only consults spng when libpng is absent (§2.4). When a flag appears to
have no effect, read the dependency's own build logic before concluding the
feature is unavailable.

### Where to look

| Question | Authoritative source |
| --- | --- |
| How is the server built? | [`server/Dockerfile`](https://github.com/immich-app/immich/blob/main/server/Dockerfile) in immich |
| How is ML built? | [`machine-learning/Dockerfile`](https://github.com/immich-app/immich/blob/main/machine-learning/Dockerfile) |
| **Which native library versions?** | [**immich-app/base-images**](https://github.com/immich-app/base-images) — `server/sources/*.json` |
| Build tool versions | `mise.toml` + `mise.lock` in immich |
| Plugin build steps | `mise.toml` → `[tasks.plugins]` |
| Released service graph and image pins | `docker/docker-compose.yml` **at the target tag**, not `main` |
| Server command and process model | `server/Dockerfile`, `server/bin/start.sh`, `server/src/main.ts` |
| Server env vars, defaults, and paths | `server/src/dtos/env.dto.ts`, `server/src/repositories/config.repository.ts` |
| ML command and env vars | `machine-learning/Dockerfile`, `machine-learning/immich_ml/config.py` |
| Env vars (prose) | [docs.immich.app/install/environment-variables](https://docs.immich.app/install/environment-variables) |
| PostgreSQL image behavior | `base-images/postgres/{Dockerfile,immich-docker-entrypoint.sh,postgresql.*.conf,healthcheck.sh}` |
| Vector extension selection and supported versions | `server/src/constants.ts`, `server/src/repositories/database.repository.ts` |
| Release/breaking changes | [Immich releases](https://github.com/immich-app/immich/releases) |

Both upstream repos are vendored as **submodules**, pinned to the revisions this
build targets, so the reference is local and matches what we build:

| Submodule | Pinned to |
| --- | --- |
| `upstream/immich` | the tag in `immich-version` — this is also the tree that gets built |
| `upstream/base-images` | the base-images revision that tag's base image was built from (§2.1) |

Read the source **at the tag you are building**, not `main`:

```bash
git -C upstream/immich show v3.1.0:server/Dockerfile
cat upstream/base-images/server/sources/libvips.json
```

Note **nix cannot read files inside a submodule** — they are not tracked by the
parent repo, so a flake path like `./upstream/base-images/...` fails with
"not tracked by Git". Anything nix needs must be copied under `nix/`; that is
why the libvips patch is vendored there, and why `scripts/build.sh` diffs the
copy against the submodule on every build.

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
   CPU-only. Upstream's PyPI wheel ships CoreML, which is why the wheels are
   used here.

   Note this argument is weaker than it looks: on Apple Silicon the CoreML
   provider turned out to be unusable in practice — it aborts the ML worker
   mid-inference and cannot compile the larger CLIP models at all, so this
   repo ships a flag to disable it (see 5.9). The wheels are still the right
   choice, but for `extism-js` and packaging cost, not for CoreML.

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
| **libvips** (+ vendored patch) | `nix/shell.nix` (`vips`), `nix/patches/` | sharp's `config.libvips` (floor) + base-images (what upstream ships) | **Build fails, or silently wrong runtime** — §5.1 |
| `extism-js` version + sha256 | `nix/extism-js.nix` | `mise.lock`, `github:extism/js-pdk` | Plugin build fails |
| Node major | `nix/shell.nix` (`nodejs_24`) | `mise.toml` | Build errors |
| pnpm major | `nix/shell.nix` (`pnpm_11`) | `mise.toml` / `packageManager` | §5.6 |
| Python | `nix/shell.nix` (`python312`) | `machine-learning/pyproject.toml` + ML Dockerfile | `uv sync` fails |
| imagemagick, libheif, libraw | `nix/shell.nix` | **base-images** `server/sources/*.json` | Format support gaps |
| ffmpeg | `nix/shell.nix` (`jellyfin-ffmpeg`) | base-images `server/packages/ffmpeg.json` | Transcoding issues |
| PostgreSQL major | `nix/shell.nix` (`postgresql_17`) | — (your existing cluster) | **Cluster won't start** — §6.1 |
| Vector extensions | `nix/shell.nix`, `scripts/immich.sh` | Compose database image tag + server extension constants/repository | PostgreSQL won't start, or search indexes cannot migrate |
| PostgreSQL runtime profile | `scripts/immich.sh` | base-images `postgres/postgresql.{ssd,hdd}.conf` | Startup failure or poor database performance |
| Valkey major + nixpkgs package | `flake.lock`, `nix/shell.nix`, `scripts/immich.sh` | Compose cache image tag + server Redis client/config | Jobs and cache stop working |
| Service commands and env contract | `scripts/immich.sh` | Compose, Dockerfiles, entrypoints, env schemas | A service fails at startup or silently loses functionality |
| geodata image/layer + output hash | `nix/geodata.nix` | pinned `base-server-prod` image | Reverse geocoding is stale or empty |

### 2.1 Finding the native library versions upstream actually uses

This is the part `show-upstream-pins.sh` cannot fully automate, and the part
most likely to drift.

Immich's `server/Dockerfile` builds `FROM ghcr.io/immich-app/base-server-dev:<datestamp>`.
That datestamp identifies a point in the **base-images** repo:

```bash
# 1. which base image does this tag use?
git -C work/immich show v3.1.0:server/Dockerfile | grep base-server-dev
#    -> base-server-dev:202607211135      (i.e. 2026-07-21 11:35)
```

**Most reliable — the image states its own source commit.** The published image
carries `org.opencontainers.image.revision` in its OCI labels:

```bash
TOKEN=$(curl -fsSL "https://ghcr.io/token?scope=repository:immich-app/base-server-dev:pull&service=ghcr.io" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
# fetch the image index -> pick the arm64 manifest -> fetch its config blob
#   -> read .config.Labels["org.opencontainers.image.revision"]
```

For v3.1.0 that yields base-images commit `cf578f014cf7060709d7cb02427e07d18d6ace50`.
Then read `server/sources/<lib>.json` at that exact revision.

**Approximate — what `show-upstream-pins.sh` uses**, since it needs no registry
auth: treat the datestamp as a timestamp and take the last commit before it.

```bash
curl -s "https://api.github.com/repos/immich-app/base-images/commits?path=server/sources/libvips.json&until=2026-07-21T11:35:00Z&per_page=1" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['sha'])"
```

This gave identical results for v3.1.0, but it is an inference. Use the revision
label when the answer matters.

Files to check: `server/sources/{libvips,imagemagick,libheif,libraw,libjxl,jpegli}.json`
and `server/packages/ffmpeg.json`.

`scripts/show-upstream-pins.sh` now does this resolution for you.

**Result for v3.1.0 (verified 2026-09-03), and how we compare:**

| Library | Upstream (v3.1.0) | This repo | |
| --- | --- | --- | --- |
| libvips | **8.18.4** | 8.18.6 | tracks upstream — §2.2 |
| imagemagick | 7.1.2-21 | 7.1.2-29 | newer |
| libheif | 1.21.2 | 1.23.1 | newer |
| libraw | 0.22.1 | 0.22.1 | match |
| jellyfin-ffmpeg | 7.1.4-3 | 7.1.4-3 | match |
| libjxl | 0.11.2 | (via nixpkgs vips) | JXL verified working |

> Note how much this differs from base-images `main` (libvips 8.18.5, libheif
> 1.23.2, libraw 0.22.2-1, libjxl 0.12.0). **Always resolve by datestamp** —
> reading `main` gives you the versions for Immich `main`, not your tag. This
> exact mistake was made while first writing this document.

### 2.2 libvips: how it is built, and why the patch is mandatory

`nix/shell.nix` supplies **libvips 8.18.x**, built the way upstream builds it.
Read `server/sources/libvips.sh` in base-images to confirm this still matches:

```bash
meson setup build --buildtype=release --libdir=lib -Dintrospection=disabled -Dtiff=disabled
```

Two things are copied from upstream, and both matter:

**`-Dtiff=disabled`.** Not a nixpkgs quirk — upstream disables it too. vips'
tiff reader mishandles some raw files (`tiff2vips: samples_per_pixel not a whole
number of bytes`).

**`nix/patches/0001-put-other-loaders-ahead-of-dcrawload.patch`** — vendored
from base-images. **Required from libvips 8.18 onwards.** 8.18 added a
`dcrawload` loader at priority **100**, which outranks stock `jpegload` (50) and
`heifload` (0), so the RAW loader gets first refusal on ordinary JPEG and HEIC
files. HEIC being the default iPhone format, this is not a corner case. The
patch raises both to 150.

Verify after any vips change:

```bash
nix develop --command vips -l | grep -E '\((jpegload|heifload|dcrawload)\)'
# expect jpegload=150, heifload=150, dcrawload=100
```

This very likely explains nixpkgs' comment `# thumbnail generation fails with
vips 8.18` on its `vips_8_17` pin: nixpkgs does **not** apply this patch, so its
8.18 would indeed misroute image loading. The right conclusion is not "avoid
8.18" but "8.18 needs upstream's patch". Immich itself has shipped 8.18 since at
least July 2026.

#### History

This repo originally pinned `vips_8_17` by copying nixpkgs. That was wrong:
Immich v3.1.0's own image uses 8.18.4. Corrected on 2026-09-03 to track
upstream. sharp 0.34.5 accepts `>=8.17.3` so the old pin was not *broken*, just
untested by upstream — and it would have blocked Immich 3.2 (sharp 0.35.3 needs
`>=8.18.3`) anyway.

### 2.3 Version drift policy — deliberate

We take nixpkgs' versions rather than pinning upstream's exactly. Ours are
generally *newer*, not older (§2.1): vips 8.18.6 vs 8.18.4, imagemagick
7.1.2-29 vs -21, libheif 1.23.1 vs 1.21.2.

**This is accepted, not an oversight.** Pinning exactly would mean overriding
each `src` to older releases, carrying unfixed CVEs, and fighting the nixpkgs
closure for no functional gain.

The rule: **match the major/minor, allow a newer patch level.** A *minor*
divergence (e.g. vips 8.17 vs 8.18) is a real problem and must be corrected —
that is what §2.2 is about. A patch-level divergence is fine.

If a specific image format misbehaves, compare against base-images first — the
drift is the obvious suspect even though it is usually innocent.

### 2.4 Known non-alignments (investigated, deliberately not fixed)

**jpegli as the libjpeg implementation — unsupported on macOS; not attempted.**
Upstream replaces libjpeg entirely with jpegli's libjpeg-compatible shim; their
Dockerfile says so: *"the final image uses jpegli (/usr/local/lib/libjpeg.so.62)
built alongside libjxl"*. So every JPEG the official image encodes goes through
jpegli, which produces smaller files at equal quality. Ours uses libjpeg-turbo.

The shim is gated out on Apple in the source (`lib/jpegli.cmake`):

```cmake
if (JPEGXL_ENABLE_JPEGLI_LIBJPEG AND NOT APPLE AND NOT WIN32 AND NOT EMSCRIPTEN)
```

The reason is concrete: the target is linked with
`-Wl,--version-script=jpeg.version.62`, GNU ld symbol versioning, which Apple's
linker has no equivalent for. Verified by building nixpkgs' `jpegli` with
`JPEGXL_ENABLE_JPEGLI_LIBJPEG=ON` + `INSTALL_JPEGLI_LIBJPEG=ON`: it builds and
installs `cjpegli`/`djpegli`, but **no libjpeg shim and no jpeglib.h** — the
guard silently skips the target.

**This is "unsupported", not "impossible".** macOS has no symbol versioning
at all, so dropping the version script is plausibly harmless and the shim might
well build and work. What cannot be known cheaply is whether the result is
*correct*, because nobody upstream builds or tests that path — there is no
reference macOS build to compare against.

Taking it on means carrying a patch that deletes an upstream platform guard,
and validating the result ourselves: encode/decode round-trips, output compared
against `cjpegli` (which does build on macOS), and crash testing. The downside
of getting it subtly wrong is corrupted thumbnails in a photo server, possibly
not obviously.

The cost of *not* doing it is JPEG file size, not correctness. Judged not worth
the risk; revisit if upstream enables it on Apple, which would supply the
tested reference this currently lacks.

**libspng — solved; PNG goes through spng, matching upstream.**
Upstream installs only `libspng-dev`/`libspng0` and **no libpng at all**. That
is not incidental: vips treats spng strictly as a fallback
(`meson.build`, "only if libpng not found"):

```meson
png_dep = dependency('libpng', ..., required: get_option('png'))
if png_dep.found() ... png_package = png_dep endif

# only if libpng not found
if not png_package.found()
    spng_dep = dependency('spng', version: '>=0.7', required: false)
```

So **`-Dspng=enabled` alone silently does nothing** while libpng is present —
meson accepts the option and compiles `spngload.c`, but `png_package` stays
libpng and the built library never references libspng. `nix/shell.nix` therefore
passes `-Dpng=disabled` as well.

Two things to know if you touch this:

- `overrideAttrs` runs *after* `mkDerivation` applied `chooseDevOutputs` to
  `buildInputs`, so appending a bare `libspng` gives the `out` output and leaves
  `spng.pc` off the pkg-config path. Use `lib.getDev`.
- Verify with `vips --vips-config | grep 'PNG load'` — it must say
  **`PNG load/save with spng`**, not `with libpng`. The operation is still named
  `pngload` either way, so `vips -l` cannot tell you which is in use.

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

# 4. Audit scripts/immich.sh against the runtime contract (§3.1)

# 5. Compare against nix/shell.nix and nix/extism-js.nix; edit as needed

# 6. Bump the version pin
echo v3.2.0 > immich-version

# 7. Build
nix develop --command scripts/build.sh

# 8. Verify fresh and upgraded disposable data (§3.1, §4)
#    BEFORE pointing at real data
nix develop --command scripts/immich.sh start
```

`build.sh` re-checks out the pinned tag but preserves `node_modules`
(`git clean -e node_modules`). If a build fails in a way that smells like stale
dependencies, delete `work/immich` entirely.

### 3.1 Audit `scripts/immich.sh`

Upstream's [upgrade guide](upstream/immich/docs/docs/install/upgrading.md) is
an operator guide for the published containers. It deliberately does not
explain what those containers changed internally. `scripts/immich.sh` is our
native translation of the release's Compose file, image entrypoints, and
health checks, so it must be reviewed separately for every Immich upgrade.

Start with a diff at the exact old and new release tags:

```bash
git -C upstream/immich diff v3.1.0..v3.2.0 -- \
  docker/docker-compose.yml docker/example.env \
  server/Dockerfile server/bin/start.sh server/src/main.ts \
  server/src/dtos/env.dto.ts server/src/repositories/config.repository.ts \
  server/src/constants.ts server/src/repositories/database.repository.ts \
  machine-learning/Dockerfile machine-learning/immich_ml/config.py
```

Also diff the old and new `upstream/base-images` revisions, especially
`postgres/` and `server/`. The Compose file warns that its version on `main`
may not match the latest release; the same warning applies to all of these
checks.

For each release, re-establish these invariants:

- **Service graph and commands.** Compare every Compose service, dependency,
  command, entrypoint, port, volume, and health check. The current `node
  dist/main` process starts both API and microservices workers; do not add old
  split worker commands unless `server/src/main.ts` changes. ML currently runs
  as `python -m immich_ml`. If upstream adds or splits a required service, the
  runner must do the same.
- **Entrypoint behavior.** Read the scripts behind each image command, not just
  the Dockerfile `CMD`. Reproduce behavior that affects correctness or
  performance, but translate Linux-only details rather than invoking them
  blindly. For example, server `start.sh` currently handles secret files,
  Linux mimalloc/library paths, and CPU-based `UV_THREADPOOL_SIZE`; these are
  not all applicable to this local macOS runner.
- **Environment and paths.** Re-check every variable passed by `start_server`
  and `start_ml` against the code schemas and defaults. In particular, preserve
  the absolute media path, build-data layout, database URL, Redis connection,
  ML URL/cache path, bind host, and port. Remove renamed variables and add new
  required ones. Do not force a value when upstream intentionally relies on
  auto-detection, as with `DB_VECTOR_EXTENSION`.
- **Database image contract.** Read the Compose database image tag and the
  base-image Dockerfile, entrypoint, SSD/HDD profiles, and health check. Keep
  `--data-checksums`, required preload libraries, search path, WAL/memory/
  autovacuum settings, and storage-specific planner settings aligned. Preserve
  the Darwin exception for `effective_io_concurrency`, which PostgreSQL
  requires to be zero because macOS lacks `posix_fadvise`.
- **PostgreSQL and extensions.** Keep the PostgreSQL major tied to the existing
  data directory, not blindly to Compose's default major. Compare Immich's
  extension preference and accepted version ranges with the Nix packages,
  preload requirements, and migration code. Immich owns `CREATE/ALTER
  EXTENSION`, index conversion, and schema migrations; the runner should only
  make the server prerequisites available and create a missing database.
- **Darwin VectorChord package.** Nixpkgs currently marks all pgrx extensions
  broken on Darwin because sandboxed PostgreSQL tests can leak shared-memory
  objects. Our override only clears that metadata guard. After a Nixpkgs or
  VectorChord update, check whether the override is still necessary, build it
  on Darwin, load `vchord`, create a `vchordrq` index, and execute a vector
  query before keeping the override.
- **Valkey contract.** Keep nixpkgs' Valkey on the major supported by Compose;
  prefer its current patch release over reproducing the container digest's
  older patch. `flake.lock` still makes the selected package reproducible while
  avoiding a custom source pin and retaining nixpkgs security fixes and binary
  cache coverage. Immich and Compose call the connection `redis`, which is why
  the runner must retain `REDIS_*` env names and its existing `redis` state,
  PID, and log paths. Nix's package provides `valkey-server` and `valkey-cli`;
  it does not provide the image's `redis-*` compatibility command names.
  Recheck commands, persistence, authentication, and memory/eviction settings
  whenever the image or Valkey major changes.
- **Geodata image contract.** Extract geodata from the exact
  `base-server-prod` image pinned by Immich rather than rebuilding it from
  mutable GeoNames URLs. When that image changes, identify the layer produced
  by `COPY /build/ /build/`, update `imageDigest` and `layerDigest` together,
  then replace the fixed-output hash. Verify the five files and
  `geodata-date.txt` against the image before accepting the update.
- **Lifecycle and health.** Docker restart policies and periodic health checks
  are not supplied by this native runner. Keep startup failure detection and
  clean signal handling working. Upstream's PostgreSQL health check also checks
  `pg_stat_database.checksum_failures`; our readiness probe does not replace
  that integrity check, so include it in upgrade verification.

Test two different data paths before calling the runner compatible: a brand-new
disposable cluster and a disposable copy/restore of the previous version's
database. A fresh start cannot exercise extension conversion, index rebuilds,
or version-to-version schema migrations. Never use the only copy of real data
for this test.

Before replacing an old database stack, record its installed extensions:

```sql
SELECT extname, extversion, pg_get_userbyid(extowner) AS owner
FROM pg_extension
ORDER BY extname;
```

`vector` is pgvector and is supported by this runner. `vectors` is the retired
pgvecto.rs extension and is different: upstream's compatibility database image
includes it specifically for migration. This runner does not package
pgvecto.rs, so a database containing `vectors` needs a temporary compatible
extension or the
[upstream standalone-PostgreSQL migration procedure](upstream/immich/docs/docs/administration/postgres-standalone.md)
before it can be considered supported. A backup made after conversion to
VectorChord also requires VectorChord to be available and preloaded when
restored.

### 3.2 Known upcoming change: Immich 3.2

Verified by running the pins script against `v3.2.0-rc.2` (2026-09-03):

| | v3.1.0 | v3.2.0-rc.2 |
| --- | --- | --- |
| sharp | 0.34.5 | 0.35.3 |
| **required libvips** | **>=8.17.3** | **>=8.18.3** |
| extism-js | 1.6.0 | **1.7.0** (new sha256) |
| pnpm | 11.13.1 | 11.22.0 |
| insightface | required | **dropped** |

3.2's libvips floor is already satisfied (we ship 8.18.x), so it needs a new
`extism-js` version and checksum, and re-checking the vendored libvips patch
still applies. Re-verify against the real tag when it ships —
release candidates change.

---

## 4. Verification checklist

After any upgrade, confirm all of these. Each has caught a real problem.

```bash
# libvips actually linked (NOT sharp's bundled copy -- see §5.1)
(cd .local/immich-app/server && node -p 'require("sharp").versions.vips')
# expect the version from nix/shell.nix, e.g. 8.18.6 (build.sh also asserts this)

# image formats present
(cd .local/immich-app/server && \
  node -p 'const s=require("sharp");[!!s.format.heif,!!s.format.jxl,!!s.format.webp].join()')
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

# Valkey queue/cache server answers and stays on upstream's supported major
valkey-cli -h 127.0.0.1 -p "${IMMICH_REDIS_PORT:-6380}" ping   # PONG
valkey-server --version                                         # currently v=9.1.1

# VectorChord is loaded, installed as postgres, and owns both search indexes
psql -h 127.0.0.1 -p "${IMMICH_PG_PORT:-5433}" -U postgres immich \
  -c "SHOW shared_preload_libraries" \
  -c "SELECT extname, extversion, pg_get_userbyid(extowner) AS owner
      FROM pg_extension WHERE extname IN ('vector', 'vectors', 'vchord')" \
  -c "SELECT indexname, indexdef FROM pg_indexes
      WHERE indexname IN ('clip_index', 'face_index') ORDER BY indexname" \
  -c "SELECT name, setting, unit FROM pg_settings
      WHERE name IN ('autovacuum_analyze_scale_factor',
                     'autovacuum_vacuum_cost_limit',
                     'autovacuum_vacuum_scale_factor',
                     'effective_io_concurrency', 'max_wal_size',
                     'random_page_cost', 'shared_buffers',
                     'wal_compression', 'work_mem') ORDER BY name"
# expect vchord preloaded and installed; clip_index/face_index use vchordrq
# compare settings with the selected upstream profile and the Darwin exception

# The upstream database health check treats any checksum failure as unhealthy
psql -h 127.0.0.1 -p "${IMMICH_PG_PORT:-5433}" -U postgres immich \
  -Atc 'SELECT COALESCE(SUM(checksum_failures), 0) FROM pg_stat_database'
# expect: 0

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

`scripts/build.sh` does both, and **fails** if the linked version does not match
`IMMICH_VIPS_VERSION` from the shell. **Do not remove either, or the assertion.**
Upstream does the same in `server/Dockerfile` — check there if the mechanism
changes.

**pnpm will not relink sharp when only the vips changes.** It reuses the
already-built package from its store, so the deployed tree silently keeps
pointing at the old libvips — observed exactly this when moving 8.17 → 8.18.
`build.sh` therefore rebuilds sharp unconditionally after deploying:

```bash
( cd "$PREFIX/server/node_modules/sharp" && npm run build )
```

This is why upstream's Dockerfile has the same explicit step. If you ever change
the vips and the version does not move, suspect this before anything else.

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

### 5.9 CoreML on Apple Silicon — model-specific routing

Measured on an M1 Pro (16 GB), Immich v3.1.0, onnxruntime 1.26.0, macOS
26.5.2, 2026-09-03/04. The local policy is implemented by
`scripts/patch-coreml.py`:

| Model family | Execution route | Reason |
| --- | --- | --- |
| CLIP visual encoders, including SO400M | MLProgram, static shapes, `MatMulAddFusion` disabled | Fast GPU path without ORT's giant generated constants |
| B-16 textual encoder | MLProgram, `MatMulAddFusion` disabled | Its weights are embedded and CoreML compiles it normally |
| SO400M textual encoder | ORT CPU | Its 2.8 GB of external initializers trigger an ORT CoreML path-loss bug; text runs once per query |
| Face detector | Derived static 640x640 ONNX + MLProgram | Immich always supplies 640x640, so the source model's dynamic dimensions are unnecessary |
| Face recognizer | NeuralNetwork | Preserves dynamic multi-face batching and is faster than a batch-1 static MLProgram |
| OCR detector and recognizer | NeuralNetwork | Their spatial/width dimensions are intentionally dynamic; the detector also uses an MLProgram-incompatible MaxPool |

On Darwin with CoreML enabled, the patch also launches Uvicorn directly instead
of placing its worker behind Gunicorn's `fork()`. CPU mode and non-Darwin keep
the upstream Gunicorn launcher.

This hybrid is the most performant reliable option found. In the terminology
used during diagnosis, it is **not simply option 2 everywhere**: face detection
uses option 2 (static MLProgram), while face recognition and OCR use option 1
(NeuralNetwork). SO400M uses the optimizer workaround for images and CPU only
for the comparatively infrequent text query.

#### Smart search

With `ViT-B-16-SigLIP2__webli`, CoreML indexed a 9,331-asset library in about
five minutes, cold cache included:

| Arm | Throughput | p50 latency |
| --- | --- | --- |
| CoreML, production smart-search | **32-37 img/s** | — |
| CoreML, isolated, 1 thread | 59.8 img/s | 16.7 ms |
| CoreML, isolated, 10 threads | 59.9 img/s | 166.9 ms |
| CPU, isolated, 1 thread | 4.9 img/s | 203.6 ms |
| CPU, isolated, 2 threads (Immich's default) | 7.3 img/s | 273.6 ms |
| CPU, isolated, 9 threads | 17.0 img/s | 520.5 ms |

CoreML saturates at about 60 img/s and serializes cleanly: extra threads add
latency, not throughput. It is roughly 3.5x faster than CPU at the best CPU
thread count and 12x faster single-threaded.

`ViT-SO400M-16-SigLIP2-384__webli` failed for a different reason. ORT's
`MatMulAddFusion` converts initializer-backed MatMul + Add pairs to Gemm. The
CoreML builder then serializes the generated/transposed weights as ASCII hex
immediates in `model.mil`, rather than binary data in `weight.bin`:

```text
default ORT CoreML cache:
  model.mil     6,566,229,453 bytes
  weight.bin        7,332,416 bytes

MatMulAddFusion disabled:
  model.mil         2,405,136 bytes
  weight.bin    1,707,212,352 bytes
```

This is ONNX Runtime issue
[#32212](https://github.com/microsoft/onnxruntime/issues/32212); upstream PR
[#32223](https://github.com/microsoft/onnxruntime/pull/32223) fixes generated
constant storage but was still open when tested. The local workaround sets
`optimization.disable_specified_optimizers=MatMulAddFusion` for CLIP MLProgram
sessions. With it, SO400M-384 loaded in 27.3 s, ran its first inference in
2.56 s, and averaged **183 ms/image warm versus 1267 ms on ORT CPU (6.9x)**.
The CoreML compute plan assigned 1008 captured operations to the GPU, two to
CoreML CPU, and left three graph nodes on ORT CPU.

The workaround also improved a clean B-16 visual compile in a follow-up run:
186.3 s and a 1.79 GB cache with the fusion, versus 5.8 s and a 739 MB cache
without it; warm inference was unchanged (17.3 versus 17.0 ms). Keep the
workaround on CLIP encoders until the ORT fix lands and is verified in the
wheel.

The SO400M textual tower has a separate ORT 1.26 limitation. All 330
initializers are external files (2.83 GB total); during CoreML graph building,
ORT reconstructs one without retaining the model path and aborts with
`model_path must not be empty`. Both MLProgram and NeuralNetwork failed, even
with graph optimization disabled. ORT CPU loaded it in 5.8 s and took about
166 ms per warm query, so the patch routes only this textual tower to CPU while
leaving the throughput-critical visual tower on CoreML.

#### Face recognition

Both buffalo detector and recognizer source models have dynamic input axes.
MLProgram accepted most graph nodes but E5RT rejected the unbounded dimensions
and prediction failed with CoreML status `-1`. ORT did not retry the complete
model on CPU: its Python fallback catches `EPFail`, while this path raises the
more general `Fail`, so the request became HTTP 500 and the queue retried it.

Forcing `RequireStaticInputShapes=1` alone only moved nearly all work to ORT
CPU (about 47 ms recognition and 85 ms detection), so it is not the fix. The
measured choices were:

| Face stage | CoreML mode | Warm latency |
| --- | --- | --- |
| Detector, derived static 640x640 MLProgram | GPU | **10.4 ms** |
| Detector, dynamic NeuralNetwork | mostly CoreML CPU | 32.0 ms |
| Detector, ORT CPU | CPU | 86.3 ms |
| Recognizer, dynamic NeuralNetwork | hardware accelerated | **4.1 ms** at batch 1 |
| Recognizer, static batch-1 MLProgram | GPU | 7.4 ms |
| Recognizer, ORT CPU | CPU | 48.0 ms |

The patch writes `model_coreml_static.onnx` beside the downloaded detector on
first CoreML load. It leaves the source model untouched and attaches a
content-derived `CACHE_KEY`, so changing the downloaded model creates a new
CoreML cache entry. The recognizer stays dynamic to retain Immich's multi-face
batching.

InsightFace issue
[#2238](https://github.com/deepinsight/insightface/issues/2238) describes the
same broad dynamic-shape limitation, but staticizing the recognizer too is not
the fastest configuration here.

#### OCR

The PP-OCRv5 detector preserves image aspect ratio, limits the shorter side to
736 pixels, and rounds both sides to multiples of 32. Its dimensions therefore
must remain dynamic. MLProgram also rejects its graph during compilation:

```text
in operation MaxPool.0: ceil_mode must be False when pad_type is equal to same
```

Consequently, neither the SO400M fusion workaround nor forcing static inputs
fixes OCR. NeuralNetwork does. Measured warm inference:

| OCR stage | NeuralNetwork / ALL | NeuralNetwork / CPUOnly | ORT CPU |
| --- | ---: | ---: | ---: |
| Detector, 736x736 | **173.7 ms** | 270.3 ms | 889.3 ms |
| Recognizer, batch 1 | **16.5 ms** | 20.7 ms | 38.2 ms |
| Recognizer, batch 6 | **42.1 ms** | 99.9 ms | 278.2 ms |

The `ALL` versus `CPUOnly` difference confirms useful hardware acceleration,
especially for batched recognition. Dynamic output shapes were preserved.

There is an additional process-model trap: the same NeuralNetwork OCR request
aborted inside MPS when run by Gunicorn's forked worker, reporting that
`MTLCompilerService` was unavailable. It succeeded from the same environment
under direct Uvicorn, returning 30 recognized items in 4.65 s on a cold full
detector-to-recognizer HTTP request. A standalone process also succeeded both
with and without `setsid`, isolating the problem to Gunicorn prefork rather
than Immich's detached service session. Do not remove the Darwin Uvicorn route
unless this exact OCR test still passes under the newer runtime.

#### Operations and cache maintenance

The CPU escape hatch remains available without rebuilding:

```bash
MACHINE_LEARNING_DISABLE_COREML=1 scripts/immich.sh start
```

CoreML compilation is cached beneath each model directory. Old failed
`dynamic_mlprogram` entries are no longer selected, but they can consume many
gigabytes. With Immich stopped, it is safe to delete only the affected model's
`coreml/` directory; the next load recompiles it. Re-test and remove this local
patch when upgrading ONNX Runtime beyond the release containing PR #32223.

The same `MTLCompilerService` message can still indicate a genuinely unhealthy
system compiler service. If it occurs from the direct-Uvicorn worker, stop all
Immich processes before restarting; use the CPU flag only if the Metal service
does not recover.

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
Upstream does not support downgrading, even within a minor release. For a major
upgrade, update mobile clients before the server; clients are generally
compatible with the current and previous major, while the server expects its
own matching major.

### 6.3 Then

```bash
export IMMICH_PGDATA=/path/to/pgdata
export IMMICH_MEDIA_DIR=/path/to/media
nix develop --command scripts/immich.sh start
```

Both pgvector and VectorChord are installed, and VectorChord is preloaded. As
in upstream Compose, the runner leaves `DB_VECTOR_EXTENSION` unset so Immich
auto-selects VectorChord when it is available. On the first start of an
existing pgvector database, Immich creates the `vchord` extension and rebuilds
the `clip_index` and `face_index` indexes with `vchordrq`. This can take a while
for a large library; do not interrupt it. Set
`IMMICH_DB_VECTOR_EXTENSION=pgvector` to postpone that migration.

PostgreSQL uses the settings from upstream's SSD profile by default. Set
`IMMICH_DB_STORAGE_TYPE=HDD` when `IMMICH_PGDATA` is on spinning storage; this
omits the SSD-specific `effective_io_concurrency=200` and
`random_page_cost=1.2` settings while retaining the common WAL, memory, and
autovacuum tuning. On macOS, the SSD profile uses
`effective_io_concurrency=0` because PostgreSQL rejects nonzero values on
platforms without `posix_fadvise`; the SSD `random_page_cost` setting still
applies.

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
- **The submodules are pinned, so they lag `main`.** `upstream/base-images` in
  particular is checked out at the revision matching `immich-version`; querying
  it about a *different* tag gives the wrong answer. `show-upstream-pins.sh`
  handles this — it reads locally only when the tag matches the pin, and says
  which source it used.
- **`git submodule update --init --depth 1` fetches the commit but not the
  tag**, so `git -C upstream/immich describe --tags` comes back empty on a
  freshly initialised checkout. This is harmless — `build.sh` sees no matching
  tag, fetches it, and checks out — but it is confusing if you are inspecting
  the submodule by hand. `git clone --recurse-submodules` does fetch the tag.
- **`upstream/immich` is both reference and build tree.** `scripts/build.sh`
  patches it (§8) and pnpm fills it with build output, so it will show as dirty;
  `.gitmodules` sets `ignore = dirty` for it. Do not keep local edits there.
- **Release candidates are not releases.** `v3.2.0-rc.2` figures may differ from
  `v3.2.0`.

---

## 8. Local patches

`scripts/build.sh` applies these to the source tree before building. Both are
idempotent (the file is `git checkout`-ed first) and **fail loudly** if the code
they target has moved — re-check them against each new tag.

| Patch | Why |
| --- | --- |
| `scripts/patch-postgres-bin-path.py` | Immich builds the backup command as `/usr/lib/postgresql/${databaseMajorVersion}/bin/${bin}`, a Debian path that does not exist under nix. We put the matching postgres client on PATH instead. Scheduled backups are **on by default** (`config.ts`: `backup.database.enabled`), so without this the nightly job fails silently. nixpkgs patches the same line. |

## 9. Reference: runtime layout

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
