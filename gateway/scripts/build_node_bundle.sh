#!/bin/bash
# build_node_bundle.sh — produce a signed Node.js binary at $1 (or $BUNDLE_OUT).
#
# Pin matches the dev machine (Node 24.14.0 currently). talk/mac-use
# node_modules may ship native modules built against this ABI — bundling a
# different Node would require `npm rebuild` at build time. Match dev to avoid that.
#
# Usage:
#   ./build_node_bundle.sh /tmp/node-staging              # standalone
#   BUNDLE_OUT=$RESOURCES_DIR/node ./build_node_bundle.sh # Xcode build phase
#
# Env:
#   CODE_SIGN_IDENTITY   Pass-through to codesign --sign. Empty → skip.
#   NODE_VERSION         Override Node version (default v24.14.0).
#   FORCE_REBUILD        Set to 1 to ignore cache.

set -euo pipefail

NODE_VERSION="${NODE_VERSION:-v24.14.0}"
NODE_TARBALL="node-${NODE_VERSION}-darwin-arm64.tar.xz"
NODE_URL="https://nodejs.org/dist/${NODE_VERSION}/${NODE_TARBALL}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${BUNDLE_OUT:-$SCRIPT_DIR/.bundle-staging/node}}"
CACHE_DIR="$HOME/.dottie-build-cache"
DOWNLOAD_CACHE="$CACHE_DIR/downloads"
CACHED_BUNDLE="$CACHE_DIR/node-${NODE_VERSION}"
mkdir -p "$DOWNLOAD_CACHE"

CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY:-}}"

log() { printf '[node-bundle] %s\n' "$*" >&2; }
die() { printf '[node-bundle] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(uname -m)" = "arm64" ] || die "arm64 build host required (got $(uname -m))"

# Drop headers/docs — customers only need bin/node (+ lib for npm-native optional).
# Run after every copy so old caches still get slimmed without FORCE_REBUILD.
slim_node_tree() {
    local root="$1"
    rm -rf "$root/include" "$root/share" \
        "$root/CHANGELOG.md" "$root/LICENSE" "$root/README.md" 2>/dev/null || true
}

# -- cache hit ----------------------------------------------------------------
if [ -d "$CACHED_BUNDLE" ] && [ -z "${FORCE_REBUILD:-}" ]; then
    log "cache hit: $CACHED_BUNDLE"
    rm -rf "$OUT"
    mkdir -p "$(dirname "$OUT")"
    cp -R "$CACHED_BUNDLE" "$OUT"
    slim_node_tree "$OUT"
    # Slim the cache too so future hits don't re-copy 60MB of headers.
    slim_node_tree "$CACHED_BUNDLE"
    if [ -n "$CODE_SIGN_IDENTITY" ]; then
        ENTITLEMENTS_PLIST_CACHE="$(cd "$SCRIPT_DIR/../.." && pwd)/client/Dottie/EmbeddedRuntime.entitlements"
        [ -f "$ENTITLEMENTS_PLIST_CACHE" ] || die "missing $ENTITLEMENTS_PLIST_CACHE"
        log "re-signing $OUT/bin/node with embedded-runtime entitlements"
        codesign --force --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS_PLIST_CACHE" \
            --sign "$CODE_SIGN_IDENTITY" "$OUT/bin/node" || die "codesign failed"
    fi
    "$OUT/bin/node" --version
    exit 0
fi

# -- cache miss ---------------------------------------------------------------
TARBALL_PATH="$DOWNLOAD_CACHE/$NODE_TARBALL"
if [ ! -f "$TARBALL_PATH" ]; then
    log "downloading $NODE_URL"
    curl -fL --retry 3 -o "$TARBALL_PATH.tmp" "$NODE_URL" || die "Node download failed"
    mv "$TARBALL_PATH.tmp" "$TARBALL_PATH"
fi

STAGING="$CACHE_DIR/staging-node-$$"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING"
tar -xJf "$TARBALL_PATH" -C "$STAGING"

EXTRACTED="$STAGING/node-${NODE_VERSION}-darwin-arm64"
[ -d "$EXTRACTED" ] || die "expected $EXTRACTED after extraction"
[ -x "$EXTRACTED/bin/node" ] || die "node binary missing or not executable"

log "Node: $("$EXTRACTED/bin/node" --version)"

# Strip cruft we don't need at runtime (headers ~60MB, docs, man pages).
slim_node_tree "$EXTRACTED"

# -- sign ---------------------------------------------------------------------
ENTITLEMENTS_PLIST="$(cd "$SCRIPT_DIR/../.." && pwd)/client/Dottie/EmbeddedRuntime.entitlements"

if [ -n "$CODE_SIGN_IDENTITY" ]; then
    [ -f "$ENTITLEMENTS_PLIST" ] || die "missing $ENTITLEMENTS_PLIST"
    log "signing $EXTRACTED/bin/node with embedded-runtime entitlements"
    # Apple's stock node ships with cs.allow-jit + allow-unsigned-executable-memory
    # + disable-library-validation. Re-signing with our Developer ID strips them,
    # so V8 fatally OOMs on CodeRange allocation. Re-apply via --entitlements.
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS_PLIST" \
        --sign "$CODE_SIGN_IDENTITY" "$EXTRACTED/bin/node" || die "codesign failed"
fi

# -- cache + emit -------------------------------------------------------------
log "moving to cache: $CACHED_BUNDLE"
rm -rf "$CACHED_BUNDLE"
mv "$EXTRACTED" "$CACHED_BUNDLE"

log "copying to $OUT"
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -R "$CACHED_BUNDLE" "$OUT"

log "done. node: $OUT/bin/node"
"$OUT/bin/node" --version
du -sh "$OUT" 2>/dev/null
