#!/usr/bin/env bash
# scripts/06_merge_port.sh -- Phase C steps 25-27.
# Builds the port workspace strictly from scripts/04's classification
# table. Never re-decides classification here -- this script only
# executes what 04 already decided, so the "what moves" logic lives in
# exactly one place.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/../config/port.env"

require_not_analysis_only "merge/port construction"

log_section 6 "MERGE SOURCE-PORTABLE FRAMEWORK INTO PORT WORKSPACE"

PORT_ROOT="$WORK_TREE/port_root"
PASSTHROUGH_LIST="$REPORT_DIR/passthrough_images.txt"
mkdir -p "$PORT_ROOT"
: > "$PASSTHROUGH_LIST"

CLASS_TSV="$REPORT_DIR/partition_classification.tsv"
tail -n +2 "$CLASS_TSV" | while IFS=$'\t' read -r name _avail _cls sel _size _fs; do
    case "$sel" in
        source)
            src_tree="$WORK_TREE/extract_source/$name"
            if [ -d "$src_tree" ]; then
                log_info "MERGE (source-portable): $name"
                mkdir -p "$PORT_ROOT/$name"
                rsync -a --delete "$src_tree/" "$PORT_ROOT/$name/"
            else
                log_warn "$name classified source-portable but extracted tree missing -- falling back to target image passthrough"
                echo "$name" >> "$PASSTHROUGH_LIST"
            fi
            ;;
        target|"MISSING-FROM-TARGET")
            # Whole-image passthrough: boot, vendor_boot, dtbo, firmware,
            # and anything unknown. Handled in 07 (vendor/odm may still
            # need an fs-format conversion) -- here we just record intent.
            echo "$name" >> "$PASSTHROUGH_LIST"
            ;;
        *)
            log_warn "Unrecognized selection '$sel' for $name -- treating as passthrough (safest default)"
            echo "$name" >> "$PASSTHROUGH_LIST"
            ;;
    esac
    case "$sel" in
        "MISSING-FROM-TARGET") log_warn "$name: MISSING-FROM-TARGET -- 07_rebuild_images.sh will leave this out of the package rather than substitute source's copy; confirm this partition is genuinely optional" ;;
    esac
done

record_status "merge_construction" PASS "source-portable trees merged into $PORT_ROOT; passthrough list at $PASSTHROUGH_LIST"

# ---- Strip stale ART artifacts from the merged tree (spec section 17) ---
stripped=0
while IFS= read -r -d '' f; do
    rm -f "$f"
    stripped=$((stripped + 1))
done < <(find "$PORT_ROOT" \( -iname '*.odex' -o -iname '*.vdex' -o -iname '*.art' -o -iname '*.dm' \) -print0 2>/dev/null)
record_status "art_strip" PASS "$stripped stale precompiled ART artifact(s) removed from merged tree; device will regenerate on first boot"

log_info "Merge complete. $PORT_ROOT ready for image rebuild."
