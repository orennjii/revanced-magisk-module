#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
CACHE_DIR="$ROOT_DIR/.cache"
ARCH="arm64-v8a"

log() {
    printf '\033[1;32m[INFO]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

error() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || error "Required command not found: $cmd"
    done
}

run_apksigner() {
    if command -v apksigner >/dev/null 2>&1; then
        apksigner "$@"
    else
        local signer_jar="$CACHE_DIR/apksigner.jar"
        if [ ! -s "$signer_jar" ]; then
            log "Downloading apksigner fallback..."
            curl -fSL "https://raw.githubusercontent.com/j-hc/revanced-magisk-module/main/bin/apksigner.jar" -o "$signer_jar" || \
                error "apksigner command not found and failed to download fallback jar"
        fi
        java -jar "$signer_jar" "$@"
    fi
}

init_environment() {
    require_cmd java curl jq unzip zip
    mkdir -p "$BUILD_DIR" "$CACHE_DIR"
}

gh_api_get() {
    local endpoint="$1"
    local auth_header=()
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        auth_header=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    curl -fsSL "${auth_header[@]}" "https://api.github.com/${endpoint}"
}

fetch_morphe_tools() {
    log "Checking latest stable Morphe tools..."

    # Fetch latest stable Morphe CLI release
    local cli_release cli_url
    cli_release="$(gh_api_get "repos/MorpheApp/morphe-cli/releases/latest")"
    MORPHE_CLI_VER="$(echo "$cli_release" | jq -r '.tag_name')"
    cli_url="$(echo "$cli_release" | jq -r '.assets[] | select(.name | test("morphe-desktop-.*-all\\.jar$")) | .browser_download_url' | head -n1)"
    [ -n "$cli_url" ] || error "Could not find morphe-desktop jar asset in Morphe CLI release $MORPHE_CLI_VER"

    if [ ! -s "$CACHE_DIR/morphe-cli.jar" ]; then
        log "Downloading Morphe CLI ($MORPHE_CLI_VER)..."
        curl -fL "$cli_url" -o "$CACHE_DIR/morphe-cli.jar"
    fi

    # Fetch latest stable Morphe Patches release
    local patches_release patches_url
    patches_release="$(gh_api_get "repos/MorpheApp/morphe-patches/releases/latest")"
    MORPHE_PATCHES_VER="$(echo "$patches_release" | jq -r '.tag_name')"
    patches_url="$(echo "$patches_release" | jq -r '.assets[] | select(.name | test("patches-.*\\.mpp$")) | .browser_download_url' | head -n1)"
    [ -n "$patches_url" ] || error "Could not find patches.mpp asset in Morphe Patches release $MORPHE_PATCHES_VER"

    if [ ! -s "$CACHE_DIR/patches.mpp" ]; then
        log "Downloading Morphe Patches ($MORPHE_PATCHES_VER)..."
        curl -fL "$patches_url" -o "$CACHE_DIR/patches.mpp"
    fi

    log "Morphe CLI: $MORPHE_CLI_VER"
    log "Morphe Patches: $MORPHE_PATCHES_VER"
}

get_morphe_compatible_version() {
    local package="$1"
    local raw_output ver

    raw_output="$(java -jar "$CACHE_DIR/morphe-cli.jar" list-versions --patches "$CACHE_DIR/patches.mpp" -f "$package" 2>&1)"
    ver="$(echo "$raw_output" | sed -n '/Most common compatible versions:/,$p' | awk 'NR > 1 {print $1; exit}')"

    [ -n "$ver" ] || error "Could not resolve compatible version for $package from Morphe CLI"
    echo "$ver"
}

generate_keystore() {
    local ks_file="$CACHE_DIR/morphe.keystore"
    if [ ! -f "$ks_file" ]; then
        log "Generating deterministic CI signing keystore..."
        keytool -genkeypair \
            -keystore "$ks_file" \
            -storepass "123456789" \
            -keypass "123456789" \
            -alias "morphe" \
            -keyalg RSA \
            -keysize 2048 \
            -validity 10000 \
            -dname "CN=Morphe, O=Morphe Builder, C=US" \
            >/dev/null 2>&1
    fi
}
