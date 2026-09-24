#!/usr/bin/env bash
# scripts/03_extract_detect.sh -- Phase A steps 7-13.
# Never assumes a ROM layout: detects payload.bin vs super.img vs loose
# raw/sparse images per zip before extracting anything.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/../config/port.env"

is_erofs() {
    # EROFS superblock magic 0xE0F5E1E2 (little-endian) at offset 1024.
    local img="$1"
    local magic
    magic="$(dd if="$img" bs=1 skip=1024 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ "$magic" = "e2e1f5e0" ]
}

detect_fs() {
    local img="$1"
    local ftype
    ftype="$(file -b "$img" 2>/dev/null || true)"
    case "$ftype" in
        *EROFS*) echo "erofs"; return ;;
        *ext2*|*ext3*|*ext4*) echo "ext4"; return ;;
    esac
    if is_erofs "$img"; then echo "erofs"; return; fi
    # ext4 superblock magic 0xEF53 at offset 1080
    local em
    em="$(dd if="$img" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    if [ "$em" = "53ef" ]; then echo "ext4"; return; fi
    echo "unknown"
}

unsparse_if_needed() {
    local img="$1"
    if file -b "$img" 2>/dev/null | grep -qi "android sparse image"; then
        log_info "  unsparsing $(basename "$img")"
        mv "$img" "${img}.sparse"
        simg2img "${img}.sparse" "$img"
        rm -f "${img}.sparse"
    fi
}

# process_rom_zip <zip> <outdir> <label>
process_rom_zip() {
    local zip="$1" outdir="$2" label="$3"
    mkdir -p "$outdir/raw_extract" "$outdir/partitions"
    log_info "[$label] Listing ZIP contents"
    unzip -l "$zip" > "$REPORT_DIR/${label}_zip_listing.txt"

    local payload_path=""
    payload_path="$(unzip -l "$zip" | awk '{print $NF}' | grep -E '(^|/)payload\.bin$' | head -n1 || true)"

    if [ -n "$payload_path" ]; then
        log_info "[$label] OTA layout detected: $payload_path"
        unzip -o -j "$zip" "$payload_path" -d "$outdir/raw_extract" >/dev/null
        local payload_file
        payload_file="$outdir/raw_extract/$(basename "$payload_path")"
        log_info "[$label] Inspecting payload metadata"
        payload-dumper-go -list "$payload_file" > "$REPORT_DIR/${label}_payload_partitions.txt" 2>&1 || \
            log_warn "[$label] payload-dumper-go -list unsupported on this build; continuing to full extract"
        log_info "[$label] Extracting all partitions from payload.bin"
        payload-dumper-go -o "$outdir/partitions" "$payload_file"
        record_status "${label}_ota_extract" PASS "payload.bin extracted to $outdir/partitions"
    else
        log_info "[$label] No payload.bin at top level; extracting whole ZIP for direct image search"
        unzip -o "$zip" -d "$outdir/raw_extract" >/dev/null

        local super_img
        super_img="$(find "$outdir/raw_extract" -iname 'super.img*' -type f | head -n1 || true)"
        if [ -n "$super_img" ]; then
            log_info "[$label] super.img found: $super_img"
            unsparse_if_needed "$super_img"
            log_info "[$label] Unpacking dynamic partitions with lpunpack"
            lpunpack "$super_img" "$outdir/partitions"
            record_status "${label}_super_unpack" PASS "lpunpack extracted $(find "$outdir/partitions" -name '*.img' | wc -l) images"
        else
            log_info "[$label] No super.img; treating ZIP as a loose fastboot-style image set"
            find "$outdir/raw_extract" -maxdepth 3 -iname '*.img' -exec cp {} "$outdir/partitions/" \;
            record_status "${label}_loose_images" PASS "$(find "$outdir/partitions" -name '*.img' | wc -l) loose images copied"
        fi
    fi

    # Normalize every extracted image: unsparse, then classify filesystem.
    : > "$REPORT_DIR/${label}_partition_inventory.tsv"
    find "$outdir/partitions" -maxdepth 1 -iname '*.img' -type f | sort | while read -r img; do
        unsparse_if_needed "$img"
        local name size fs
        name="$(basename "$img" .img)"
        size="$(stat -c%s "$img")"
        fs="$(detect_fs "$img")"
        printf '%s\t%s\t%s\n' "$name" "$size" "$fs" >> "$REPORT_DIR/${label}_partition_inventory.tsv"
    done
    log_info "[$label] Inventory written: $REPORT_DIR/${label}_partition_inventory.tsv"
}

log_section 3 "DETECT + EXTRACT ROM STRUCTURE"

process_rom_zip "$SRC_DIR/source_rom.zip" "$SRC_DIR" "source"
process_rom_zip "$TGT_DIR/target_rom.zip" "$TGT_DIR" "target"

record_status "extract_detect" PASS "both ROMs extracted; per-partition filesystem detected (see *_partition_inventory.tsv)"
log_info "Extraction complete."
