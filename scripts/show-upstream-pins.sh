#!/usr/bin/env bash
# Print every upstream pin this repo has to track, for a given immich tag.
#
#   scripts/show-upstream-pins.sh [tag]     # defaults to ./immich-version
#
# Run this FIRST when upgrading. Everything it prints has a corresponding
# value in nix/ or immich-version that may need to change. See UPGRADING.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${IMMICH_SRC_DIR:-$REPO_ROOT/work/immich}"
UPSTREAM="${IMMICH_UPSTREAM:-https://github.com/immich-app/immich.git}"
TAG="${1:-$(cat "$REPO_ROOT/immich-version")}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }

if [[ ! -d "$SRC_DIR/.git" ]]; then
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone -q --depth=1 --branch "$TAG" "$UPSTREAM" "$SRC_DIR"
fi

if ! git -C "$SRC_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  warn "fetching tag $TAG..."
  git -C "$SRC_DIR" fetch -q --depth=1 "$UPSTREAM" "refs/tags/$TAG:refs/tags/$TAG"
fi

show() { git -C "$SRC_DIR" show "$TAG:$1" 2>/dev/null; }

bold "immich $TAG"
echo

# --- build toolchain ---------------------------------------------------------

bold "toolchain (mise.toml) -> nix/shell.nix"
show mise.toml | sed -n '/^\[tools\]/,/^\[/p' \
  | grep -E '^(node|pnpm|java) *=' | sed 's/^/  /'
echo "  python  = $(show machine-learning/pyproject.toml | sed -n 's/^requires-python *= *//p')"
echo

# --- sharp / libvips ---------------------------------------------------------
# This is the pin that bites: sharp gates on libvips at compile time, so
# nix/shell.nix must provide a vips inside sharp's declared range.

bold "sharp -> vips pin in nix/shell.nix"
sharp_range="$(show server/package.json | sed -n 's/.*"sharp": *"\([^"]*\)".*/\1/p' | head -1)"
sharp_locked="$(show pnpm-lock.yaml | sed -n 's/^  sharp@\([0-9][^(:]*\).*/\1/p' | head -1)"
echo "  declared:  $sharp_range"
echo "  resolved:  ${sharp_locked:-unknown}"

if [[ -n "$sharp_locked" ]] && command -v npm >/dev/null; then
  libvips="$(npm view "sharp@$sharp_locked" config.libvips 2>/dev/null || true)"
  echo "  requires libvips: ${libvips:-<npm lookup failed>}"
  [[ -n "$libvips" ]] && echo "  -> nix/shell.nix must supply a vips satisfying '$libvips'"
else
  warn "  (could not resolve libvips requirement; run 'npm view sharp@<v> config.libvips')"
fi
echo

# --- prebuilt binaries -------------------------------------------------------

bold "prebuilt binaries (mise.lock) -> nix/extism-js.nix"
LOCK_FILE="$(mktemp)"
trap 'rm -f "$LOCK_FILE"' EXIT
show mise.lock > "$LOCK_FILE"

python3 - "$LOCK_FILE" <<'PY'
import re, sys

lock = open(sys.argv[1]).read()
tools = [
    ("github:extism/js-pdk", "nix/extism-js.nix -- version AND sha256"),
    ("github:webassembly/binaryen", "nixpkgs binaryen (version only)"),
    ("github:jellyfin/jellyfin-ffmpeg", "nixpkgs jellyfin-ffmpeg (version only)"),
]

for tool, note in tools:
    quoted = re.escape(tool)
    version = re.search(rf'\[\[tools\."{quoted}"\]\]\nversion = "([^"]+)"', lock)
    platform = re.search(
        rf'\[tools\."{quoted}"\."platforms\.macos-arm64"\]\n((?:[^\[]*\n)*)', lock
    )

    print(f"  {tool}  [{note}]")
    print(f"    version : {version.group(1) if version else 'unknown'}")
    if platform:
        for line in platform.group(1).strip().splitlines():
            if line.startswith(("checksum", "url ")):
                print(f"    {line.strip()}")
    print()
PY

# --- native libraries (immich-app/base-images) -------------------------------
# immich builds FROM a dated base image; that datestamp identifies a point in
# the base-images repo, which is where the real native library versions live.

bold "native libraries -> nix/shell.nix"
base_tag="$(show server/Dockerfile | sed -n 's|.*base-server-dev:\([0-9]\{12\}\).*|\1|p' | head -1)"

if [[ -z "$base_tag" ]]; then
  warn "  could not find a base-server-dev tag in server/Dockerfile"
  warn "  check https://github.com/immich-app/base-images manually"
else
  until_ts="${base_tag:0:4}-${base_tag:4:2}-${base_tag:6:2}T${base_tag:8:2}:${base_tag:10:2}:00Z"
  echo "  base image : base-server-dev:$base_tag  ($until_ts)"

  api="https://api.github.com/repos/immich-app/base-images/commits"
  raw="https://raw.githubusercontent.com/immich-app/base-images"

  for lib in libvips imagemagick libheif libraw libjxl; do
    sha="$(curl -fsSL "$api?path=server/sources/$lib.json&until=$until_ts&per_page=1" 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["sha"] if d else "")' 2>/dev/null || true)"
    if [[ -z "$sha" ]]; then
      printf '    %-13s <lookup failed>\n' "$lib"
      continue
    fi
    ver="$(curl -fsSL "$raw/$sha/server/sources/$lib.json" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
    printf '    %-13s %s\n' "$lib" "${ver:-<unknown>}"
  done
  echo "  (these are what upstream builds against; see UPGRADING.md §2.1-2.2)"
fi
echo

# --- machine learning --------------------------------------------------------

bold "machine-learning deps (pyproject.toml)"
show machine-learning/pyproject.toml | sed -n '/^dependencies = \[/,/^\]/p' | sed 's/^/  /'
echo
show machine-learning/pyproject.toml | sed -n '/^\[project.optional-dependencies\]/,/^\[/p' \
  | grep -E '^(cpu|cuda|openvino) *=' | sed 's/^/  /'
echo

bold "reminder"
cat <<'EOF'
  - geodata (nix/geodata.nix) is independent of the immich tag; refresh it only
    deliberately, and update timestamp + hash together.
  - nix/shell.nix pins postgresql_17. An existing cluster CANNOT be started by a
    different major version -- see UPGRADING.md before bumping.
EOF
