#!/usr/bin/env bash
# scripts/05_compatibility_analysis.sh -- Phase A steps 17-24 / Phase D
# (static half). This is the core "do not fake compatibility" stage:
# every check here is real static analysis against extracted files, and
# every report says plainly what it did and did not verify. Nothing a
# physical device would need to confirm (symbol-level ABI, runtime HAL
# behavior, actual boot) is claimed as PASS here -- those stay
# "NOT TESTED" until scripts/11_diagnostics.sh runs against real hardware.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/../config/port.env"

EXTRACT_SRC="$WORK_TREE/extract_source"
EXTRACT_TGT="$WORK_TREE/extract_target"
mkdir -p "$EXTRACT_SRC" "$EXTRACT_TGT" "$REPORT_DIR"

extract_partition() {
    # extract_partition <img_dir> <partition_name> <fs> <out_root>
    local imgdir="$1" part="$2" fs="$3" out="$4"
    local img="$imgdir/partitions/${part}.img"
    [ -f "$img" ] || { log_warn "extract_partition: $img not found, skipping"; return 1; }
    mkdir -p "$out/$part"
    case "$fs" in
        erofs) fsck.erofs --extract="$out/$part" "$img" >/dev/null 2>&1 || die "erofs extraction failed for $part" ;;
        ext4)  debugfs -R "rdump / $out/$part" "$img" >/dev/null 2>&1 || die "ext4 (debugfs rdump) extraction failed for $part" ;;
        *) log_warn "extract_partition: unknown fs '$fs' for $part, skipping"; return 1 ;;
    esac
}

log_section 5 "COMPATIBILITY ANALYSIS (VINTF / SELinux / linker / ART / props)"

declare -A SRC_FS TGT_FS
while IFS=$'\t' read -r name _ fs; do SRC_FS[$name]="$fs"; done < "$REPORT_DIR/source_partition_inventory.tsv"
while IFS=$'\t' read -r name _ fs; do TGT_FS[$name]="$fs"; done < "$REPORT_DIR/target_partition_inventory.tsv"

for p in system system_ext product; do
    [ -n "${SRC_FS[$p]:-}" ] && extract_partition "$SRC_DIR" "$p" "${SRC_FS[$p]}" "$EXTRACT_SRC"
done
for p in vendor odm; do
    [ -n "${TGT_FS[$p]:-}" ] && extract_partition "$TGT_DIR" "$p" "${TGT_FS[$p]}" "$EXTRACT_TGT"
done

# ---- 1. VINTF -----------------------------------------------------------
vintf_report="$REPORT_DIR/vintf-report.md"
{
    echo "# VINTF compatibility (automated first pass)"
    echo
    echo "Scope: extracts <hal name+version+interface+instance> tuples from"
    echo "the SOURCE framework compatibility matrix and the TARGET vendor/odm"
    echo "manifests, and flags HALs the matrix requires that no target"
    echo "manifest declares. Does NOT verify runtime instance behavior."
    echo
    echo "| hal | required (source matrix) | present (target manifest) | status |"
    echo "|---|---|---|---|"
} > "$vintf_report"

matrix_file="$(find "$EXTRACT_SRC/system" -path '*etc/vintf/compatibility_matrix*.xml' 2>/dev/null | head -n1 || true)"
manifest_files="$(find "$EXTRACT_TGT" -path '*etc/vintf/manifest*.xml' 2>/dev/null || true)"

if [ -z "$matrix_file" ] || [ -z "$manifest_files" ]; then
    record_status "vintf_analysis" WARN "matrix or manifest XML not found at expected paths -- manual VINTF review required"
    echo "| (none found) | - | - | NOT TESTED |" >> "$vintf_report"
else
    required_hals="$(xmllint --xpath '//hal/name/text()' "$matrix_file" 2>/dev/null | sort -u || true)"
    present_hals=""
    for mf in $manifest_files; do
        present_hals+="$(xmllint --xpath '//hal/name/text()' "$mf" 2>/dev/null || true)"$'\n'
    done
    present_hals="$(printf '%s' "$present_hals" | sort -u)"

    fail_count=0
    while read -r hal; do
        [ -z "$hal" ] && continue
        if grep -qx "$hal" <<< "$present_hals"; then
            echo "| $hal | yes | yes | PASS |" >> "$vintf_report"
        else
            echo "| $hal | yes | **no** | FAIL |" >> "$vintf_report"
            fail_count=$((fail_count + 1))
        fi
    done <<< "$required_hals"

    if [ "$fail_count" -gt 0 ]; then
        record_status "vintf_analysis" FAIL "$fail_count required HAL(s) missing from target manifests -- see vintf-report.md"
    else
        record_status "vintf_analysis" WARN "no missing HAL names detected at the name-level; instance/version-level and AIDL/HIDL interface detail were not exhaustively verified"
    fi
fi

# ---- 2. SELinux contexts ------------------------------------------------
selinux_report="$REPORT_DIR/selinux-report.md"
{
    echo "# SELinux context compatibility (automated first pass)"
    echo
    echo "Scope: diffs the SET of context TYPES referenced in source"
    echo "file_contexts against types known to target policy files. New"
    echo "types are flagged for MANUAL sepolicy authoring -- this pipeline"
    echo "never auto-generates allow rules, per policy."
    echo
} > "$selinux_report"

extract_types() { grep -hoE ':[a-zA-Z0-9_]+:s0' "$@" 2>/dev/null | sort -u || true; }
src_ctx_files="$(find "$EXTRACT_SRC" -iname '*_contexts' -o -iname '*file_contexts*' 2>/dev/null || true)"
tgt_ctx_files="$(find "$EXTRACT_TGT" -iname '*_contexts' -o -iname '*file_contexts*' 2>/dev/null || true)"

if [ -z "$src_ctx_files" ] || [ -z "$tgt_ctx_files" ]; then
    record_status "selinux_analysis" WARN "context files not found at expected paths -- manual sepolicy review required"
    echo "(context files not found; manual review required)" >> "$selinux_report"
else
    # shellcheck disable=SC2086
    src_types="$(extract_types $src_ctx_files)"
    # shellcheck disable=SC2086
    tgt_types="$(extract_types $tgt_ctx_files)"
    new_types="$(comm -23 <(printf '%s\n' "$src_types") <(printf '%s\n' "$tgt_types") | grep -v '^$' || true)"
    new_count="$(printf '%s\n' "$new_types" | grep -vc '^$' || true)"
    {
        echo "New context types referenced by source, absent from target policy:"
        echo '```'
        printf '%s\n' "$new_types"
        echo '```'
    } >> "$selinux_report"
    if [ "$new_count" -gt 0 ]; then
        record_status "selinux_analysis" WARN "$new_count new SELinux type(s) need manual sepolicy authoring -- see selinux-report.md; NOT auto-generated"
    else
        record_status "selinux_analysis" PASS "no new context types found beyond target policy"
    fi
fi

# ---- 3. Linker / ELF dependency check -----------------------------------
linker_report="$REPORT_DIR/linker-report.md"
{
    echo "# Linker dependency compatibility (automated first pass)"
    echo
    echo "Scope: for every ELF file under the ported system/system_ext/"
    echo "product tree, lists DT_NEEDED entries and checks whether a"
    echo "library of that SONAME exists anywhere in source+target system/"
    echo "vendor/odm. This catches missing libraries, NOT symbol-version"
    echo "mismatches within a present library of the same name."
    echo
    echo "| consumer | missing NEEDED | status |"
    echo "|---|---|---|"
} > "$linker_report"

lib_inventory="$(find "$EXTRACT_SRC" "$EXTRACT_TGT" \( -iname '*.so' -o -iname '*.so.*' \) -print0 2>/dev/null | xargs -r -0 -n1 basename | sort -u)"
missing_total=0
while IFS= read -r -d '' elf; do
    file -b "$elf" 2>/dev/null | grep -q ELF || continue
    needed="$(readelf -d "$elf" 2>/dev/null | grep NEEDED | sed -E 's/.*\[(.*)\].*/\1/' || true)"
    [ -z "$needed" ] && continue
    missing=""
    while read -r lib; do
        [ -z "$lib" ] && continue
        grep -qx "$lib" <<< "$lib_inventory" || missing+="$lib "
    done <<< "$needed"
    if [ -n "$missing" ]; then
        echo "| ${elf#"$EXTRACT_SRC"/} | $missing | FAIL |" >> "$linker_report"
        missing_total=$((missing_total + 1))
    fi
done < <(find "$EXTRACT_SRC/system" -type f \( -iname '*.so' -o -perm -u+x \) -print0 2>/dev/null)

if [ "$missing_total" -gt 0 ]; then
    record_status "linker_analysis" FAIL "$missing_total binaries reference a NEEDED library not found anywhere in source+target -- see linker-report.md"
else
    record_status "linker_analysis" WARN "no missing SONAMEs by name; symbol-level ABI compatibility was NOT checked"
fi

# ---- 4. ART / odex / vdex staleness -------------------------------------
art_count="$(find "$EXTRACT_SRC" \( -iname '*.odex' -o -iname '*.vdex' -o -iname '*.art' -o -iname '*.dm' \) 2>/dev/null | wc -l)"
echo "$art_count" > "$REPORT_DIR/stale_art_artifact_count.txt"
if [ "$art_count" -gt 0 ]; then
    record_status "art_staleness" WARN "$art_count precompiled ART artifact(s) found in ported source tree -- will be stripped in 06_merge_port.sh so the device regenerates them; boot classpath consistency was NOT independently verified"
else
    record_status "art_staleness" PASS "no stale precompiled ART artifacts found in ported tree"
fi

# ---- 5. build.prop / property classification ----------------------------
props_report="$REPORT_DIR/build-prop-diff.md"
{
    echo "# build.prop property classification"
    echo
    echo "Device-identity and hardware properties are NOT changed by this"
    echo "pipeline; only informational diff below. Physical hardware must"
    echo "keep claiming to be $TARGET_DEVICE, never $SOURCE_DEVICE."
    echo
} > "$props_report"
src_props="$(find "$EXTRACT_SRC" -iname 'build.prop' 2>/dev/null | head -n1 || true)"
tgt_props="$(find "$EXTRACT_TGT" -iname 'build.prop' 2>/dev/null | head -n1 || true)"
if [ -n "$src_props" ] && [ -n "$tgt_props" ]; then
    {
        echo '```diff'
        diff <(grep -E '^ro\.(product|build|vendor|boot|hardware|board|soc)\.' "$src_props" | sort) \
             <(grep -E '^ro\.(product|build|vendor|boot|hardware|board|soc)\.' "$tgt_props" | sort) || true
        echo '```'
    } >> "$props_report"
    record_status "build_prop_diff" PASS "identity/hardware property diff recorded; target values will be preserved by default in 07_rebuild_images.sh"
else
    record_status "build_prop_diff" WARN "build.prop not found on one side -- manual review required"
fi

log_info "Compatibility analysis complete. Reports: $REPORT_DIR/{vintf,selinux,linker,build-prop-diff}*"
if ledger_has_fail && [ "${ANALYSIS_ONLY:-true}" != "true" ]; then
    log_warn "FAIL-level findings exist and ANALYSIS_ONLY=false -- construction phases will still run per spec (analysis reports, does not silently block), but packaging validation in 09 will refuse to produce a ZIP while unresolved FAILs remain."
fi
