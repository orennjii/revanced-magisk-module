#!/usr/bin/env bash

set -euo pipefail

patch_stock_apk() {
    local app_name="$1"
    local package="$2"
    local version="$3"
    local stock_apk="$4"
    local output_apk="$5"

    log ""
    log "=================================================="
    log "Patching $app_name (v$version)"
    log "Package: $package"
    log "Architecture: $ARCH"
    log "Root-only: GmsCore support explicitly DISABLED"
    log "=================================================="

    local patch_log="$CACHE_DIR/${package}-patch.log"
    local report_json="$CACHE_DIR/${package}-report.json"

    # Explicitly disable GmsCore support to preserve official package name and Google Play Services
    java -jar "$CACHE_DIR/morphe-cli.jar" patch \
        -p "$CACHE_DIR/patches.mpp" \
        "$stock_apk" \
        -o "$output_apk" \
        -d "GmsCore support" \
        --striplibs "$ARCH" \
        --keystore "$CACHE_DIR/morphe.keystore" \
        --keystore-password "123456789" \
        --keystore-entry-alias "morphe" \
        --keystore-entry-password "123456789" \
        --signer "Morphe" \
        -r "$report_json" 2>&1 | tee "$patch_log"

    verify_patched_apk "$output_apk" "$package" "$patch_log" "$report_json"

    log "Successfully built and verified: $output_apk"
}

verify_patched_apk() {
    local apk="$1"
    local expected_package="$2"
    local patch_log="$3"
    local report_json="$4"

    log "Verifying patched APK: $apk"

    # 1. APK file exists and non-empty
    [ -s "$apk" ] || error "Output APK does not exist or is empty: $apk"

    # 2. APK zip integrity
    unzip -t "$apk" >/dev/null 2>&1 || error "Corrupted APK zip archive: $apk"

    # 3. Only arm64-v8a native libraries remain
    if unzip -l "$apk" | grep -Eq 'lib/(armeabi-v7a|x86/|x86_64/)'; then
        error "Non-arm64 native libraries detected in $apk"
    fi

    # 4. Confirm GmsCore support was NOT applied
    if grep -qi "Applied: GmsCore support" "$patch_log"; then
        error "GmsCore support patch was applied! Root build requires GmsCore disabled."
    fi

    # 5. Confirm package name in Morphe report or manifest
    if [ -s "$report_json" ]; then
        local reported_pkg
        reported_pkg="$(jq -r '.packageName // empty' "$report_json")"
        if [ -n "$reported_pkg" ] && [ "$reported_pkg" != "$expected_package" ]; then
            error "Package name was altered! Expected $expected_package, found $reported_pkg"
        fi
    fi

    # 6. Verify signature
    log "Verifying APK signature..."
    run_apksigner verify "$apk" || error "APK signature verification failed for $apk"

    # 7. Confirm no MicroG / module artifacts exist
    if ls "$BUILD_DIR"/*microg* "$BUILD_DIR"/*module*.zip 1>/dev/null 2>&1; then
        error "Unwanted MicroG or Module artifact found in build directory"
    fi

    log "All verification checks passed for $expected_package"
}
