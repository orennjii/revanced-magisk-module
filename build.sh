#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source modular components
source "$ROOT_DIR/scripts/common.sh"
source "$ROOT_DIR/scripts/download.sh"
source "$ROOT_DIR/scripts/patch.sh"

main() {
    log "=================================================="
    log "Starting Morphe Root APK Builder"
    log "Target: YouTube + YouTube Music (arm64-v8a only)"
    log "=================================================="

    init_environment
    fetch_morphe_tools
    generate_keystore

    # 1. Build YouTube
    local yt_slug="youtube"
    local yt_pkg="com.google.android.youtube"
    local yt_name="YouTube"
    local yt_ver
    yt_ver="$(get_morphe_compatible_version "$yt_pkg")"
    log "Selected $yt_name compatible version: $yt_ver"

    local yt_stock="$CACHE_DIR/${yt_slug}-${yt_ver}-stock.apk"
    local yt_output="$BUILD_DIR/${yt_slug}-morphe-v${yt_ver}-${ARCH}.apk"

    download_stock_apk "$yt_slug" "$yt_pkg" "$yt_ver" "$yt_stock"
    patch_stock_apk "$yt_name" "$yt_pkg" "$yt_ver" "$yt_stock" "$yt_output"

    # 2. Build YouTube Music
    local ytm_slug="youtube-music"
    local ytm_pkg="com.google.android.apps.youtube.music"
    local ytm_name="YouTube Music"
    local ytm_ver
    ytm_ver="$(get_morphe_compatible_version "$ytm_pkg")"
    log "Selected $ytm_name compatible version: $ytm_ver"

    local ytm_stock="$CACHE_DIR/${ytm_slug}-${ytm_ver}-stock.apk"
    local ytm_output="$BUILD_DIR/${ytm_slug}-morphe-v${ytm_ver}-${ARCH}.apk"

    download_stock_apk "$ytm_slug" "$ytm_pkg" "$ytm_ver" "$ytm_stock"
    patch_stock_apk "$ytm_name" "$ytm_pkg" "$ytm_ver" "$ytm_stock" "$ytm_output"

    # 3. Generate build metadata
    local build_time
    build_time="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local info_json="$BUILD_DIR/build-info.json"

    jq -n \
        --arg build_time "$build_time" \
        --arg arch "$ARCH" \
        --arg cli_ver "$MORPHE_CLI_VER" \
        --arg patches_ver "$MORPHE_PATCHES_VER" \
        --arg yt_pkg "$yt_pkg" \
        --arg yt_ver "$yt_ver" \
        --arg yt_file "$(basename "$yt_output")" \
        --arg ytm_pkg "$ytm_pkg" \
        --arg ytm_ver "$ytm_ver" \
        --arg ytm_file "$(basename "$ytm_output")" \
        '{
            build_timestamp: $build_time,
            architecture: $arch,
            morphe_cli_version: $cli_ver,
            morphe_patches_version: $patches_ver,
            apps: [
                {
                    name: "YouTube",
                    package: $yt_pkg,
                    version: $yt_ver,
                    output_file: $yt_file
                },
                {
                    name: "YouTube Music",
                    package: $ytm_pkg,
                    version: $ytm_ver,
                    output_file: $ytm_file
                }
            ]
        }' > "$info_json"

    log ""
    log "=================================================="
    log "BUILD COMPLETE"
    log "=================================================="
    ls -lh "$BUILD_DIR"
    log "Metadata recorded in $info_json"
}

main "$@"
