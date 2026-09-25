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
        modem|modemst1|modemst2|fsg|bluetooth|dsp|persist|abl|xbl|xbl_config|aop|aop_config|cpucp|devcfg|keymaster|tz|hyp|uefisecapp|qupfw|shrm|imagefv) echo "TARGET-HARDWARE-SPECIFIC" ;;
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

all_names="$(printf '%s\n%s\n' "${!SRC_SIZE[*]}" "${!TGT_SIZE[*]}" | tr ' ' '\n' | sort -u | grep -v '^$')"

PORTABLE_TOTAL=0
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
                sel="MISSING-FROM-TARGET"; size=0; fs="unknown"
                record_status "classify_${name}" WARN "kept-from-target partition '$name' does not exist in target ROM -- manual review needed"
            fi
            ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$avail" "$cls" "$sel" "$size" "$fs" >> "$CLASS_TSV"
done

log_info "Classification written: $CLASS_TSV"
record_status "partition_classification" PASS "$(wc -l < "$CLASS_TSV") partitions classified"

# --- Heuristic dynamic-partition capacity check ------------------------
# ota_full payload.bin layouts do not ship a standalone super.img we can
# lpdump for the device's true group ceiling. We estimate capacity as
# the target's OWN current dynamic-partition usage (system+system_ext+
# product+vendor+odm as shipped) plus a configurable slack margin. This
# is explicitly a heuristic, not a verified device limit -- the report
# says so; it is not asserted as a hard PASS.
CURRENT_TARGET_DYNAMIC_TOTAL=0
for p in system system_ext product vendor odm; do
    CURRENT_TARGET_DYNAMIC_TOTAL=$((CURRENT_TARGET_DYNAMIC_TOTAL + ${TGT_SIZE[$p]:-0}))
done
SLACK_PCT="${DYNAMIC_GROUP_SLACK_PCT:-10}"
ESTIMATED_CAP=$((CURRENT_TARGET_DYNAMIC_TOTAL * (100 + SLACK_PCT) / 100))
NEW_DYNAMIC_TOTAL=0
for p in system system_ext product; do
    NEW_DYNAMIC_TOTAL=$((NEW_DYNAMIC_TOTAL + ${SRC_SIZE[$p]:-${TGT_SIZE[$p]:-0}}))
done
for p in vendor odm; do
    NEW_DYNAMIC_TOTAL=$((NEW_DYNAMIC_TOTAL + ${TGT_SIZE[$p]:-0}))
done

{
    echo "# Dynamic partition sizing (HEURISTIC -- see caveat below)"
    echo "current_target_dynamic_total_bytes=$CURRENT_TARGET_DYNAMIC_TOTAL"
    echo "estimated_capacity_with_${SLACK_PCT}pct_slack_bytes=$ESTIMATED_CAP"
    echo "projected_ported_dynamic_total_bytes=$NEW_DYNAMIC_TOTAL"
    echo "caveat=No standalone super.img metadata was available (payload.bin-based OTA);"
    echo "  this is estimated from shipped partition sizes, not a verified device group limit."
} > "$REPORT_DIR/dynamic_partition_sizing.txt"

if [ "$NEW_DYNAMIC_TOTAL" -gt "$ESTIMATED_CAP" ]; then
    record_status "dynamic_partition_sizing" FAIL "projected ${NEW_DYNAMIC_TOTAL}B exceeds heuristic capacity ${ESTIMATED_CAP}B -- see dynamic_partition_sizing.txt; do not proceed to packaging without a real device-verified lpdump"
else
    record_status "dynamic_partition_sizing" WARN "projected ${NEW_DYNAMIC_TOTAL}B fits heuristic capacity ${ESTIMATED_CAP}B, but this is an ESTIMATE (no super.img metadata) -- verify with lpdump on-device before flashing"
fi

log_info "Sizing report: $REPORT_DIR/dynamic_partition_sizing.txt"
