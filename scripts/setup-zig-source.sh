#!/usr/bin/env bash
# setup-zig-source.sh - vendor upstream Zig and build libzig.a.
#
# Supported ZIG_TAG values:
#   supported      -> project-pinned tested version (default)
#   latest-stable  -> latest stable release from ziglang.org/download/index.json
#   master         -> latest master snapshot from ziglang.org/download/index.json
#   0.14.0         -> explicit release tag
#
# Bootstrap Zig selection:
#   ZIG=zig        -> use zig from PATH (must match the resolved version)
#   ZIG=/path/to/zig
#   ZIG=auto       -> download a matching bootstrap Zig into deps/toolchains/bootstrap
#
# Extra build knobs:
#   ZIG_TARGET=native
#   ZIG_ENABLE_LLVM=1
#   ZIG_CONFIG_H=/path/to/config.h
#   ZIG_SEARCH_PREFIXES=/opt/llvm:/opt/clang
#
# The auto bootstrap mode is experimental and uses official ziglang.org
# download metadata.

set -euo pipefail

ZIG_TAG="${ZIG_TAG:-supported}"
ZIG_REPO="${ZIG_REPO:-https://github.com/ziglang/zig}"
ZIG_OPTIMIZE="${ZIG_OPTIMIZE:-ReleaseFast}"
ZIG_TARGET="${ZIG_TARGET:-native}"
ZIG="${ZIG:-zig}"
ZIG_ENABLE_LLVM="${ZIG_ENABLE_LLVM:-0}"
ZIG_CONFIG_H="${ZIG_CONFIG_H:-}"
ZIG_SEARCH_PREFIXES="${ZIG_SEARCH_PREFIXES:-}"
ZIG_INDEX_URL="${ZIG_INDEX_URL:-https://ziglang.org/download/index.json}"

SUPPORTED_TAGS=("0.14.0")
DEFAULT_SUPPORTED_TAG="${SUPPORTED_TAGS[0]}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS_DIR="$REPO_ROOT/deps"
TOOLCHAINS_DIR="$DEPS_DIR/toolchains"
ZIG_DIR="$DEPS_DIR/zig"
PATCH_FILE="$REPO_ROOT/patches/zig-expose-lib.patch"
MARKER_FILE="$ZIG_DIR/.zigbox-patched"
INDEX_JSON=""

log() { printf '\033[1;34m[setup-zig]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[setup-zig]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || err "required command not found: $1"
}

ensure_index() {
    [[ -n "$INDEX_JSON" ]] && return
    require_cmd curl
    require_cmd python3
    INDEX_JSON="$(mktemp)"
    trap '[[ -n "$INDEX_JSON" && -f "$INDEX_JSON" ]] && rm -f "$INDEX_JSON"' EXIT
    log "fetching Zig download index"
    curl -fsSL "$ZIG_INDEX_URL" -o "$INDEX_JSON"
}

get_latest_stable_tag() {
    python3 - "$INDEX_JSON" <<'PY'
import json, re, sys
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    data = json.load(fh)
stable = sorted(
    (key for key in data.keys() if re.fullmatch(r"\d+\.\d+\.\d+", key)),
    key=lambda s: tuple(map(int, s.split('.'))),
    reverse=True,
)
if not stable:
    raise SystemExit("no stable release tags found")
print(stable[0])
PY
}

resolve_requested_tag() {
    case "$ZIG_TAG" in
        supported)
            RESOLVED_REF="$DEFAULT_SUPPORTED_TAG"
            BOOTSTRAP_VERSION="$DEFAULT_SUPPORTED_TAG"
            EXPERIMENTAL_CHANNEL=0
            ;;
        latest-stable)
            ensure_index
            RESOLVED_REF="$(get_latest_stable_tag)"
            BOOTSTRAP_VERSION="$RESOLVED_REF"
            EXPERIMENTAL_CHANNEL=0
            ;;
        master)
            ensure_index
            RESOLVED_REF="master"
            BOOTSTRAP_VERSION="$(python3 - "$INDEX_JSON" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    data = json.load(fh)
print(data["master"]["version"])
PY
)"
            EXPERIMENTAL_CHANNEL=1
            ;;
        *)
            RESOLVED_REF="$ZIG_TAG"
            if [[ "$ZIG_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                BOOTSTRAP_VERSION="$ZIG_TAG"
            else
                BOOTSTRAP_VERSION=""
            fi
            EXPERIMENTAL_CHANNEL=0
            ;;
    esac
}

platform_candidates() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "$os:$arch" in
        Linux:x86_64) printf '%s\n' "x86_64-linux" ;;
        Linux:aarch64|Linux:arm64) printf '%s\n' "aarch64-linux" ;;
        Linux:armv7l|Linux:armv6l) printf '%s\n' "armv7a-linux" "arm-linux" ;;
        Linux:i686|Linux:i386) printf '%s\n' "x86-linux" ;;
        Darwin:x86_64) printf '%s\n' "x86_64-macos" ;;
        Darwin:arm64|Darwin:aarch64) printf '%s\n' "aarch64-macos" ;;
        *)
            err "unsupported host platform for auto bootstrap: $os/$arch"
            ;;
    esac
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        err "need sha256sum or shasum to verify downloads"
    fi
}

ensure_auto_bootstrap() {
    [[ -n "$BOOTSTRAP_VERSION" ]] || err "auto bootstrap needs a resolvable release version"
    ensure_index
    require_cmd tar

    mapfile -t platform_keys < <(platform_candidates)
    local meta
    meta="$(python3 - "$INDEX_JSON" "$BOOTSTRAP_VERSION" "${platform_keys[@]}" <<'PY'
import json, sys
index_path = sys.argv[1]
version = sys.argv[2]
candidates = sys.argv[3:]
with open(index_path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)
entry = data.get(version)
if entry is None:
    raise SystemExit(f"missing version in index: {version}")
for key in candidates:
    item = entry.get(key)
    if item:
        print(key)
        print(item["tarball"])
        print(item["shasum"])
        raise SystemExit(0)
raise SystemExit("no matching host archive in index")
PY
)" || err "failed to resolve bootstrap archive for $BOOTSTRAP_VERSION"

    local platform_key archive_url archive_sha archive_path extract_dir temp_dir root_dir
    platform_key="$(printf '%s\n' "$meta" | sed -n '1p')"
    archive_url="$(printf '%s\n' "$meta" | sed -n '2p')"
    archive_sha="$(printf '%s\n' "$meta" | sed -n '3p')"

    mkdir -p "$TOOLCHAINS_DIR/bootstrap/$platform_key"
    archive_path="$TOOLCHAINS_DIR/bootstrap/$platform_key/$(basename "$archive_url")"
    extract_dir="$TOOLCHAINS_DIR/bootstrap/$platform_key/$BOOTSTRAP_VERSION"

    if [[ -x "$extract_dir/zig" ]]; then
        local existing_version
        existing_version="$("$extract_dir/zig" version)"
        if [[ "$existing_version" == "$BOOTSTRAP_VERSION" ]]; then
            log "reusing cached bootstrap zig: $extract_dir/zig"
            ZIG_BOOTSTRAP_PATH="$extract_dir/zig"
            return
        fi
        rm -rf "$extract_dir"
    fi

    if [[ ! -f "$archive_path" ]]; then
        log "downloading bootstrap Zig $BOOTSTRAP_VERSION for $platform_key"
        curl -fsSL "$archive_url" -o "$archive_path"
    fi

    local actual_sha
    actual_sha="$(sha256_file "$archive_path")"
    [[ "$actual_sha" == "$archive_sha" ]] || {
        rm -f "$archive_path"
        err "checksum mismatch for $archive_path"
    }

    temp_dir="$(mktemp -d)"
    trap 'rm -rf "$temp_dir"' RETURN
    log "extracting bootstrap Zig into cache"
    tar -xf "$archive_path" -C "$temp_dir"
    root_dir="$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [[ -n "$root_dir" ]] || err "bootstrap archive did not contain a root directory"
    rm -rf "$extract_dir"
    mv "$root_dir" "$extract_dir"
    rm -rf "$temp_dir"
    trap - RETURN

    [[ -x "$extract_dir/zig" ]] || err "bootstrap zig was not found after extraction"
    log "cached bootstrap zig: $extract_dir/zig"
    ZIG_BOOTSTRAP_PATH="$extract_dir/zig"
}

sync_upstream_zig() {
    if [[ ! -d "$ZIG_DIR/.git" ]]; then
        if [[ "$RESOLVED_REF" == "master" ]]; then
            log "cloning $ZIG_REPO @ master into deps/zig (experimental channel)"
        else
            log "cloning $ZIG_REPO @ $RESOLVED_REF into deps/zig"
        fi
        git clone --depth 1 --branch "$RESOLVED_REF" "$ZIG_REPO" "$ZIG_DIR"
        return
    fi

    if [[ "$RESOLVED_REF" == "master" ]]; then
        log "updating deps/zig to latest origin/master"
        (
            cd "$ZIG_DIR"
            git fetch --depth 1 origin master
            git checkout --force FETCH_HEAD
        )
        rm -f "$MARKER_FILE"
        return
    fi

    local current_tag
    current_tag="$(cd "$ZIG_DIR" && git describe --tags --exact-match 2>/dev/null || true)"
    if [[ "$current_tag" != "$RESOLVED_REF" ]]; then
        log "updating deps/zig to $RESOLVED_REF (current: ${current_tag:-<unknown>})"
        (
            cd "$ZIG_DIR"
            git fetch --depth 1 origin "refs/tags/$RESOLVED_REF:refs/tags/$RESOLVED_REF"
            git checkout --force "$RESOLVED_REF"
        )
        rm -f "$MARKER_FILE"
    else
        log "deps/zig already at $RESOLVED_REF"
    fi
}

ensure_public_mainargs() {
    local main_file="$ZIG_DIR/src/main.zig"
    if grep -q '^pub fn mainArgs(gpa: Allocator, arena: Allocator, args: \[\]const \[\]const u8) !void {$' "$main_file"; then
        return
    fi
    if grep -q '^fn mainArgs(gpa: Allocator, arena: Allocator, args: \[\]const \[\]const u8) !void {$' "$main_file"; then
        log "upgrading deps/zig/src/main.zig: exposing mainArgs as pub"
        python3 - "$main_file" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
old = "fn mainArgs(gpa: Allocator, arena: Allocator, args: []const []const u8) !void {"
new = "pub fn mainArgs(gpa: Allocator, arena: Allocator, args: []const []const u8) !void {"
text = path.read_text(encoding="utf-8")
if old not in text:
    raise SystemExit("could not locate mainArgs signature")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY
        return
    fi
    err "could not locate mainArgs signature in $main_file"
}

require_cmd git
[[ -f "$PATCH_FILE" ]] || err "missing $PATCH_FILE"
mkdir -p "$DEPS_DIR"

resolve_requested_tag
log "requested tag:       $ZIG_TAG"
log "resolved ref:        $RESOLVED_REF"
[[ -n "$BOOTSTRAP_VERSION" ]] && log "bootstrap version:   $BOOTSTRAP_VERSION"
[[ "$EXPERIMENTAL_CHANNEL" == "1" ]] && log "channel:             experimental"
log "optimize:            $ZIG_OPTIMIZE"
log "target:              $ZIG_TARGET"
log "enable llvm:         $ZIG_ENABLE_LLVM"

ZIG_BOOTSTRAP_PATH="$ZIG"
if [[ "$ZIG" == "auto" ]]; then
    ensure_auto_bootstrap
fi

require_cmd "$ZIG_BOOTSTRAP_PATH"
zig_version="$("$ZIG_BOOTSTRAP_PATH" version)"
log "bootstrap zig path:  $ZIG_BOOTSTRAP_PATH"
log "bootstrap zig ver:   $zig_version"

if [[ -n "$BOOTSTRAP_VERSION" ]] && [[ "$zig_version" != "$BOOTSTRAP_VERSION" ]]; then
    err "bootstrap Zig version mismatch:
  bootstrap zig: $zig_version
  upstream ref:  $RESOLVED_REF
  expected:      $BOOTSTRAP_VERSION

Use the exact same Zig version to build upstream Zig as a library,
or pass ZIG=auto to let the script fetch the matching toolchain."
fi

if [[ -n "$ZIG_CONFIG_H" ]]; then
    ZIG_CONFIG_H="$(cd "$(dirname "$ZIG_CONFIG_H")" && pwd)/$(basename "$ZIG_CONFIG_H")"
    [[ -f "$ZIG_CONFIG_H" ]] || err "config.h not found: $ZIG_CONFIG_H"
    log "config.h:            $ZIG_CONFIG_H"
fi
if [[ -n "$ZIG_SEARCH_PREFIXES" ]]; then
    log "search prefixes:     $ZIG_SEARCH_PREFIXES"
fi
if [[ "$ZIG_ENABLE_LLVM" == "1" || "$ZIG_ENABLE_LLVM" == "true" ]] && [[ -z "$ZIG_CONFIG_H" && -z "$ZIG_SEARCH_PREFIXES" ]]; then
    log "LLVM mode without ZIG_CONFIG_H/ZIG_SEARCH_PREFIXES relies on globally discoverable LLVM, Clang, and LLD libraries"
fi

sync_upstream_zig

if [[ -f "$MARKER_FILE" ]]; then
    log "patch already applied (marker present)"
else
    log "applying patches/zig-expose-lib.patch"
    if ! (cd "$ZIG_DIR" && git apply --check "$PATCH_FILE" 2>/dev/null); then
        err "patch does not apply cleanly - upstream build.zig likely moved the anchor line.
Try: cd deps/zig && git apply --reject ../../patches/zig-expose-lib.patch
Inspect the .rej file and port the block manually (it is additive and small)."
    fi
    (cd "$ZIG_DIR" && git apply "$PATCH_FILE")
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$MARKER_FILE"
fi

ensure_public_mainargs

log "building libzig.a (optimize=$ZIG_OPTIMIZE)"
build_args=(build libzig "-Doptimize=$ZIG_OPTIMIZE")
if [[ "$ZIG_TARGET" != "native" ]]; then
    build_args+=("-Dtarget=$ZIG_TARGET")
fi
if [[ "$ZIG_ENABLE_LLVM" == "1" || "$ZIG_ENABLE_LLVM" == "true" ]]; then
    build_args+=("-Denable-llvm")
fi
if [[ -n "$ZIG_CONFIG_H" ]]; then
    build_args+=("-Dconfig_h=$ZIG_CONFIG_H")
fi
if [[ -n "$ZIG_SEARCH_PREFIXES" ]]; then
    IFS=':' read -r -a zig_search_prefixes <<<"$ZIG_SEARCH_PREFIXES"
    for prefix in "${zig_search_prefixes[@]}"; do
        [[ -n "$prefix" ]] || continue
        build_args+=(--search-prefix "$prefix")
    done
fi
(cd "$ZIG_DIR" && "$ZIG_BOOTSTRAP_PATH" "${build_args[@]}")

LIBZIG="$ZIG_DIR/zig-out/lib/libzig.a"
if [[ ! -f "$LIBZIG" ]]; then
    LIBZIG="$(find "$ZIG_DIR/zig-out" \( -name 'libzig.a' -o -name 'zig.lib' -o -name 'libzig.lib' \) -print -quit || true)"
fi
[[ -n "${LIBZIG:-}" && -f "$LIBZIG" ]] || err "libzig was not produced - check the build output above"

size="$(du -h "$LIBZIG" | cut -f1)"
log "success: $LIBZIG ($size)"
run_args=(build smoke "-Dlibzig=$LIBZIG")
if [[ "$ZIG_TARGET" != "native" ]]; then
    run_args+=("-Dtarget=$ZIG_TARGET")
fi
if [[ "$ZIG_ENABLE_LLVM" == "1" || "$ZIG_ENABLE_LLVM" == "true" ]]; then
    run_args+=("-Dembedded-zig-have-llvm=true")
fi
if [[ -n "$ZIG_SEARCH_PREFIXES" ]]; then
    IFS=':' read -r -a zig_search_prefixes <<<"$ZIG_SEARCH_PREFIXES"
    for prefix in "${zig_search_prefixes[@]}"; do
        [[ -n "$prefix" ]] || continue
        run_args+=(--search-prefix "$prefix")
    done
fi
log "now run: \"$ZIG_BOOTSTRAP_PATH\" ${run_args[*]}   (from $REPO_ROOT)"
