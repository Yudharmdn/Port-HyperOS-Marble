#!/usr/bin/env bash
# scripts/09_validate_package.sh -- Phase D (final gate) + Phase E.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/../config/port.env"

log_section 9 "FINAL VALIDATION MATRIX + PACKAGING"

# ---- AVB inspection (report-only; never silently disabled) --------------
avb_report="$REPORT_DIR/avb-report.md"
{ echo "# AVB state"; echo; echo "DISABLE_AVB_FOR_TESTING=${DISABLE_AVB_FOR_TESTING}"; echo; } > "$avb_report"
for img in "$IMG_DIR"/vbmeta*.img; do
    [ -f "$img" ] || continue
    { echo "## $(basename "$img")"; echo '```'; avbtool info_image --image "$img" 2>&1 || echo "(not an AVB-signed image or avbtool could not parse it)"; echo '```'; } >> "$avb_report"
done
if [ "${DISABLE_AVB_FOR_TESTING}" = "true" ] && [ -f "$IMG_DIR/vbmeta.img" ]; then
    # Standard AVB disable is flags=3 (HASHTREE_DISABLED | VERIFICATION_DISABLED)
    # on a freshly authored vbmeta, not truncating/erasing the original footer.
    # Written as a clearly separate side file -- the packaged vbmeta.img is
    # NEVER silently swapped for this; the flasher must consciously use it.
    if avbtool make_vbmeta_image --flags 3 --padding_size 4096 \
        --output "$IMG_DIR/vbmeta-DISABLED-VERIFICATION.img" 2>>"$avb_report"; then
        log_warn "DISABLE_AVB_FOR_TESTING=true: wrote vbmeta-DISABLED-VERIFICATION.img (flags=3) as a SEPARATE file. The packaged vbmeta.img is untouched -- swap it in yourself only if you understand the tradeoff. This omits any chained-partition descriptors the original vbmeta had; verify against avb-report.md before relying on it."
        record_status "avb_state" WARN "explicit opt-in: vbmeta-DISABLED-VERIFICATION.img produced alongside the normal, still-verified vbmeta.img"
    else
        log_warn "avbtool make_vbmeta_image failed -- see avb-report.md; packaged vbmeta.img is untouched either way"
        record_status "avb_state" WARN "DISABLE_AVB_FOR_TESTING=true requested but avbtool make_vbmeta_image failed; no AVB file was modified"
    fi
else
    record_status "avb_state" "NOT TESTED" "AVB left as target ROM ships it; report-only inspection in avb-report.md"
fi

# ---- Cross-check: boot.img replaced (08) vs. vbmeta's original descriptor --
# A hash/chain descriptor naming "boot" only matches the ORIGINAL boot.img's
# digest. Swapping boot.img (see boot-image-provenance.txt) without also
# handling AVB means the packaged vbmeta.img no longer describes what's
# actually in the package -- a real, checkable incompatibility, not a
# guess, so it is checked for rather than assumed away either direction.
boot_provenance="$REPORT_DIR/boot-image-provenance.txt"
if [ -f "$boot_provenance" ] && [ -f "$IMG_DIR/vbmeta.img" ]; then
    boot_descriptor_present=false
    if avbtool info_image --image "$IMG_DIR/vbmeta.img" 2>/dev/null \
        | grep -qiE '^[[:space:]]*Partition Name:[[:space:]]*boot[[:space:]]*$'; then
        boot_descriptor_present=true
    fi
    if [ "$boot_descriptor_present" = "true" ] && [ "${DISABLE_AVB_FOR_TESTING}" = "true" ]; then
        record_status "avb_boot_descriptor_mismatch" WARN "vbmeta.img's boot hash descriptor no longer matches the replaced boot.img (see boot-image-provenance.txt) -- mitigated by DISABLE_AVB_FOR_TESTING=true; flash vbmeta-DISABLED-VERIFICATION.img, not the packaged vbmeta.img"
    elif [ "$boot_descriptor_present" = "true" ]; then
        record_status "avb_boot_descriptor_mismatch" FAIL "boot.img was replaced (see boot-image-provenance.txt) but vbmeta.img still carries a hash descriptor for the ORIGINAL boot partition. AVB verification will fail on an enforcing bootloader. Set DISABLE_AVB_FOR_TESTING=true, or re-sign vbmeta yourself, before flashing."
    else
        record_status "avb_boot_descriptor_mismatch" WARN "boot.img was replaced; avbtool output did not clearly confirm a boot-partition descriptor either way (best-effort text match) -- verify avb-report.md manually before flashing regardless of DISABLE_AVB_FOR_TESTING"
    fi
fi

# ---- Compile final matrix -------------------------------------------------
matrix_md="$REPORT_DIR/build-summary.md"
{
    echo "# Build summary -- $SOURCE_DEVICE $SOURCE_BUILD (Android $SOURCE_ANDROID) -> $TARGET_DEVICE $TARGET_BUILD (Android $TARGET_ANDROID)"
    echo
    echo "| Check | Status | Detail |"
    echo "|---|---|---|"
} > "$matrix_md"
fail_count=0
while IFS=$'\t' read -r name state detail; do
    printf '| %s | %s | %s |\n' "$name" "$state" "$detail" >> "$matrix_md"
    [ "$state" = "FAIL" ] && fail_count=$((fail_count + 1))
done < "$STATUS_LEDGER"
{
    echo
    echo "BUILD STATUS: images produced by scripts 06-08"
    echo "PACKAGE STATUS: see below"
    echo "STATIC VALIDATION STATUS: $([ "$fail_count" -eq 0 ] && echo PASS || echo "FAIL ($fail_count check(s))")"
    echo "DEVICE BOOT TEST STATUS: NOT TESTED (no physical device in this run -- see scripts/11_diagnostics.sh)"
} >> "$matrix_md"

if [ "${ANALYSIS_ONLY}" = "true" ]; then
    log_info "ANALYSIS_ONLY=true -- stopping here by design. Review $matrix_md before setting ANALYSIS_ONLY=false."
    exit 0
fi

if [ "$fail_count" -gt 0 ] && [ "${FORCE_PACKAGE_DESPITE_FAIL:-false}" != "true" ]; then
    log_error "$fail_count FAIL-level finding(s) in the validation matrix. Refusing to package."
    log_error "Review $matrix_md. To override explicitly (NOT recommended), set FORCE_PACKAGE_DESPITE_FAIL=true."
    die "Static validation failed. This is not being silently downgraded to a warning."
fi
[ "${FORCE_PACKAGE_DESPITE_FAIL:-false}" = "true" ] && [ "$fail_count" -gt 0 ] && \
    log_warn "FORCE_PACKAGE_DESPITE_FAIL=true -- packaging despite $fail_count FAIL finding(s). This was an explicit, logged override, not a silent one."

# ---- Packaging (streaming update-binary, proven pattern) -----------------
NAME="${OUTPUT_NAME:-${TARGET_DEVICE}_HyperOS_Port}"
PKG_ROOT="$WORKDIR/package"
PKGDIR="$PKG_ROOT/${NAME}_zip"
rm -rf "$PKGDIR"; mkdir -p "$PKGDIR/META-INF/com/google/android" "$PKGDIR/images"

DYNAMIC_PARTS="system system_ext product mi_ext vendor vendor_dlkm odm odm_dlkm"
STATIC_PARTS="boot vendor_boot dtbo vbmeta vbmeta_system vbmeta_vendor"

for p in $DYNAMIC_PARTS $STATIC_PARTS; do
    [ -f "$IMG_DIR/${p}.img" ] && cp "$IMG_DIR/${p}.img" "$PKGDIR/images/"
done
FW_LIST="$PKGDIR/firmware_list.txt"; : > "$FW_LIST"
if [ -d "$WORK_TREE/extract_target/vendor/firmware-update" ]; then
    cp -r "$WORK_TREE/extract_target/vendor/firmware-update" "$PKGDIR/images/firmware-update"
    (cd "$PKGDIR/images/firmware-update" && for f in *.img; do [ -f "$f" ] && basename "$f" .img; done) > "$FW_LIST" 2>/dev/null || true
fi
cp "$REPORT_DIR"/*.md "$PKGDIR/" 2>/dev/null || true
for kf in "$WORKDIR"/*Kernel*.zip; do
    [ -f "$kf" ] && cp "$kf" "$PKG_ROOT/"
done

cat > "$PKGDIR/META-INF/com/google/android/updater-script" <<'EOF'
# Real logic is in update-binary + update-script.sh (shell, not edify).
EOF

cat > "$PKGDIR/update-script.sh" <<SCRIPTEOF
#!/sbin/sh
# update-script.sh <OUTFD> <ZIPFILE>
# Streaming installer: setiap image di-dd langsung dari dalam zip
# (unzip -p | dd), TIDAK di-extract dulu ke /tmp recovery yang biasanya
# tmpfs kecil -- paket ini bisa >7GB.
set -eu
ZIP="\$2"
ERRORS=0

ui_print() { printf 'ui_print %s\nui_print\n' "\$1" >> /proc/self/fd/"\$OUTFD" 2>/dev/null || printf '%s\n' "\$1"; }
zip_has_entry() { unzip -l "\$ZIP" "\$1" >/dev/null 2>&1; }
get_slot() { getprop ro.boot.slot_suffix 2>/dev/null || echo ""; }
SLOT="\$(get_slot)"

flash_static() {
    entry="images/\$1"; part="\$2"
    dev="/dev/block/bootdevice/by-name/\${part}\${SLOT}"
    [ -e "\$dev" ] || { ui_print "  !! \$dev tidak ada, dilewati"; return 0; }
    zip_has_entry "\$entry" || return 0
    devsize=\$(blockdev --getsize64 "\$dev" 2>/dev/null || echo 0)
    imgsize=\$(unzip -l "\$ZIP" "\$entry" | awk 'NR==4{print \$1}')
    if [ "\$devsize" -gt 0 ] && [ "\$imgsize" -gt "\$devsize" ]; then
        ui_print "  !! \$1 (\${imgsize}B) > partisi \$part (\${devsize}B) -- DILEWATI"
        ERRORS=\$((ERRORS + 1)); return 1
    fi
    ui_print "  Flashing \$1 -> \$part (static)"
    unzip -p "\$ZIP" "\$entry" | dd of="\$dev" bs=4M 2>/dev/null || { ui_print "  !! GAGAL flash \$1"; ERRORS=\$((ERRORS + 1)); }
}

flash_dynamic() {
    entry="images/\$1"; part="\$2"
    dev="/dev/block/mapper/\${part}\${SLOT}"
    [ -e "\$dev" ] || dev="/dev/block/mapper/\${part}"
    [ -e "\$dev" ] || { ui_print "  !! \$dev tidak ada, dilewati"; return 0; }
    zip_has_entry "\$entry" || return 0
    ui_print "  Flashing \$1 -> \$part (dynamic)"
    unzip -p "\$ZIP" "\$entry" | dd of="\$dev" bs=4M 2>/dev/null || { ui_print "  !! GAGAL flash \$1"; ERRORS=\$((ERRORS + 1)); }
}

ui_print "============================================"
ui_print " Port HyperOS $SOURCE_DEVICE $SOURCE_BUILD -> $TARGET_DEVICE"
ui_print "============================================"
ui_print "Tahap 1/3: partisi statis"
for p in $STATIC_PARTS; do flash_static "\${p}.img" "\$p"; done
ui_print "Tahap 2/3: partisi dinamis"
for p in $DYNAMIC_PARTS; do flash_dynamic "\${p}.img" "\$p"; done
ui_print "Tahap 3/3: firmware"
if zip_has_entry "firmware_list.txt"; then
    unzip -p "\$ZIP" firmware_list.txt > /tmp/port_fw_list.txt 2>/dev/null || true
    while IFS= read -r fwname; do [ -z "\$fwname" ] && continue; flash_static "firmware-update/\${fwname}.img" "\$fwname"; done < /tmp/port_fw_list.txt
    rm -f /tmp/port_fw_list.txt
fi
if [ "\$ERRORS" -gt 0 ]; then
    ui_print "SELESAI dengan \$ERRORS masalah -- CEK LOG sebelum reboot!"
    exit 1
fi
ui_print "Selesai tanpa error. Data TIDAK dihapus otomatis. Reboot ke system untuk uji boot."
exit 0
SCRIPTEOF
chmod +x "$PKGDIR/update-script.sh"

cat > "$PKGDIR/META-INF/com/google/android/update-binary" <<'BINEOF'
#!/sbin/sh
OUTFD="$2"; ZIP="$3"
TMPDIR=/tmp/port_rom_zip
rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
unzip -o "$ZIP" "update-script.sh" -d "$TMPDIR" >&2
sh "$TMPDIR/update-script.sh" "$OUTFD" "$ZIP"
RC=$?
rm -rf "$TMPDIR"
exit $RC
BINEOF
chmod +x "$PKGDIR/META-INF/com/google/android/update-binary"

mkdir -p "$WORKDIR/output"
( cd "$PKGDIR" && zip -r -X -q "$WORKDIR/output/${NAME}.zip" . )
( cd "$WORKDIR/output" && sha256sum ./*.zip > SHA256SUMS )
[ -d "$PKG_ROOT" ] && find "$PKG_ROOT" -maxdepth 1 -iname '*Kernel*.zip' -exec cp {} "$WORKDIR/output/" \;
cp "$REPORT_DIR"/*.md "$WORKDIR/output/" 2>/dev/null || true

record_status "packaging" PASS "recovery-flashable ZIP produced: $WORKDIR/output/${NAME}.zip (custom recovery only -- no fastboot flash.sh path)"
log_info "Package ready: $WORKDIR/output/"
log_info "NOTE: does not wipe /data. Clean vs dirty flash is the flasher's choice, per policy (spec section 31)."
