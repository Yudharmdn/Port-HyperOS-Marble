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
    # Extract as root, PRESERVING ownership, permissions, SELinux labels
    # and file capabilities exactly as the device maker built them.
    # Earlier versions dropped all of these (plain extraction as the
    # runner user), which is what forced the lossy relabel step and left
    # fs_config (uid/gid/mode/caps) unreproduced. fsck.erofs here is the
    # patched v1.9.4 from 01_toolchain.sh (--xattrs, caps kept past chown).
    case "$fs" in
        erofs)
            sudo fsck.erofs --extract="$out/$part" --xattrs --preserve "$img" >/dev/null 2>&1 \
                || die "erofs extraction failed for $part"
            ;;
        ext4)
            local mnt="$WORK_TREE/.mnt_$part"
            mkdir -p "$mnt"
            if sudo mount -o loop,ro "$img" "$mnt" 2>/dev/null; then
                sudo rsync -aHAX "$mnt/" "$out/$part/" || { sudo umount "$mnt"; die "ext4 copy failed for $part"; }
                sudo umount "$mnt"
            else
                log_warn "loop mount failed for $part -- falling back to debugfs rdump (ownership kept, SELinux labels/capabilities NOT preserved for this partition)"
                sudo debugfs -R "rdump / $out/$part" "$img" >/dev/null 2>&1 || die "ext4 (debugfs rdump) extraction failed for $part"
            fi
            rmdir "$mnt" 2>/dev/null || true
            ;;
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
# How libvintf actually decides compatibility (source.android.com, VINTF
# match rules / FCM lifecycle): it reads the device manifest's
# target-level and uses the framework compatibility matrix AT THAT
# LEVEL. Since the Android V-era libvintf change "<matrix><hal> optional
# attr has default value true" (and the optional tag being unsupported
# from Android 16), a HAL listed in an Android 17 matrix is NOT required
# unless explicitly marked optional="false". The previous check counted
# every listed HAL as required and picked an arbitrary matrix file
# (find | head -n1) -- which is where the 43 "missing" automotive /
# broadcastradio / etc. HALs came from. The real gates are:
#   a) the source framework ships compatibility_matrix.<target-level>.xml
#      (i.e. it still supports marble's vendor FCM level) -- hard FAIL if not;
#   b) the kernel version marble runs is allowed by that matrix;
#   c) every HAL that matrix marks optional="false" is in marble's manifests.
vintf_report="$REPORT_DIR/vintf-report.md"
vintf_fail=0
{
    echo "# VINTF compatibility (framework matrix at marble's FCM level)"
    echo
    echo "Scope: selects the SOURCE framework compatibility matrix matching the"
    echo "TARGET device manifest's target-level (as libvintf does), checks that"
    echo "level is still supported, checks its kernel requirement against"
    echo "TARGET_KERNEL_VERSION, and requires only HALs explicitly marked"
    echo "optional=\"false\" (Android 16+: optional defaults to true). Does NOT"
    echo "run libvintf itself, and does NOT verify runtime HAL behavior."
    echo
} > "$vintf_report"

dev_manifest="$(find "$EXTRACT_TGT/vendor" -path '*etc/vintf/manifest.xml' 2>/dev/null | head -n1 || true)"
target_level=""
if [ -n "$dev_manifest" ]; then
    target_level="$(xmllint --xpath 'string(/manifest/@target-level)' "$dev_manifest" 2>/dev/null || true)"
fi
manifest_files="$(find "$EXTRACT_TGT" -path '*etc/vintf/manifest*.xml' 2>/dev/null || true)"
supported_levels="$(find "$EXTRACT_SRC" -path '*etc/vintf/compatibility_matrix.*.xml' 2>/dev/null \
    | sed -E 's#.*/compatibility_matrix\.([^/]+)\.xml$#\1#' | grep -v '^device$' | sort -uV | tr '\n' ' ' || true)"
echo "- target device manifest: \`${dev_manifest#"$EXTRACT_TGT"/}\`, target-level=\`${target_level:-unknown}\`" >> "$vintf_report"
echo "- FCM levels the source framework supports: \`${supported_levels:-none found}\`" >> "$vintf_report"

if [ -z "$target_level" ]; then
    record_status "vintf_analysis" WARN "could not read target-level from marble's vendor manifest -- manual VINTF review required"
else
    matrix_file="$(find "$EXTRACT_SRC" -path "*etc/vintf/compatibility_matrix.${target_level}.xml" 2>/dev/null | head -n1 || true)"
    if [ -z "$matrix_file" ]; then
        vintf_fail=1
        echo "- **FAIL**: no \`compatibility_matrix.${target_level}.xml\` in the source framework -- it no longer supports marble's vendor FCM level" >> "$vintf_report"
        record_status "vintf_fcm_level" FAIL "source framework has no compatibility matrix for marble's FCM target-level ${target_level} (supports: ${supported_levels:-none}) -- libvintf will reject this vendor; not fixable by porting scripts"
    else
        echo "- matrix used: \`${matrix_file#"$EXTRACT_SRC"/}\`" >> "$vintf_report"
        record_status "vintf_fcm_level" PASS "source framework still ships compatibility_matrix.${target_level}.xml (marble's FCM target-level)"

        # b) kernel requirement
        kvers="$(xmllint --xpath '//kernel/@version' "$matrix_file" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -uV || true)"
        tk="${TARGET_KERNEL_VERSION:-5.10}"
        if [ -z "$kvers" ]; then
            echo "- kernel: matrix at this level lists no kernel requirement" >> "$vintf_report"
            record_status "vintf_kernel" PASS "matrix at level ${target_level} sets no kernel version requirement"
        elif grep -q "^${tk//./\\.}\." <<< "$kvers"; then
            echo "- kernel: matrix allows ${tk}.x (listed: $(tr '\n' ' ' <<< "$kvers"))" >> "$vintf_report"
            record_status "vintf_kernel" PASS "matrix at level ${target_level} allows kernel ${tk}.x"
        else
            vintf_fail=1
            echo "- **FAIL** kernel: matrix does not allow ${tk}.x (listed: $(tr '\n' ' ' <<< "$kvers"))" >> "$vintf_report"
            record_status "vintf_kernel" FAIL "matrix at level ${target_level} does not list kernel ${tk}.x (allows: $(tr '\n' ' ' <<< "$kvers"))"
        fi

        # c) explicitly required HALs
        required_hals="$(xmllint --xpath '//hal[@optional="false"]/name/text()' "$matrix_file" 2>/dev/null | sort -u || true)"
        present_hals=""
        for mf in $manifest_files; do
            present_hals+="$(xmllint --xpath '//hal/name/text()' "$mf" 2>/dev/null || true)"$'\n'
        done
        present_hals="$(printf '%s' "$present_hals" | sort -u)"
        {
            echo
            echo "| required HAL (optional=\"false\") | present in marble manifests | status |"
            echo "|---|---|---|"
        } >> "$vintf_report"
        missing_required=0
        while read -r hal; do
            [ -z "$hal" ] && continue
            if grep -qx "$hal" <<< "$present_hals"; then
                echo "| $hal | yes | PASS |" >> "$vintf_report"
            else
                echo "| $hal | **no** | FAIL |" >> "$vintf_report"
                missing_required=$((missing_required + 1))
            fi
        done <<< "$required_hals"
        [ -n "$required_hals" ] || echo "| (none -- every HAL at this level is optional) | - | PASS |" >> "$vintf_report"
        if [ "$missing_required" -gt 0 ]; then
            vintf_fail=1
            record_status "vintf_required_hals" FAIL "$missing_required HAL(s) marked optional=\"false\" in the level-${target_level} matrix are missing from marble's manifests -- see vintf-report.md"
        else
            record_status "vintf_required_hals" PASS "no HAL explicitly required (optional=\"false\") by the level-${target_level} matrix is missing"
        fi
    fi
fi
echo "vintf_fail=$vintf_fail" > "$REPORT_DIR/vintf_result.txt"

# ---- 2. SELinux: Treble policy compatibility ------------------------------
# A new platform sepolicy runs against an older vendor policy only through
# the versioned mapping files the platform ships: system/etc/selinux/
# mapping/<vendor_ver>.cil (+ <ver>.compat.cil), where <vendor_ver> is in
# the vendor's plat_sepolicy_vers.txt. If the mapping for marble's vendor
# version exists, init can compile the split policy and every NEW type in
# the platform is covered by design -- counting "new types" (the old
# check's 1762) measures nothing that decides boot. If the mapping is
# absent, the policy will not compile at boot: that is a hard FAIL.
selinux_report="$REPORT_DIR/selinux-report.md"
{
    echo "# SELinux Treble policy compatibility"
    echo
    echo "Scope: checks that the SOURCE platform policy ships the mapping for"
    echo "marble's vendor sepolicy version. Runtime denials are NOT predicted"
    echo "here -- collect avc: denied from a real boot (11_diagnostics.sh)."
    echo
} > "$selinux_report"
vers_file="$(find "$EXTRACT_TGT/vendor" -path '*etc/selinux/plat_sepolicy_vers.txt' 2>/dev/null | head -n1 || true)"
vendor_sepol_ver=""
[ -n "$vers_file" ] && vendor_sepol_ver="$(sudo cat "$vers_file" 2>/dev/null | tr -d '[:space:]' || true)"
mappings="$(find "$EXTRACT_SRC" -path '*etc/selinux/mapping/*.cil' 2>/dev/null | sed -E 's#.*/##' | sort -u | tr '\n' ' ' || true)"
{
    echo "- marble vendor sepolicy version: \`${vendor_sepol_ver:-unknown}\`"
    echo "- mapping files in source platform: \`${mappings:-none found}\`"
} >> "$selinux_report"
if [ -z "$vendor_sepol_ver" ]; then
    record_status "selinux_mapping" WARN "could not read marble's vendor plat_sepolicy_vers.txt -- manual sepolicy review required"
elif find "$EXTRACT_SRC" -path "*etc/selinux/mapping/${vendor_sepol_ver}.cil" 2>/dev/null | grep -q .; then
    echo "- **PASS**: \`mapping/${vendor_sepol_ver}.cil\` present" >> "$selinux_report"
    record_status "selinux_mapping" PASS "source platform ships mapping/${vendor_sepol_ver}.cil for marble's vendor policy version -- split policy can compile"
else
    echo "- **FAIL**: \`mapping/${vendor_sepol_ver}.cil\` missing" >> "$selinux_report"
    record_status "selinux_mapping" FAIL "source platform has no mapping/${vendor_sepol_ver}.cil for marble's vendor sepolicy version -- split policy will not compile at boot"
fi

# ---- 3. Linker / ELF dependency check -----------------------------------
linker_report="$REPORT_DIR/linker-report.md"
{
    echo "# Linker dependency compatibility (automated first pass)"
    echo
    echo "Scope: for every ELF file under the ported system/system_ext/"
    echo "product tree, lists DT_NEEDED entries and checks whether a"
    echo "library of that SONAME exists anywhere in source+target system/"
    echo "vendor/odm, INCLUDING inside Mainline APEX modules (both .apex"
    echo "and compressed .capex are unpacked for this inventory)."
    echo "This catches missing libraries, NOT symbol-version mismatches"
    echo "within a present library of the same name."
    echo
    echo "| consumer | missing NEEDED | status |"
    echo "|---|---|---|"
} > "$linker_report"

# APEX-aware inventory. A real run found every one of its "missing"
# libraries (libicu.so, libstatssocket.so, libstatspull.so,
# libcom.android.tethering.connectivity_native.so, etc.) to actually be
# a well-known Mainline APEX module library this check hadn't unpacked
# -- 100% false positives on that run. An uncompressed .apex is just a
# zip containing apex_payload.img, itself an ext4 or erofs image --
# unpacked below with the exact tools already used for the partitions
# themselves.
extract_apex_libs() {
    # Unpacks every APEX under $1 just far enough to inventory its .so
    # files. .apex = zip holding apex_payload.img (ext4/erofs). .capex
    # (compressed APEX) = zip holding the whole original .apex as the
    # deflated member "original_apex" (AOSP APEX format docs) -- a real
    # run showed 25 such modules (ART, i18n, statsd, tethering...) are
    # exactly where every remaining "missing" library lived.
    local root="$1" out="$2"
    mkdir -p "$out"
    local n_apex=0 n_capex=0 n_fail=0
    unpack_one() {
        local apexfile="$1" dest="$2"
        mkdir -p "$dest/root"
        unzip -p "$apexfile" apex_payload.img > "$dest/apex_payload.img" 2>/dev/null || true
        [ -s "$dest/apex_payload.img" ] || return 1
        local ftype
        ftype="$(file -b "$dest/apex_payload.img" 2>/dev/null)"
        if grep -qi erofs <<< "$ftype"; then
            fsck.erofs --extract="$dest/root" "$dest/apex_payload.img" >/dev/null 2>&1 || return 1
        elif grep -qi ext4 <<< "$ftype"; then
            debugfs -R "rdump / $dest/root" "$dest/apex_payload.img" >/dev/null 2>&1 || return 1
        else
            return 1
        fi
        rm -f "$dest/apex_payload.img"
        # only the library names are needed -- drop everything else
        find "$dest/root" -type f ! -name '*.so' ! -name '*.so.*' -delete 2>/dev/null || true
        return 0
    }
    while IFS= read -r -d '' apex; do
        if unpack_one "$apex" "$out/$(basename "$apex")"; then n_apex=$((n_apex + 1)); else n_fail=$((n_fail + 1)); fi
    done < <(find "$root" -iname '*.apex' -type f -print0 2>/dev/null)
    while IFS= read -r -d '' capex; do
        local d
        d="$out/$(basename "$capex")"
        mkdir -p "$d"
        if unzip -p "$capex" original_apex > "$d/original.apex" 2>/dev/null && [ -s "$d/original.apex" ] \
            && unpack_one "$d/original.apex" "$d"; then
            n_capex=$((n_capex + 1))
        else
            n_fail=$((n_fail + 1))
        fi
        rm -f "$d/original.apex"
    done < <(find "$root" -iname '*.capex' -type f -print0 2>/dev/null)
    log_info "APEX inventory under $root: $n_apex .apex + $n_capex .capex unpacked, $n_fail failed"
    [ "$n_fail" -eq 0 ] || log_warn "$n_fail APEX module(s) under $root could not be unpacked -- libraries inside them may show as false-positive missing"
    return 0
}
APEX_LIBS_DIR="$WORK_TREE/apex_libs_extracted"
extract_apex_libs "$EXTRACT_SRC" "$APEX_LIBS_DIR/src"
extract_apex_libs "$EXTRACT_TGT" "$APEX_LIBS_DIR/tgt"

lib_inventory="$(find "$EXTRACT_SRC" "$EXTRACT_TGT" "$APEX_LIBS_DIR" \( -iname '*.so' -o -iname '*.so.*' \) -print0 2>/dev/null | xargs -r -0 -n1 basename | sort -u)"
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
