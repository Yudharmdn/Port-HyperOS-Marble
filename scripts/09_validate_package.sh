#!/usr/bin/env bash
# scripts/09_validate_package.sh -- Phase D (final gate) + Phase E.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/../config/port.env"

log_section 9 "FINAL VALIDATION MATRIX + PACKAGING"

# ---- AVB ------------------------------------------------------------------
# Every image this pipeline REBUILDS (system/system_ext/product/vendor/odm)
# no longer matches the hashtree descriptors in marble's vbmeta /
# vbmeta_system, and a replaced boot.img no longer matches its hash
# descriptor. Flashing the original vbmeta over such images = dm-verity
# corruption / verification failure at boot. So, for a real build:
#   DISABLE_AVB_FOR_TESTING=true  -> the PACKAGED vbmeta.img and
#       vbmeta_system.img are freshly authored flags=3 images (verity +
#       verification disabled; needs an unlocked bootloader). The
#       originals are kept beside them as *.ORIGINAL.img, never flashed.
#       (The old design left the original in the package and a side file
#       "to swap in yourself" -- the installer then flashed the original,
#       i.e. produced an unbootable result by default.)
#   DISABLE_AVB_FOR_TESTING=false -> FAIL: re-signing is not implemented.
# This is an explicit, logged opt-in, never a silent disable.
avb_report="$REPORT_DIR/avb-report.md"
{ echo "# AVB state"; echo; echo "DISABLE_AVB_FOR_TESTING=${DISABLE_AVB_FOR_TESTING}"; echo; } > "$avb_report"
for img in "$IMG_DIR"/vbmeta*.img; do
    [ -f "$img" ] || continue
    { echo "## $(basename "$img") (as shipped by $TARGET_DEVICE)"; echo '```'; avbtool info_image --image "$img" 2>&1 || echo "(not parseable by avbtool)"; echo '```'; } >> "$avb_report"
done

rebuilt_parts=""
for p in system system_ext product vendor odm; do
    grep -qP "^rebuild_${p}\tPASS\t" "$STATUS_LEDGER" 2>/dev/null && rebuilt_parts+="$p "
done
boot_replaced=false
[ -f "$REPORT_DIR/boot-image-provenance.txt" ] && boot_replaced=true

if [ "${ANALYSIS_ONLY}" = "true" ]; then
    record_status "avb_state" "NOT TESTED" "ANALYSIS_ONLY=true -- no images built, AVB not evaluated"
elif [ -z "$rebuilt_parts" ] && [ "$boot_replaced" = "false" ]; then
    record_status "avb_state" PASS "no verified image was modified; marble's vbmeta packaged as shipped"
elif [ "${DISABLE_AVB_FOR_TESTING}" = "true" ]; then
    avb_ok=true
    for v in vbmeta vbmeta_system; do
        [ -f "$IMG_DIR/${v}.img" ] || continue
        [ -f "$IMG_DIR/${v}.ORIGINAL.img" ] || mv "$IMG_DIR/${v}.img" "$IMG_DIR/${v}.ORIGINAL.img"
        if ! avbtool make_vbmeta_image --flags 3 --padding_size 4096 --output "$IMG_DIR/${v}.img" 2>>"$avb_report"; then
            avb_ok=false
            cp "$IMG_DIR/${v}.ORIGINAL.img" "$IMG_DIR/${v}.img"
        fi
    done
    if [ "$avb_ok" = "true" ]; then
        { echo "## packaged vbmeta (flags=3, authored by this pipeline)"; echo '```'; avbtool info_image --image "$IMG_DIR/vbmeta.img" 2>&1 || true; echo '```'; } >> "$avb_report"
        log_warn "AVB verification + dm-verity DISABLED in the packaged vbmeta/vbmeta_system (explicit DISABLE_AVB_FOR_TESTING=true). Requires an UNLOCKED bootloader. Originals kept as *.ORIGINAL.img (not flashed)."
        record_status "avb_state" WARN "explicit opt-in: packaged vbmeta + vbmeta_system are flags=3 (verity/verification off, unlocked bootloader required) because rebuilt=[${rebuilt_parts}] boot_replaced=${boot_replaced} invalidate the original descriptors"
    else
        record_status "avb_state" FAIL "DISABLE_AVB_FOR_TESTING=true but avbtool could not author the flags=3 vbmeta -- see avb-report.md; original vbmeta would fail verification over the rebuilt images"
    fi
else
    record_status "avb_state" FAIL "rebuilt=[${rebuilt_parts}] boot_replaced=${boot_replaced}: these no longer match the hashtree/hash descriptors in marble's vbmeta/vbmeta_system -> verification / dm-verity failure at boot. Set DISABLE_AVB_FOR_TESTING=true (unlocked bootloader) -- re-signing is not implemented."
fi

# ---- Dynamic partition group capacity: AUTHORITATIVE check on built images --
# Real limit = marble's group size from its own OTA payload manifest (04).
# Sizes = the actual images about to be packaged, not estimates.
TGT_META="$REPORT_DIR/target_payload_meta.json"
if [ "${ANALYSIS_ONLY}" != "true" ]; then
    if [ -f "$TGT_META" ]; then
        {
            echo
            echo "# AUTHORITATIVE check -- actual built images vs marble's real group limit"
        } >> "$REPORT_DIR/dynamic_partition_sizing.txt"
        set +e
        python3 "$SCRIPT_DIR/lib/dynamic_fit.py" built "$TGT_META" "$IMG_DIR" >> "$REPORT_DIR/dynamic_partition_sizing.txt" 2>&1
        fit_rc=$?
        set -e
        case "$fit_rc" in
            0) record_status "dynamic_partition_sizing" PASS "built images fit marble's real dynamic partition group limit (read from its OTA payload manifest) -- see dynamic_partition_sizing.txt" ;;
            1) record_status "dynamic_partition_sizing" FAIL "built images EXCEED marble's real dynamic partition group limit -- they cannot all be written to super. Options: VENDOR_ODM_FS=erofs, lower EXT4_MARGIN_PCT, or remove apps from product. See dynamic_partition_sizing.txt" ;;
            *) record_status "dynamic_partition_sizing" WARN "target payload has no dynamic partition group metadata -- group capacity unverified; check with lpdump on-device" ;;
        esac
    else
        record_status "dynamic_partition_sizing" WARN "no target payload manifest -- group capacity unverified; check with lpdump on-device"
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
    # Partisi logis di super punya ukuran SEKARANG milik ROM lama. Image
    # hasil port bisa lebih besar -- dd ke partisi yang lebih kecil akan
    # terpotong di tengah. Cek dulu; coba resize via lptools kalau ada.
    devsize=\$(blockdev --getsize64 "\$dev" 2>/dev/null || echo 0)
    imgsize=\$(unzip -l "\$ZIP" "\$entry" | awk 'NR==4{print \$1}')
    if [ "\$devsize" -gt 0 ] && [ "\$imgsize" -gt "\$devsize" ]; then
        if command -v lptools >/dev/null 2>&1; then
            ui_print "  \$part terlalu kecil (\${devsize}B < \${imgsize}B), resize via lptools..."
            lptools resize "\${part}\${SLOT}" "\$imgsize" >/dev/null 2>&1 || lptools resize "\$part" "\$imgsize" >/dev/null 2>&1 || true
            devsize=\$(blockdev --getsize64 "\$dev" 2>/dev/null || echo 0)
        fi
        if [ "\$imgsize" -gt "\$devsize" ]; then
            ui_print "  !! \$1 (\${imgsize}B) > partisi \$part (\${devsize}B) dan tidak bisa di-resize di recovery ini"
            ui_print "  !! Pakai flash_fastboot.sh / .bat (fastbootd resize otomatis)"
            ERRORS=\$((ERRORS + 1)); return 1
        fi
    fi
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

# ---- fastboot path (fastbootd resizes logical partitions itself) --------
# Recommended when the ported images are bigger than marble's current
# logical partitions and the recovery has no lptools. Run from the
# extracted zip's folder with the phone in bootloader (fastboot) mode.
{
    echo '#!/usr/bin/env bash'
    echo '# Flash port via fastboot. Bootloader must be UNLOCKED. Data is NOT wiped.'
    echo 'set -e'
    echo 'cd "$(dirname "$0")/images"'
    echo 'f() { [ -f "$2" ] && fastboot flash "$1" "$2"; }'
    for p in $STATIC_PARTS; do echo "f $p $p.img"; done
    echo 'if [ -d firmware-update ]; then for i in firmware-update/*.img; do n=$(basename "$i" .img); fastboot flash "$n" "$i"; done; fi'
    echo 'fastboot reboot fastboot'
    for p in $DYNAMIC_PARTS; do
        echo "fastboot delete-logical-partition ${p}_a-cow 2>/dev/null || true"
        echo "fastboot delete-logical-partition ${p}_b-cow 2>/dev/null || true"
        echo "f $p $p.img"
    done
    echo 'fastboot reboot'
} > "$PKGDIR/flash_fastboot.sh"
chmod +x "$PKGDIR/flash_fastboot.sh"
{
    printf '@echo off\r\n'
    printf 'rem Flash port via fastboot. Bootloader must be UNLOCKED. Data is NOT wiped.\r\n'
    printf 'cd /d "%%~dp0images"\r\n'
    for p in $STATIC_PARTS; do printf 'if exist %s.img fastboot flash %s %s.img\r\n' "$p" "$p" "$p"; done
    printf 'if exist firmware-update for %%%%i in (firmware-update\\*.img) do fastboot flash %%%%~ni %%%%i\r\n'
    printf 'fastboot reboot fastboot\r\n'
    for p in $DYNAMIC_PARTS; do
        printf 'fastboot delete-logical-partition %s_a-cow\r\n' "$p"
        printf 'fastboot delete-logical-partition %s_b-cow\r\n' "$p"
        printf 'if exist %s.img fastboot flash %s %s.img\r\n' "$p" "$p" "$p"
    done
    printf 'fastboot reboot\r\npause\r\n'
} > "$PKGDIR/flash_fastboot.bat"

mkdir -p "$WORKDIR/output"
( cd "$PKGDIR" && zip -r -X -q "$WORKDIR/output/${NAME}.zip" . )
( cd "$WORKDIR/output" && sha256sum ./*.zip > SHA256SUMS )
[ -d "$PKG_ROOT" ] && find "$PKG_ROOT" -maxdepth 1 -iname '*Kernel*.zip' -exec cp {} "$WORKDIR/output/" \;
cp "$REPORT_DIR"/*.md "$WORKDIR/output/" 2>/dev/null || true

record_status "packaging" PASS "recovery-flashable ZIP produced: $WORKDIR/output/${NAME}.zip (recovery installer + flash_fastboot.sh/.bat)"
log_info "Package ready: $WORKDIR/output/"
log_info "NOTE: does not wipe /data. Clean vs dirty flash is the flasher's choice, per policy (spec section 31)."
