#!/usr/bin/env bash

set -euo pipefail

# Download APKEditor for merging split APKs / bundles if needed
ensure_apkeditor() {
    local editor_jar="$CACHE_DIR/apkeditor.jar"
    if [ ! -s "$editor_jar" ]; then
        log "Downloading APKEditor for split APK merging..."
        local editor_release dlurl
        editor_release="$(gh_api_get "repos/REAndroid/APKEditor/releases/latest")"
        dlurl="$(echo "$editor_release" | jq -r '.assets[] | select(.name | endswith(".jar")) | .browser_download_url' | head -n1)"
        [ -n "$dlurl" ] || error "Could not locate APKEditor release jar"
        curl -fL "$dlurl" -o "$editor_jar"
    fi
}

merge_splits() {
    local bundle="$1"
    local output="$2"

    log "Merging split APK bundle ($bundle)..."
    ensure_apkeditor

    local unsigned_apk="${output}.unsigned.apk"
    java -jar "$CACHE_DIR/apkeditor.jar" merge -i "$bundle" -o "$unsigned_apk" -clean-meta -f

    # Sign the merged stock apk
    run_apksigner sign \
        --ks "$CACHE_DIR/morphe.keystore" \
        --ks-pass pass:123456789 \
        --key-pass pass:123456789 \
        --ks-key-alias morphe \
        --out "$output" \
        "$unsigned_apk"

    rm -f "$unsigned_apk" "${output}.idsig"
}

# Download from APKMirror using structured page traversal
download_from_apkmirror() {
    local app_slug="$1"
    local version="$2"
    local output="$3"

    local base_url="https://www.apkmirror.com/apk/google-inc/${app_slug}/${app_slug}-${version//./-}-release"
    log "Querying APKMirror: $base_url"

    local user_agent="Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
    local release_html
    release_html="$(curl -sSL -A "$user_agent" "$base_url/" 2>&1)" || return 1

    # If blocked by Cloudflare challenge, return failure to allow fallback
    if echo "$release_html" | grep -qiE "cf-mitigated|challenges\.cloudflare|Cloudflare"; then
        warn "APKMirror is protected by Cloudflare challenge."
        return 1
    fi

    # Extract download links from variant rows
    # Prefer arm64-v8a + nodpi, fallback to universal / bundle
    local variant_path
    variant_path="$(echo "$release_html" | grep -o 'href="[^"]*-android-apk-download/"' | head -n1 | sed 's/href="//;s/"//' || true)"

    if [ -z "$variant_path" ]; then
        warn "Could not parse APKMirror variant link."
        return 1
    fi

    local variant_url="https://www.apkmirror.com${variant_path}"
    local variant_html
    variant_html="$(curl -sSL -A "$user_agent" "$variant_url" 2>&1)" || return 1

    local dl_btn_path
    dl_btn_path="$(echo "$variant_html" | grep -o 'href="[^"]*/download/\?[^"]*"' | head -n1 | sed 's/href="//;s/"//' || true)"
    [ -n "$dl_btn_path" ] || return 1

    local dl_page_url="https://www.apkmirror.com${dl_btn_path}"
    local dl_page_html
    dl_page_html="$(curl -sSL -A "$user_agent" "$dl_page_url" 2>&1)" || return 1

    local cdn_url
    cdn_url="$(echo "$dl_page_html" | grep -o 'href="https://[^"]*key=[^"]*"' | head -n1 | sed 's/href="//;s/"//' || true)"
    [ -n "$cdn_url" ] || return 1

    log "Downloading from APKMirror CDN..."
    local temp_download="$CACHE_DIR/apkmirror_temp"
    curl -fSL -A "$user_agent" "$cdn_url" -o "$temp_download" || return 1

    if file "$temp_download" | grep -qi "zip\|archive"; then
        # Check if it's a split bundle (apkm)
        if unzip -l "$temp_download" | grep -q "base.apk"; then
            mv "$temp_download" "${output}.apkm"
            merge_splits "${output}.apkm" "$output"
            rm -f "${output}.apkm"
        else
            mv "$temp_download" "$output"
        fi
        return 0
    fi

    rm -f "$temp_download"
    return 1
}

# Download from Archive.org repository dynamically inspecting available files
download_from_archive() {
    local package="$1"
    local version="$2"
    local output="$3"

    local index_url="https://archive.org/download/jhc-apks/apks/${package}"
    log "Querying Archive repository: $index_url"

    local index_html
    index_html="$(curl -fsSL "$index_url" 2>&1)" || return 1

    # Extract all href links
    local links
    links="$(echo "$index_html" | grep -o 'href="[^"]*"' | sed 's/href="//;s/"//')"

    # Match in priority order: arm64-v8a apk -> all apk -> arm64-v8a apkm -> all apkm
    local matched_file=""
    for pattern in \
        "${package}-${version}-arm64-v8a.apk" \
        "${package}-${version}-all.apk" \
        "${package}-${version}-arm64-v8a.apkm" \
        "${package}-${version}-all.apkm"; do
        if echo "$links" | grep -Fxq "$pattern"; then
            matched_file="$pattern"
            break
        fi
    done

    # If exact package prefix was not found, match version and arch
    if [ -z "$matched_file" ]; then
        matched_file="$(echo "$links" | grep -E "${version}-(arm64-v8a|all)\.(apk|apkm)$" | head -n1 || true)"
    fi

    if [ -z "$matched_file" ]; then
        warn "No matching file found in archive for $package $version"
        return 1
    fi

    log "Found archive candidate: $matched_file"
    local download_url="${index_url}/${matched_file}"
    local dest_temp="$CACHE_DIR/$matched_file"

    curl -fSL "$download_url" -o "$dest_temp"

    if [[ "$matched_file" == *.apkm ]]; then
        merge_splits "$dest_temp" "$output"
        rm -f "$dest_temp"
    else
        mv "$dest_temp" "$output"
    fi

    return 0
}

download_stock_apk() {
    local app_slug="$1"
    local package="$2"
    local version="$3"
    local output="$4"

    log "Acquiring stock APK for $package (v$version)..."

    # Strategy: First check Archive.org mirror (fast, reliable, no Cloudflare captcha).
    # If not found or fails, fallback to APKMirror traversal.
    if download_from_archive "$package" "$version" "$output"; then
        log "Stock APK successfully acquired from Archive repository."
    elif download_from_apkmirror "$app_slug" "$version" "$output"; then
        log "Stock APK successfully acquired from APKMirror."
    else
        error "Failed to download stock APK for $package (v$version) from all sources."
    fi

    [ -s "$output" ] || error "Downloaded stock APK is empty: $output"
    local unzip_status=0
    unzip -t "$output" >/dev/null 2>&1 || unzip_status=$?
    if [ "$unzip_status" -ge 2 ]; then
        error "Downloaded stock APK is corrupted (exit code $unzip_status): $output"
    fi
}
