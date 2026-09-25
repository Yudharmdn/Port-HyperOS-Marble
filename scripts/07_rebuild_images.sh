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

# ---- 1. fstab patch (comma-safe: the earlier greedy \S+ regex bug is
# fixed here by bounding matches at a comma or field end, never past it)
patch_fstab_tree() {
    local root="$1"
    local disabled=0
    while IFS= read -r -d '' fstab; do
        cp "$fstab" "${fstab}.orig"
        if [ "${DISABLE_FORCEENCRYPT:-true}" = "true" ]; then
            sed -i -E \
                -e 's/,?forceencrypt=[^,[:space:]]*//g' \
                -e 's/,?fileencryption=[^,[:space:]]*//g' \
                -e 's/,?metadata_encryption=[^,[:space:]]*//g' \
                -e 's/,,+/,/g' -e 's/,$//' -e 's/\t,/\t/g' \
                "$fstab"
        fi
        IFS=',' read -ra rw_parts <<< "${MOUNT_RW_PARTITIONS:-}"
        for mnt in "${rw_parts[@]}"; do
            [ -z "$mnt" ] && continue
            # flip the 4th column's leading ro -> rw only on the matching mount-point line
            awk -v m="/$mnt" 'BEGIN{OFS="\t"} $2==m || $2=="/"m {
                gsub(/(^|,)ro(,|$)/,"\\1rw\\2",$4)
            } {print}' "$fstab" > "${fstab}.tmp" && mv "${fstab}.tmp" "$fstab"
        done
        disabled=$((disabled + 1))
    done < <(find "$root" -iname 'fstab.*' -type f -print0 2>/dev/null)
    echo "$disabled"
}

fcount_v=0 fcount_o=0
if [ -d "$WORK_TREE/extract_target/vendor" ]; then
    rsync -a --delete "$WORK_TREE/extract_target/vendor/" "$VENDOR_WORK/"
    fcount_v="$(patch_fstab_tree "$VENDOR_WORK")"
fi
if [ -d "$WORK_TREE/extract_target/odm" ]; then
    rsync -a --delete "$WORK_TREE/extract_target/odm/" "$ODM_WORK/"
    fcount_o="$(patch_fstab_tree "$ODM_WORK")"
fi
record_status "fstab_patch" PASS "patched $fcount_v fstab file(s) in vendor, $fcount_o in odm (forceencrypt/fileencryption disabled=${DISABLE_FORCEENCRYPT}, rw=${MOUNT_RW_PARTITIONS})"

# ---- 2. best-effort context re-application (see lib/apply_contexts.py) --
apply_best_effort_contexts() {
    local tree="$1" part="$2"
    local ctxfile
    ctxfile="$(find "$WORK_TREE/extract_target" "$WORK_TREE/extract_source" -iname "${part}_file_contexts" -o -iname 'plat_file_contexts' 2>/dev/null | head -n1 || true)"
    if [ -z "$ctxfile" ]; then
        log_warn "No *_file_contexts found for $part -- skipping context re-application (image will inherit no SELinux labels from this step)"
        return 1
    fi
    sudo python3 "$SCRIPT_DIR/lib/apply_contexts.py" "$ctxfile" "$tree" "/$part" 2>&1 || true
}

for entry in "system:$PORT_ROOT/system" "system_ext:$PORT_ROOT/system_ext" "product:$PORT_ROOT/product" \
             "vendor:$VENDOR_WORK" "odm:$ODM_WORK"; do
    part="${entry%%:*}"; tree="${entry#*:}"
    [ -d "$tree" ] || continue
    apply_best_effort_contexts "$tree" "$part"
done
record_status "selinux_relabel" WARN "best-effort userspace context re-application used (lib/apply_contexts.py) -- fs_config (uid/gid/mode/capabilities) NOT reproduced; not equivalent to AOSP e2fsdroid/mkuserimg host tools. Verify labels post-build before trusting a PASS boot."

# ---- 3. rebuild filesystem images ---------------------------------------
build_ext4() {
    local tree="$1" out="$2"
    local size_bytes margin_bytes total_bytes
    size_bytes="$(du -sb "$tree" | awk '{print $1}')"
    margin_bytes=$((size_bytes * 20 / 100 + 16*1024*1024))
    total_bytes=$((size_bytes + margin_bytes))
    mke2fs -q -t ext4 -b 4096 -O ^has_journal -d "$tree" "$out" $((total_bytes / 4096))
    e2fsck -fy "$out" >/dev/null 2>&1 || true
}
build_erofs() {
    local tree="$1" out="$2"
    mkfs.erofs -zlz4hc "$out" "$tree" >/dev/null
}

for name in system system_ext product; do
    [ -d "$PORT_ROOT/$name" ] || continue
    fs="${SRC_FS[$name]:-erofs}"
    out="$IMG_DIR/${name}.img"
    log_info "Rebuilding $name as $fs"
    if [ "$fs" = "erofs" ]; then build_erofs "$PORT_ROOT/$name" "$out"; else build_ext4 "$PORT_ROOT/$name" "$out"; fi
    record_status "rebuild_${name}" PASS "$name rebuilt as $fs -> $out"
done

for entry in "vendor:$VENDOR_WORK" "odm:$ODM_WORK"; do
    part="${entry%%:*}"; tree="${entry#*:}"
    [ -d "$tree" ] || continue
    out="$IMG_DIR/${part}.img"
    log_info "Rebuilding $part as ${VENDOR_ODM_FS} (stated preference)"
    if [ "${VENDOR_ODM_FS}" = "erofs" ]; then build_erofs "$tree" "$out"; else build_ext4 "$tree" "$out"; fi
    record_status "rebuild_${part}" PASS "$part rebuilt as ${VENDOR_ODM_FS} -> $out"
done

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
