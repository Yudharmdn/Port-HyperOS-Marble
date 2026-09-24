#!/usr/bin/env bash
# scripts/02_download_verify.sh -- Phase A steps 4-6: download source ROM,
# download target ROM, verify ZIP integrity. Never proceeds on a
# corrupted or empty download.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/../config/port.env"

download_and_verify() {
    local url="$1" dest="$2" label="$3"
    log_info "Downloading $label from $url"
    curl -fL --retry 5 --retry-all-errors --connect-timeout 30 -o "$dest" "$url"

    [ -s "$dest" ] || die "$label: downloaded file is empty ($dest)"

    if ! unzip -t "$dest" >/dev/null 2>&1; then
        die "$label: ZIP integrity check failed for $dest -- refusing to continue with a corrupted ROM"
    fi

    local size sha
    size="$(stat -c%s "$dest")"
    sha="$(sha256sum "$dest" | awk '{print $1}')"
    log_info "$label OK: size=${size} bytes sha256=${sha}"
    printf '%s\turl=%s\tsize=%s\tsha256=%s\n' "$label" "$url" "$size" "$sha" \
        >> "$REPORT_DIR/rom_metadata.tsv"
}

log_section 2 "DOWNLOAD + VERIFY SOURCE AND TARGET ROMS"
mkdir -p "$SRC_DIR" "$TGT_DIR" "$REPORT_DIR"
: > "$REPORT_DIR/rom_metadata.tsv"

download_and_verify "$SOURCE_ROM_URL" "$SRC_DIR/source_rom.zip" "SOURCE(${SOURCE_DEVICE}/${SOURCE_BUILD})"
record_status "download_source_rom" PASS "$SOURCE_DEVICE $SOURCE_BUILD downloaded and ZIP-verified"

download_and_verify "$TARGET_ROM_URL" "$TGT_DIR/target_rom.zip" "TARGET(${TARGET_DEVICE}/${TARGET_BUILD})"
record_status "download_target_rom" PASS "$TARGET_DEVICE $TARGET_BUILD downloaded and ZIP-verified"

log_info "Both ROMs downloaded and verified. Metadata: $REPORT_DIR/rom_metadata.tsv"
