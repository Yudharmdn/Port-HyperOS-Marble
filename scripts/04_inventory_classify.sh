#!/usr/bin/env bash
# scripts/04_inventory_classify.sh -- Phase A steps 13-16 / Phase B.
# Classifies every partition found in either ROM, then checks whether
# the source-portable partitions will fit in the target's dynamic
# partition group. This does not decide framework-internal dependency
# compatibility (that is 05_compatibility_analysis.sh) -- this stage
# only decides WHICH WHOLE PARTITIONS move, and whether they'll fit.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/../config/port.env"

# Decision table (spec sections 12-13, 45-49). Default is always
# TARGET-HARDWARE-SPECIFIC ("keep marble") unless a partition is
# explicitly known to be generic HyperOS framework/UI. When in doubt,
# a partition is UNKNOWN and is kept from target, never guessed onto
# the source-portable list.
classify_partition() {
    case "$1" in
        system|system_ext|product) echo "SOURCE-PORTABLE" ;;
        vendor|odm|vendor_dlkm|odm_dlkm|vendor_boot|boot|init_boot|dtbo|dtb|vbmeta|vbmeta_system|vbmeta_vendor) echo "TARGET-HARDWARE-SPECIFIC" ;;
        modem|modemst1|modemst2|fsg|bluetooth|dsp|persist|abl|xbl|xbl_config|xbl_ramdump|aop|aop_config|cpucp|cpucp_dtb|devcfg|keymaster|tz|hyp|uefi|uefisecapp|qupfw|shrm|imagefv|featenabler|recovery) echo "TARGET-HARDWARE-SPECIFIC" ;;
        # SoC/board-tied images that newer Snapdragon platforms (annibale)
        # ship and marble's SM7475 does not: kernel-module, VM, secure-
        # processor and region blobs. Never portable across devices.
        system_dlkm|pvmfw|vm-bootsys|soccp_dcd|soccp_debug|spuservice|pdp|pdp_cdb|multiimgqti|modemfirmware|idmanager|countrycode) echo "TARGET-HARDWARE-SPECIFIC" ;;
        super|super_empty|userdata|metadata|misc|frp|cache) echo "SHARED" ;;
        *) echo "UNKNOWN-KEEP-TARGET" ;;
    esac
}

log_section 4 "PARTITION INVENTORY + CLASSIFICATION"

CLASS_TSV="$REPORT_DIR/partition_classification.tsv"
: > "$CLASS_TSV"
printf 'partition\torigin_available\tclassification\tselected_source\tsize_bytes\tfilesystem\n' >> "$CLASS_TSV"

declare -A SRC_SIZE SRC_FS TGT_SIZE TGT_FS
while IFS=$'\t' read -r name size fs; do SRC_SIZE[$name]="$size"; SRC_FS[$name]="$fs"; done < "$REPORT_DIR/source_partition_inventory.tsv"
while IFS=$'\t' read -r name size fs; do TGT_SIZE[$name]="$size"; TGT_FS[$name]="$fs"; done < "$REPORT_DIR/target_partition_inventory.tsv"

all_names="$(printf '%s\n%s\n' "${!SRC_SIZE[*]}" "${!TGT_SIZE[*]}" | tr ' ' '\n' | sort -u | grep -v '^$' || true)"

PORTABLE_TOTAL=0
SOURCE_ONLY_HW=()
SOURCE_ONLY_UNKNOWN=()
for name in $all_names; do
    cls="$(classify_partition "$name")"
    in_src="no"; in_tgt="no"
    [ -n "${SRC_SIZE[$name]:-}" ] && in_src="yes"
    [ -n "${TGT_SIZE[$name]:-}" ] && in_tgt="yes"
    avail="src=$in_src,tgt=$in_tgt"

    case "$cls" in
        SOURCE-PORTABLE)
            if [ "$in_src" = "yes" ]; then
                sel="source"; size="${SRC_SIZE[$name]}"; fs="${SRC_FS[$name]}"
                PORTABLE_TOTAL=$((PORTABLE_TOTAL + size))
            else
                sel="target(fallback-no-source-copy)"; size="${TGT_SIZE[$name]:-0}"; fs="${TGT_FS[$name]:-unknown}"
            fi
            ;;
        TARGET-HARDWARE-SPECIFIC|SHARED|UNKNOWN-KEEP-TARGET)
            if [ "$in_tgt" = "yes" ]; then
                sel="target"; size="${TGT_SIZE[$name]}"; fs="${TGT_FS[$name]}"
            else
                # Only the SOURCE device has this image. For a known
                # hardware-tied partition, excluding it is the correct,
                # final decision (marble has no such partition to write
                # it to) -- not something to review. Only an UNKNOWN
                # source-only partition stays a WARN, since it might carry
                # framework content the ported system expects.
                sel="SOURCE-ONLY-EXCLUDED"; size=0; fs="unknown"
                if [ "$cls" = "UNKNOWN-KEEP-TARGET" ]; then
                    SOURCE_ONLY_UNKNOWN+=("$name")
                else
                    SOURCE_ONLY_HW+=("$name")
                fi
            fi
            ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$avail" "$cls" "$sel" "$size" "$fs" >> "$CLASS_TSV"
done

log_info "Classification written: $CLASS_TSV"
if [ "${#SOURCE_ONLY_HW[@]}" -gt 0 ]; then
    record_status "source_only_hw_partitions" PASS "${#SOURCE_ONLY_HW[@]} ${SOURCE_DEVICE}-only hardware partition(s) correctly excluded (marble has no such partition): ${SOURCE_ONLY_HW[*]}"
fi
if [ "${#SOURCE_ONLY_UNKNOWN[@]}" -gt 0 ]; then
    record_status "source_only_unknown_partitions" WARN "${SOURCE_DEVICE}-only partition(s) of unknown role excluded: ${SOURCE_ONLY_UNKNOWN[*]} -- marble has no slot for them; if the ported framework reads files from them, those features will be missing"
fi
record_status "partition_classification" PASS "$(wc -l < "$CLASS_TSV") partitions classified"

# --- Dynamic-partition capacity check (pre-build ESTIMATE) -------------
# The real ceiling is the target's dynamic partition GROUP size, read from
# marble's own OTA payload manifest (lib/payload_meta.py) -- not a guess.
# Here, before anything is rebuilt, sizes can only be estimated (source
# payload sizes for the ported partitions, target payload sizes for the
# rest), so this stage never FAILs: it records the estimate, and
# 09_validate_package.sh repeats the check against the ACTUAL built
# images, which is the authoritative, blocking check.
SIZING_TXT="$REPORT_DIR/dynamic_partition_sizing.txt"
TGT_META="$REPORT_DIR/target_payload_meta.json"
SRC_META="$REPORT_DIR/source_payload_meta.json"
: > "$SIZING_TXT"
if [ -f "$TGT_DIR/raw_extract/payload.bin" ] && python3 "$SCRIPT_DIR/lib/payload_meta.py" "$TGT_DIR/raw_extract/payload.bin" > "$TGT_META" 2>>"$SIZING_TXT"; then
    if [ -f "$SRC_DIR/raw_extract/payload.bin" ]; then
        python3 "$SCRIPT_DIR/lib/payload_meta.py" "$SRC_DIR/raw_extract/payload.bin" > "$SRC_META" 2>>"$SIZING_TXT" || echo '{"groups":[],"partitions":{}}' > "$SRC_META"
    else
        echo '{"groups":[],"partitions":{}}' > "$SRC_META"
    fi
    {
        echo "# Dynamic partition sizing -- PRE-BUILD ESTIMATE against marble's real group limit"
        echo "# (authoritative re-check on the built images happens in 09_validate_package.sh)"
    } >> "$SIZING_TXT"
    set +e
    python3 "$SCRIPT_DIR/lib/dynamic_fit.py" estimate "$TGT_META" "$SRC_META" "system,system_ext,product" >> "$SIZING_TXT" 2>&1
    fit_rc=$?
    set -e
    case "$fit_rc" in
        0) record_status "dynamic_partition_sizing_estimate" PASS "pre-build estimate fits marble's real dynamic group limit (from target payload manifest); authoritative check on built images runs in 09" ;;
        1) record_status "dynamic_partition_sizing_estimate" WARN "pre-build estimate EXCEEDS marble's real dynamic group limit -- rebuilt images may still differ (compression / fs conversion); 09 re-checks the actual images and blocks packaging if they really do not fit. See dynamic_partition_sizing.txt" ;;
        *) record_status "dynamic_partition_sizing_estimate" WARN "target payload has no usable dynamic partition metadata; 09 cannot verify group capacity either -- verify with lpdump on-device" ;;
    esac
else
    echo "target payload.bin not available (non-payload ROM layout) -- group limit unknown; verify with lpdump on-device" >> "$SIZING_TXT"
    record_status "dynamic_partition_sizing_estimate" WARN "no target payload manifest to read the real group limit from -- verify with lpdump on-device before flashing"
fi

log_info "Sizing report: $SIZING_TXT"
