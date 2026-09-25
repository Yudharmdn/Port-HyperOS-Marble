#!/usr/bin/env bash
# scripts/08_kernel_integration.sh -- Phase C step: kernel integration.
#
# Two independent, separately-toggled concerns, both confirmed against
# real release data rather than assumed:
#
#   1. USE_CUSTOM_BOOT_IMG (default true -- stated instruction): fetch
#      the pre-built boot.img published by KERNEL_BOOT_IMG_REPO
#      (Yudharmdn/boot-melt-rebase) and REPLACE the target ROM's
#      passthrough boot.img with it. This is the actual kernel+ramdisk
#      that boots the device. Replacing it invalidates vbmeta's
#      original AVB hash descriptor for "boot" -- this script logs
#      that plainly and 09_validate_package.sh cross-checks it into
#      the status ledger; it is never silently absorbed.
#
#   2. BUILD_KERNEL / KERNEL_ARTIFACT_REPO (default false/unset): an
#      OPTIONAL companion root-solution AnyKernel3 zip, unrelated to
#      (1). Inspecting KERNEL_ARTIFACT_REPO's real latest release shows
#      SIX differently-named zips (KernelSU-Next / Official-KernelSU /
#      ReSukiSU, each CORE/FULL, all SuSFS-NoMount) -- these patch an
#      *existing* boot image to add root management; they are not a
#      base kernel/boot image. Picking one of six meaningfully
#      different root solutions is a real decision: this script never
#      glob-guesses among them. KERNEL_ROOT_VARIANT_ASSET_NAME must
#      name the exact asset to stage one; left empty, this is skipped
#      with a WARN listing what is actually available.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/../config/port.env"

require_not_analysis_only "kernel integration"

log_section 8 "KERNEL INTEGRATION"

KERNEL_OUT="$WORKDIR/kernel"
mkdir -p "$KERNEL_OUT" "$IMG_DIR" "$REPORT_DIR"

# =======================================================================
# Part 1 -- custom boot.img (the actual kernel boot image)
# =======================================================================
if [ "${USE_CUSTOM_BOOT_IMG}" = "true" ]; then
    log_info "USE_CUSTOM_BOOT_IMG=true -- fetching boot image from $KERNEL_BOOT_IMG_REPO"

    boot_rel_json="$WORKDIR/boot_img_release.json"
    if [ -n "$KERNEL_BOOT_IMG_TAG" ]; then
        gh_api "https://api.github.com/repos/${KERNEL_BOOT_IMG_REPO}/releases/tags/${KERNEL_BOOT_IMG_TAG}" > "$boot_rel_json"
    else
        gh_api "https://api.github.com/repos/${KERNEL_BOOT_IMG_REPO}/releases/latest" > "$boot_rel_json"
    fi
    boot_tag="$(python3 -c "import json;print(json.load(open('$boot_rel_json')).get('tag_name',''))")"
    boot_url="$(python3 -c "
import json
d = json.load(open('$boot_rel_json'))
for a in d.get('assets', []):
    if a['name'] == '$KERNEL_BOOT_IMG_ASSET_NAME':
        print(a['browser_download_url']); break
")"
    [ -n "$boot_url" ] || die "Asset '$KERNEL_BOOT_IMG_ASSET_NAME' not found on $KERNEL_BOOT_IMG_REPO release '${boot_tag:-unknown}'. Set KERNEL_BOOT_IMG_ASSET_NAME to the exact asset name if it differs."
    log_info "Boot image release: $boot_tag -- $boot_url"
    curl -fL --retry 5 --retry-all-errors -o "$KERNEL_OUT/boot.img" "$boot_url"

    # Sanity checks -- refuse to stage something that isn't plausibly a
    # boot image rather than silently packaging whatever was downloaded.
    boot_size="$(stat -c%s "$KERNEL_OUT/boot.img")"
    [ "$boot_size" -gt 1048576 ] || die "Downloaded boot.img is suspiciously small (${boot_size} bytes) -- likely an error page, not a real boot image. Refusing to package it."
    boot_magic="$(head -c8 "$KERNEL_OUT/boot.img" | tr -cd '[:print:]')"
    case "$boot_magic" in
        ANDROID*|VNDRBOOT*) : ;;
        *) log_warn "boot.img magic header ('$boot_magic') isn't the expected ANDROID!/VNDRBOOT signature. Staging it anyway since it came from a named, trusted release -- worth a manual look." ;;
    esac
    boot_sha256="$(sha256sum "$KERNEL_OUT/boot.img" | cut -d' ' -f1)"
    log_info "Fetched boot.img: ${boot_size} bytes, sha256=$boot_sha256"

    if [ -f "$IMG_DIR/boot.img" ]; then
        orig_sha256="$(sha256sum "$IMG_DIR/boot.img" | cut -d' ' -f1)"
        log_warn "Replacing marble's passthrough boot.img (sha256=$orig_sha256) with the custom Melt-Rebase build (sha256=$boot_sha256, tag=$boot_tag). This invalidates the ORIGINAL AVB hash descriptor for the boot partition -- see avb-report.md. Verification will fail on a locked/enforcing bootloader unless DISABLE_AVB_FOR_TESTING=true or boot is re-signed with a key vbmeta trusts."
    else
        log_warn "No passthrough boot.img was staged from target extraction yet -- writing the custom boot.img directly. Confirm 06_merge_port.sh ran first."
    fi
    cp "$KERNEL_OUT/boot.img" "$IMG_DIR/boot.img"
    {
        echo "source_repo=${KERNEL_BOOT_IMG_REPO}"
        echo "release_tag=${boot_tag}"
        echo "asset=${KERNEL_BOOT_IMG_ASSET_NAME}"
        echo "sha256=${boot_sha256}"
        echo "size_bytes=${boot_size}"
    } > "$REPORT_DIR/boot-image-provenance.txt"
    record_status "boot_image_source" WARN "boot.img replaced with custom Melt-Rebase build from ${KERNEL_BOOT_IMG_REPO}@${boot_tag}; original AVB boot descriptor no longer matches (see avb-report.md)"

    # Cross-check: many Android 13+ GKI devices (marble's Android 15
    # vendor baseline makes this likely) split init_boot from boot. A
    # combined (kernel+generic-ramdisk) boot.img flashed onto a target
    # that already ships a separate init_boot is a well-known bootloop
    # cause. Check for it with unpack_bootimg rather than assume either
    # scheme -- this is a real, executable check, not a comment.
    if grep -qP '^init_boot\t' "$REPORT_DIR/target_partition_inventory.tsv" 2>/dev/null; then
        log_info "Target ROM ships a separate init_boot partition -- checking whether the fetched boot.img is combined (legacy) or kernel-only (split-scheme)."
        if command -v unpack_bootimg >/dev/null 2>&1; then
            unpack_dir="$WORKDIR/boot_unpack_check"
            rm -rf "$unpack_dir"; mkdir -p "$unpack_dir"
            if unpack_bootimg --boot_img "$KERNEL_OUT/boot.img" --out "$unpack_dir" > "$unpack_dir/unpack.log" 2>&1; then
                hdr_ver="$(grep -oP 'boot magic header version: *\K[0-9]+' "$unpack_dir/unpack.log" 2>/dev/null || echo unknown)"
                ramdisk_size=0
                [ -f "$unpack_dir/ramdisk" ] && ramdisk_size="$(stat -c%s "$unpack_dir/ramdisk")"
                log_info "boot.img header_version=$hdr_ver ramdisk_size=${ramdisk_size}B"
                if [ "$ramdisk_size" -gt 4096 ]; then
                    record_status "boot_init_boot_split_check" WARN "target ships a separate init_boot, but the replacement boot.img (header_version=$hdr_ver) bundles a ${ramdisk_size}B ramdisk of its own -- confirm this is intentional; a combined-format image on a split-scheme device is a common bootloop cause. If Melt-Rebase targets the split scheme, this ramdisk should be empty/near-empty."
                else
                    record_status "boot_init_boot_split_check" PASS "replacement boot.img (header_version=$hdr_ver) carries no meaningful ramdisk of its own, consistent with target's split init_boot scheme"
                fi
            else
                record_status "boot_init_boot_split_check" WARN "target ships a separate init_boot but unpack_bootimg could not parse the replacement boot.img -- see $unpack_dir/unpack.log; verify the split-vs-combined format manually before flashing"
            fi
        else
            record_status "boot_init_boot_split_check" WARN "target ships a separate init_boot; could not verify the replacement boot.img's format (unpack_bootimg unavailable in this environment)"
        fi
    fi
else
    log_info "USE_CUSTOM_BOOT_IMG=false -- marble's passthrough boot.img is left untouched."
    record_status "boot_image_source" "NOT TESTED" "USE_CUSTOM_BOOT_IMG=false; target ROM's stock boot.img used as-is"
fi

# =======================================================================
# Part 2 -- optional post-boot root-solution companion zip
# =======================================================================
if [ "${BUILD_KERNEL}" != "true" ]; then
    log_info "BUILD_KERNEL=false -- no optional root-solution companion zip staged this run."
    record_status "kernel_root_variant" "NOT TESTED" "BUILD_KERNEL=false"
    exit 0
fi

if [ -z "${KERNEL_ROOT_VARIANT_ASSET_NAME}" ]; then
    log_warn "BUILD_KERNEL=true but KERNEL_ROOT_VARIANT_ASSET_NAME is empty. $KERNEL_ARTIFACT_REPO's latest release ships SIX differently-named root-solution zips (three KernelSU forks x CORE/FULL) -- picking one silently would be exactly the kind of guess this pipeline refuses to make. Set KERNEL_ROOT_VARIANT_ASSET_NAME to the exact asset filename you want. Skipping."
    record_status "kernel_root_variant" WARN "BUILD_KERNEL=true but no KERNEL_ROOT_VARIANT_ASSET_NAME set; 6 unnamed candidates on $KERNEL_ARTIFACT_REPO, none staged"
    exit 0
fi

fetch_named_asset_from_latest() {
    # $1 = repo, $2 = exact asset name. Downloads to $KERNEL_OUT/<asset>.
    # Prints the resolved tag on stdout.
    local repo="$1" asset="$2"
    local rel_json="$WORKDIR/kernel_release.json"
    gh_api "https://api.github.com/repos/${repo}/releases/latest" > "$rel_json"
    local tag url
    tag="$(python3 -c "import json;print(json.load(open('$rel_json')).get('tag_name',''))")"
    url="$(python3 -c "
import json
d = json.load(open('$rel_json'))
for a in d.get('assets', []):
    if a['name'] == '$asset':
        print(a['browser_download_url']); break
")"
    if [ -z "$url" ]; then
        log_error "Asset '$asset' not found on $repo latest release ($tag). Available assets:"
        python3 -c "import json
for a in json.load(open('$rel_json')).get('assets', []):
    print(' -', a['name'])" >&2
        die "KERNEL_ROOT_VARIANT_ASSET_NAME='$asset' does not match any real asset on $repo -- copy the exact filename from the list above."
    fi
    log_info "Root-variant release: $tag -- $url"
    curl -fL --retry 5 --retry-all-errors -o "$KERNEL_OUT/$asset" "$url"
    echo "$tag"
}

trigger_and_wait_for_fresh_build() {
    [ -n "$KERNEL_TRIGGER_REPO" ] || die "BUILD_KERNEL=true with a fresh-build request needs KERNEL_TRIGGER_REPO set (the private CI repo), plus KERNEL_TRIGGER_PAT as a secret."
    [ -n "${KERNEL_TRIGGER_PAT:-}" ] || die "KERNEL_TRIGGER_PAT secret not set. NOTE: this must be a workflow_dispatch API call, not a reusable 'workflow_call' -- public-repo callers cannot workflow_call into a private repo (confirmed constraint from prior CI work); a PAT-driven dispatch is the supported path."
    log_info "Dispatching $KERNEL_TRIGGER_WORKFLOW_FILE on $KERNEL_TRIGGER_REPO"
    local before_ts
    before_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    curl -fsSL -X POST \
        -H "Authorization: Bearer $KERNEL_TRIGGER_PAT" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${KERNEL_TRIGGER_REPO}/actions/workflows/${KERNEL_TRIGGER_WORKFLOW_FILE}/dispatches" \
        -d "{\"ref\":\"${KERNEL_SOURCE_BRANCH}\"}"

    log_info "Polling for the triggered run to complete (up to ~40 min)..."
    local elapsed=0
    while [ "$elapsed" -lt 2400 ]; do
        sleep 30; elapsed=$((elapsed + 30))
        local runs_json status conclusion created
        runs_json="$(curl -fsSL -H "Authorization: Bearer $KERNEL_TRIGGER_PAT" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${KERNEL_TRIGGER_REPO}/actions/workflows/${KERNEL_TRIGGER_WORKFLOW_FILE}/runs?per_page=1")"
        created="$(python3 -c "import json;r=json.load(open('/dev/stdin'))['workflow_runs'];print(r[0]['created_at'] if r else '')" <<< "$runs_json")"
        [ -z "$created" ] && continue
        [ "$created" \< "$before_ts" ] && continue
        status="$(python3 -c "import json;print(json.load(open('/dev/stdin'))['workflow_runs'][0]['status'])" <<< "$runs_json")"
        conclusion="$(python3 -c "import json;print(json.load(open('/dev/stdin'))['workflow_runs'][0].get('conclusion') or '')" <<< "$runs_json")"
        log_info "  root-variant build status=$status conclusion=${conclusion:-pending} (${elapsed}s elapsed)"
        if [ "$status" = "completed" ]; then
            [ "$conclusion" = "success" ] || die "Triggered root-variant build finished with conclusion=$conclusion"
            break
        fi
    done
    [ "$elapsed" -lt 2400 ] || die "Timed out waiting for triggered root-variant build"
    # The private workflow is expected to publish to KERNEL_ARTIFACT_REPO
    # on success (matches the existing private->public release pattern).
    fetch_named_asset_from_latest "$KERNEL_ARTIFACT_REPO" "$KERNEL_ROOT_VARIANT_ASSET_NAME"
}

if [ -n "$KERNEL_TRIGGER_REPO" ]; then
    tag="$(trigger_and_wait_for_fresh_build)"
else
    tag="$(fetch_named_asset_from_latest "$KERNEL_ARTIFACT_REPO" "$KERNEL_ROOT_VARIANT_ASSET_NAME")"
fi

cp "$KERNEL_OUT/$KERNEL_ROOT_VARIANT_ASSET_NAME" "$WORKDIR/${TARGET_DEVICE}-${KERNEL_ROOT_VARIANT_ASSET_NAME}" 2>/dev/null || \
    cp "$KERNEL_OUT/$KERNEL_ROOT_VARIANT_ASSET_NAME" "$IMG_DIR/../${TARGET_DEVICE}-${KERNEL_ROOT_VARIANT_ASSET_NAME}"

record_status "kernel_root_variant" PASS "Root-solution companion staged: $KERNEL_ROOT_VARIANT_ASSET_NAME (tag: $tag). This patches an existing boot image for root management -- it is separate from, and applied after, the boot.img handled in Part 1."
log_info "Kernel integration complete. Recommended flash order: ROM port ZIP (boot.img already replaced inside it) -> this root-solution zip, in the same recovery session, only if root is wanted."
