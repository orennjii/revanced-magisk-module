#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
TEMP_DIR="$ROOT_DIR/.tmp"

PATCHES_REPO="MorpheApp/morphe-patches"
CLI_REPO="MorpheApp/morphe-cli"

ARCH="arm64-v8a"

mkdir -p "$BUILD_DIR" "$TEMP_DIR"

log() {
    printf '\033[1;36m[INFO]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

error() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"
}

require_command java
require_command curl
require_command jq
require_command unzip
require_command zip

# ------------------------------------------------------------
# Versions
# ------------------------------------------------------------

get_latest_release_asset() {
    local repo="$1"
    local pattern="$2"

    curl -fsSL \
        "https://api.github.com/repos/${repo}/releases/latest" |
        jq -r --arg pattern "$pattern" '
            .assets[]
            | select(.name | test($pattern))
            | .browser_download_url
        ' |
        head -n1
}

download_tools() {
    log "Fetching latest Morphe CLI..."

    local cli_url
    cli_url="$(
        get_latest_release_asset \
            "$CLI_REPO" \
            'morphe-desktop.*\.jar$'
    )"

    [ -n "$cli_url" ] || error "Unable to find Morphe CLI release"

    curl -fL \
        "$cli_url" \
        -o "$TEMP_DIR/morphe.jar"

    [ -s "$TEMP_DIR/morphe.jar" ] ||
        error "Morphe CLI download failed"

    log "Morphe CLI downloaded."
}

download_patches() {
    log "Fetching latest Morphe patches..."

    local patch_url
    patch_url="$(
        get_latest_release_asset \
            "$PATCHES_REPO" \
            'patches-.*\.mpp$'
    )"

    [ -n "$patch_url" ] ||
        error "Unable to find Morphe patches release"

    curl -fL \
        "$patch_url" \
        -o "$TEMP_DIR/patches.mpp"

    [ -s "$TEMP_DIR/patches.mpp" ] ||
        error "Morphe patches download failed"

    log "Morphe patches downloaded."
}

# ------------------------------------------------------------
# Morphe helpers
# ------------------------------------------------------------

list_patches() {
    java -jar "$TEMP_DIR/morphe.jar" \
        list-patches \
        -p "$TEMP_DIR/patches.mpp" \
        --filter-package-name "$1" \
        --with-versions \
        --with-packages
}

get_supported_version() {
    local package="$1"

    log "Finding latest compatible version for $package..."

    java -jar "$TEMP_DIR/morphe.jar" \
        list-versions \
        --patches "$TEMP_DIR/patches.mpp" \
        -f "$package" |
        sed -n '/Most common compatible versions:/,$p' |
        awk 'NR > 1 {print $1}' |
        head -n1
}

get_gmscore_patch_name() {
    local package="$1"

    list_patches "$package" |
        sed -n 's/^Name: //p' |
        grep -iE '^(GmsCore support|microG|.*GmsCore.*)$' |
        head -n1
}

# ------------------------------------------------------------
# APK download
# ------------------------------------------------------------

download_stock_apk() {
    local package="$1"
    local version="$2"
    local output="$3"
    local archive_url="$4"

    log "Downloading $package $version..."

    # The archive used by the original project contains APKs
    # indexed by package name. Prefer it because it is stable
    # and avoids depending on APKMirror HTML structure.
    local archive_file="$TEMP_DIR/${package}-${version}.apk"

    if curl -fsSL \
        "${archive_url}/${version}.apk" \
        -o "$archive_file"; then

        mv "$archive_file" "$output"
        return 0
    fi

    rm -f "$archive_file"

    error \
        "Could not download $package $version from archive."
}

# ------------------------------------------------------------
# APK architecture
# ------------------------------------------------------------

strip_to_arm64() {
    local apk="$1"

    log "Keeping arm64-v8a native libraries only..."

    zip -d "$apk" \
        'lib/armeabi-v7a/*' \
        'lib/x86/*' \
        'lib/x86_64/*' \
        >/dev/null 2>&1 || true
}

# ------------------------------------------------------------
# Patch
# ------------------------------------------------------------

patch_apk() {
    local package="$1"
    local input="$2"
    local output="$3"

    local gmscore_patch

    gmscore_patch="$(get_gmscore_patch_name "$package" || true)"

    [ -n "$gmscore_patch" ] ||
        error "Could not identify GmsCore patch."

    log "GmsCore patch: $gmscore_patch"
    log "Explicitly disabling GmsCore support."

    local args=(
        patch
        -p "$TEMP_DIR/patches.mpp"
        "$input"
        -o "$output"

        # Root-only build.
        -d "$gmscore_patch"

        # Only arm64-v8a native libraries.
        --striplibs "$ARCH"

        # Reproducible build.
        --keystore "$TEMP_DIR/morphe.keystore"
        --keystore-password 123456789
        --keystore-entry-alias morphe
        --keystore-entry-password 123456789
        --signer morphe
    )

    java -jar "$TEMP_DIR/morphe.jar" "${args[@]}"
}

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

validate_apk() {
    local apk="$1"
    local expected_package="$2"

    log "Validating $apk..."

    local actual_package

    actual_package="$(
        unzip -p "$apk" AndroidManifest.xml >/dev/null 2>&1 || true
    )

    # Basic APK integrity check.
    unzip -t "$apk" >/dev/null

    # Verify no unwanted native architectures remain.
    if unzip -l "$apk" |
        grep -Eq 'lib/(armeabi-v7a|x86/|x86_64/)'; then

        error "Non-arm64 native libraries remain in $apk"
    fi

    log "APK integrity check passed."
}

# ------------------------------------------------------------
# Build one app
# ------------------------------------------------------------

build_app() {
    local name="$1"
    local package="$2"
    local archive_url="$3"

    log ""
    log "========================================"
    log "Building $name"
    log "Package: $package"
    log "Architecture: $ARCH"
    log "========================================"

    local version
    version="$(get_supported_version "$package")"

    [ -n "$version" ] ||
        error "No compatible version found for $package"

    log "Selected version: $version"

    local stock="$TEMP_DIR/${name}-${version}-stock.apk"
    local output="$BUILD_DIR/${name}-Morphe-${version}-${ARCH}.apk"

    download_stock_apk \
        "$package" \
        "$version" \
        "$stock" \
        "$archive_url"

    strip_to_arm64 "$stock"

    patch_apk \
        "$package" \
        "$stock" \
        "$output"

    validate_apk \
        "$output" \
        "$package"

    rm -f "$stock"

    log "Built:"
    log "  $output"
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

rm -rf "$BUILD_DIR" "$TEMP_DIR"
mkdir -p "$BUILD_DIR" "$TEMP_DIR"

download_tools
download_patches

# Generate a deterministic signing key.
keytool -genkeypair \
    -keystore "$TEMP_DIR/morphe.keystore" \
    -storepass 123456789 \
    -keypass 123456789 \
    -alias morphe \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname "CN=Morphe" \
    >/dev/null 2>&1

build_app \
    "YouTube" \
    "com.google.android.youtube" \
    "https://archive.org/download/jhc-apks/apks/com.google.android.youtube"

build_app \
    "Music" \
    "com.google.android.apps.youtube.music" \
    "https://archive.org/download/jhc-apks/apks/com.google.android.apps.youtube.music"

log ""
log "========================================"
log "BUILD COMPLETE"
log "========================================"

ls -lh "$BUILD_DIR"
