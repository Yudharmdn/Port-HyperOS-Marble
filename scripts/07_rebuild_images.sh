#!/usr/bin/env bash
# scripts/07_rebuild_images.sh -- Phase C steps 28-30.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/../config/port.env"

require_not_analysis_only "image rebuild"

log_section 7 "PATCH FSTAB + REBUILD PARTITION IMAGES"

PORT_ROOT="$WORK_TREE/port_root"
VENDOR_WORK="$WORK_TREE/vendor_root"
ODM_WORK="$WORK_TREE/odm_root"
mkdir -p "$IMG_DIR"

declare -A SRC_FS
while IFS=$'\t' read -r name _ fs; do SRC_FS[$name]="$fs"; done < "$REPORT_DIR/source_partition_inventory.tsv"

# ---- 1. fstab patch --------------------------------------------------
# Trees are root-owned with preserved labels, so every edit is done on a
# temp copy and written back with `sudo tee` (same inode: owner, mode and
# security.selinux survive -- `sed -i` would create an unlabeled file).
# The .orig backup goes to the report dir, never into the image.
#
# Fixed: the previous ro->rw flip used awk gsub() with "\1rw\2"; awk has
# no backreferences, so it wrote the literal text "\1rw\2" into the mount
# flags (verified), which would break the /vendor mount. The flip now
# edits the comma-separated flag list field-by-field, and only on ext4
# lines (erofs is read-only by design; a rw flag there means nothing).
FSTAB_BACKUP_DIR="$REPORT_DIR/fstab-original"
mkdir -p "$FSTAB_BACKUP_DIR"
patch_fstab_tree() {
    local root="$1" label="$2"
    local count=0
    while IFS= read -r -d '' fstab; do
        local tmp
        tmp="$(mktemp)"
        # shellcheck disable=SC2024  # reading as root into a user-owned temp file is intended
        sudo cat "$fstab" > "$tmp"
        cp "$tmp" "$FSTAB_BACKUP_DIR/${label}_$(basename "$fstab")"
        if [ "${DISABLE_FORCEENCRYPT:-true}" = "true" ]; then
            sed -i -E \
                -e 's/,?forceencrypt=[^,[:space:]]*//g' \
                -e 's/,?fileencryption=[^,[:space:]]*//g' \
                -e 's/,?metadata_encryption=[^,[:space:]]*//g' \
                -e 's/,?keydirectory=[^,[:space:]]*//g' \
                -e 's/([[:space:]]),/\1/g' -e 's/,,+/,/g' \
                "$tmp"
        fi
        awk -v rw_list=",${MOUNT_RW_PARTITIONS:-}," -v conv_fs="${VENDOR_ODM_FS:-ext4}" '
            BEGIN { OFS = "\t" }
            /^[[:space:]]*#/ || NF < 5 { print; next }
            {
                mp = $2; sub(/^\//, "", mp)
                # vendor/odm are rebuilt as conv_fs: make sure a matching
                # fstab entry exists (Android tries entries in order).
                if ((mp == "vendor" || mp == "odm") && conv_fs == "ext4" && $3 == "erofs") {
                    l = $0
                    if (!(mp in have_ext4)) {
                        $3 = "ext4"; $4 = (index(rw_list, "," mp ",") > 0 ? "rw" : "ro") ",barrier=1,discard"
                        extline = $0
                        $0 = l
                        print extline
                        have_ext4[mp] = 1
                    }
                    print l
                    next
                }
                if ($3 == "ext4" && index(rw_list, "," mp ",") > 0) {
                    n = split($4, f, ","); out = ""
                    for (i = 1; i <= n; i++) { if (f[i] == "ro") f[i] = "rw"; out = out (i > 1 ? "," : "") f[i] }
                    $4 = out
                }
                if ($3 == "ext4") have_ext4[mp] = 1
                print
            }' "$tmp" > "${tmp}.new"
        sudo tee "$fstab" < "${tmp}.new" > /dev/null
        rm -f "$tmp" "${tmp}.new"
        count=$((count + 1))
    done < <(sudo find "$root" -iname 'fstab.*' -type f -print0 2>/dev/null)
    echo "$count"
}

fcount_v=0 fcount_o=0
if [ -d "$WORK_TREE/extract_target/vendor" ]; then
    sudo rsync -aHAX --delete "$WORK_TREE/extract_target/vendor/" "$VENDOR_WORK/"
    fcount_v="$(patch_fstab_tree "$VENDOR_WORK" vendor)"
fi
if [ -d "$WORK_TREE/extract_target/odm" ]; then
    sudo rsync -aHAX --delete "$WORK_TREE/extract_target/odm/" "$ODM_WORK/"
    fcount_o="$(patch_fstab_tree "$ODM_WORK" odm)"
fi
record_status "fstab_patch" PASS "patched $fcount_v fstab file(s) in vendor, $fcount_o in odm (encryption flags removed=${DISABLE_FORCEENCRYPT}; ro->rw on ext4 entries for ${MOUNT_RW_PARTITIONS}; originals in reports/fstab-original/)"

# ---- 1b. first-stage fstab (vendor_boot ramdisk) ------------------------
# Dynamic partitions are mounted by first-stage init from the fstab inside
# the vendor_boot (or boot) RAMDISK, not from /vendor/etc. If vendor/odm
# are converted to ext4 but that fstab only declares erofs for them, the
# device cannot mount /vendor and bootloops -- so this is checked, not
# assumed. (Repacking vendor_boot is not done: it would need a working
# mkbootimg; the fix, if this FAILs, is VENDOR_ODM_FS=erofs.)
check_first_stage_fstab() {
    local vb="$TGT_DIR/partitions/vendor_boot.img"
    local work="$WORK_TREE/vendor_boot_check"
    rm -rf "$work"; mkdir -p "$work/rd"
    [ -f "$vb" ] || { echo "NO_VENDOR_BOOT"; return 0; }
    unpack_bootimg --boot_img "$vb" --out "$work/unpacked" > "$work/unpack.log" 2>&1 || { echo "UNPACK_FAILED"; return 0; }
    local rd
    for rd in "$work"/unpacked/vendor_ramdisk*; do
        [ -f "$rd" ] || continue
        ( cd "$work/rd" && { lz4 -dc "$rd" 2>/dev/null || gzip -dc "$rd" 2>/dev/null || cat "$rd"; } \
            | cpio -idm --quiet 'fstab.*' 'first_stage_ramdisk/fstab.*' 2>/dev/null ) || true
    done
    find "$work/rd" -name 'fstab.*' -type f 2>/dev/null
}
if [ "${VENDOR_ODM_FS:-ext4}" = "ext4" ]; then
    fs_result="$(check_first_stage_fstab)"
    case "$fs_result" in
        NO_VENDOR_BOOT|UNPACK_FAILED|"")
            record_status "first_stage_fstab" WARN "could not inspect vendor_boot ramdisk fstab (${fs_result:-no fstab found}) -- cannot confirm first-stage init will mount ext4 /vendor and /odm"
            ;;
        *)
            missing_fs=""
            for mp in vendor odm; do
                [ -d "$WORK_TREE/extract_target/$mp" ] || continue
                if ! awk -v m="/$mp" '$2 == m && $3 == "ext4" { f = 1 } END { exit !f }' $fs_result; then
                    missing_fs+="$mp "
                fi
            done
            cp $fs_result "$REPORT_DIR/" 2>/dev/null || true
            if [ -n "$missing_fs" ]; then
                record_status "first_stage_fstab" FAIL "vendor_boot's first-stage fstab has no ext4 entry for: ${missing_fs}-- converting them to ext4 would make first-stage mount fail (bootloop). Set VENDOR_ODM_FS=erofs (or repack vendor_boot's fstab yourself)."
            else
                record_status "first_stage_fstab" PASS "vendor_boot's first-stage fstab already declares ext4 entries for vendor/odm -- ext4 conversion is mountable"
            fi
            ;;
    esac
fi

# ---- 2. SELinux labels: preserved originals, gap-fill only ---------------
# 05 now extracts with labels, ownership and capabilities intact, so the
# device maker's real labels are already on every file. apply_contexts.py
# is FILL-ONLY: it only labels files that somehow have none, using the
# matching partition's own file_contexts (framework trees -> source,
# vendor/odm -> target), and never overwrites an existing label.
# (Fixed: a missing contexts file used to `return 1` inside this loop,
# which under set -e would have killed the whole stage.)
apply_fill_contexts() {
    local tree="$1" part="$2" side="$3"
    local ctxfile
    ctxfile="$(sudo find "$WORK_TREE/extract_${side}" \( -iname "${part}_file_contexts" -o -iname "plat_file_contexts" \) 2>/dev/null | head -n1 || true)"
    if [ -z "$ctxfile" ]; then
        log_warn "no file_contexts found for $part -- unlabeled files (if any) stay unlabeled"
        sudo python3 "$SCRIPT_DIR/lib/apply_contexts.py" /dev/null "$tree" "/$part" 2>&1 | tail -n1 || true
        return 0
    fi
    sudo python3 "$SCRIPT_DIR/lib/apply_contexts.py" "$ctxfile" "$tree" "/$part" 2>&1 | tail -n1 || true
}

unlabeled_total=0
label_summary=""
for entry in "system:$PORT_ROOT/system:source" "system_ext:$PORT_ROOT/system_ext:source" "product:$PORT_ROOT/product:source" \
             "vendor:$VENDOR_WORK:target" "odm:$ODM_WORK:target"; do
    part="${entry%%:*}"; rest="${entry#*:}"; tree="${rest%:*}"; side="${rest##*:}"
    [ -d "$tree" ] || continue
    line="$(apply_fill_contexts "$tree" "$part" "$side")"
    log_info "labels [$part]: $line"
    n="$(grep -oE 'still_unlabeled=[0-9]+' <<< "$line" | cut -d= -f2 || true)"
    unlabeled_total=$((unlabeled_total + ${n:-0}))
    label_summary+="$part: ${line#labels } ; "
done
if [ "$unlabeled_total" -eq 0 ]; then
    record_status "selinux_labels" PASS "every file in the rebuilt trees carries an SELinux label (original labels preserved from the images; ownership/modes/capabilities preserved too) -- $label_summary"
else
    record_status "selinux_labels" WARN "$unlabeled_total file(s) have no SELinux label and no matching file_contexts rule -- they will be denied at runtime; see log. $label_summary"
fi

# ---- 3. rebuild filesystem images ---------------------------------------
# Built as root so root-only files are readable and every uid/gid/mode/
# xattr (label + capability) is copied into the image as-is.
EXT4_MARGIN_PCT="${EXT4_MARGIN_PCT:-10}"
build_ext4() {
    local tree="$1" out="$2"
    local size_bytes margin_bytes total_bytes inodes
    size_bytes="$(sudo du -sb "$tree" | awk '{print $1}')"
    inodes="$(sudo find "$tree" | wc -l)"
    margin_bytes=$((size_bytes * EXT4_MARGIN_PCT / 100 + 32*1024*1024))
    total_bytes=$((size_bytes + margin_bytes))
    sudo mke2fs -q -t ext4 -b 4096 -m 0 -O ^has_journal -N $((inodes + inodes / 10 + 1024)) \
        -d "$tree" "$out" $((total_bytes / 4096))
    sudo e2fsck -fy "$out" >/dev/null 2>&1 || true
}
build_erofs() {
    local tree="$1" out="$2"
    sudo mkfs.erofs -zlz4hc "$out" "$tree" >/dev/null
}

for name in system system_ext product; do
    [ -d "$PORT_ROOT/$name" ] || continue
    fs="${SRC_FS[$name]:-erofs}"
    out="$IMG_DIR/${name}.img"
    log_info "Rebuilding $name as $fs"
    if [ "$fs" = "erofs" ]; then build_erofs "$PORT_ROOT/$name" "$out"; else build_ext4 "$PORT_ROOT/$name" "$out"; fi
    record_status "rebuild_${name}" PASS "$name rebuilt as $fs -> $out ($(stat -c%s "$out") bytes)"
done

for entry in "vendor:$VENDOR_WORK" "odm:$ODM_WORK"; do
    part="${entry%%:*}"; tree="${entry#*:}"
    [ -d "$tree" ] || continue
    out="$IMG_DIR/${part}.img"
    log_info "Rebuilding $part as ${VENDOR_ODM_FS} (stated preference)"
    if [ "${VENDOR_ODM_FS}" = "erofs" ]; then build_erofs "$tree" "$out"; else build_ext4 "$tree" "$out"; fi
    record_status "rebuild_${part}" PASS "$part rebuilt as ${VENDOR_ODM_FS} -> $out ($(stat -c%s "$out") bytes)"
done
sudo chown "$(id -u):$(id -g)" "$IMG_DIR"/*.img

# ---- 4. passthrough: everything else copied byte-for-byte, TARGET ONLY --
# Never falls back to the source (donor) device's copy here: every name
# reaching this loop is hardware-specific/shared/unknown (system/
# system_ext/product/vendor/odm are excluded above and handled by their
# own rebuild logic). If marble doesn't actually have a given image, the
# safe, correct behavior is to leave it out and say so loudly --
# substituting annibale's copy of a hardware-tied blob (modem, tz,
# keymaster, init_boot, etc.) is exactly the "blindly copy source
# hardware onto target" this pipeline exists to refuse. (A real run
# found this fallback silently pulling annibale's init_boot.img into
# the marble package before this fix.)
passthrough_missing=0
while read -r name; do
    case "$name" in system|system_ext|product|vendor|odm) continue ;; esac
    src_img="$TGT_DIR/partitions/${name}.img"
    if [ -f "$src_img" ]; then
        cp "$src_img" "$IMG_DIR/${name}.img"
        log_info "Passthrough (unmodified): $name"
    else
        passthrough_missing=$((passthrough_missing + 1))
        log_warn "$name has no target (marble) image to pass through -- left OUT of the package rather than substituting annibale's copy of a hardware-tied partition"
    fi
done < "$REPORT_DIR/passthrough_images.txt"
if [ "$passthrough_missing" -gt 0 ]; then
    record_status "passthrough_copy" WARN "$passthrough_missing hardware-specific image(s) had no target copy and were left OUT of the package (never substituted from source) -- see log for names"
else
    record_status "passthrough_copy" PASS "hardware-specific images copied through unmodified (boot/vendor_boot/dtbo/firmware/etc.)"
fi

log_info "Image rebuild complete: $IMG_DIR"
