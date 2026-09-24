#!/usr/bin/env bash
# scripts/08_kernel_integration.sh -- Phase C step: kernel integration.
#
# Design choice: rather than reimplementing unpack_bootimg/mkbootimg
# surgery on marble's boot.img (easy to get subtly wrong -- header
# version, cmdline, bootconfig), this stage reuses the EXISTING,
# already-validated Melt-Rebase AnyKernel3 output and ships it as a
# companion flashable, per spec section 27 ("integrate with it cleanly
# instead of duplicating unrelated logic"). marble's own boot.img stays
# untouched by this pipeline; the AnyKernel3 zip patches it at flash
# time using its own proven installer.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/../config/port.env"

require_not_analysis_only "kernel integration"

log_section 8 "KERNEL INTEGRATION"

if [ "${BUILD_KERNEL}" != "true" ]; then
    log_info "BUILD_KERNEL=false -- ROM port will preserve marble's existing boot chain untouched. Skipping."
    record_status "kernel_integration" "NOT TESTED" "BUILD_KERNEL=false; no kernel artifact attached this run"
    exit 0
fi

KERNEL_OUT="$WORKDIR/kernel"
mkdir -p "$KERNEL_OUT"

fetch_latest_published_kernel() {
    log_info "Fetching latest published kernel release from $KERNEL_ARTIFACT_REPO"
    local rel_json="$WORKDIR/kernel_release.json"
    gh_api "https://api.github.com/repos/${KERNEL_ARTIFACT_REPO}/releases/latest" > "$rel_json"
    local tag zip_url
    tag="$(python3 -c "import json;print(json.load(open('$rel_json')).get('tag_name',''))")"
    zip_url="$(python3 -c "
import json
d=json.load(open('$rel_json'))
for a in d.get('assets', []):
    if a['name'].endswith('.zip'):
        print(a['browser_download_url']); break
")"
    [ -n "$zip_url" ] || die "No .zip asset found on latest release of $KERNEL_ARTIFACT_REPO (tag: ${tag:-unknown})"
    log_info "Kernel release: $tag -- $zip_url"
    curl -fL --retry 5 --retry-all-errors -o "$KERNEL_OUT/anykernel3.zip" "$zip_url"
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
        log_info "  kernel build status=$status conclusion=${conclusion:-pending} (${elapsed}s elapsed)"
        if [ "$status" = "completed" ]; then
            [ "$conclusion" = "success" ] || die "Triggered kernel build finished with conclusion=$conclusion"
            break
        fi
    done
    [ "$elapsed" -lt 2400 ] || die "Timed out waiting for triggered kernel build"
    # The private workflow is expected to publish to KERNEL_ARTIFACT_REPO
    # on success (matches the existing private->public release pattern).
    fetch_latest_published_kernel
}

if [ -n "$KERNEL_TRIGGER_REPO" ]; then
    tag="$(trigger_and_wait_for_fresh_build)"
else
    tag="$(fetch_latest_published_kernel)"
fi

cp "$KERNEL_OUT/anykernel3.zip" "$IMG_DIR/../${TARGET_DEVICE}-MeltRebase-Kernel-${tag}.zip" 2>/dev/null || \
    cp "$KERNEL_OUT/anykernel3.zip" "$WORKDIR/${TARGET_DEVICE}-MeltRebase-Kernel-${tag}.zip"

record_status "kernel_integration" PASS "AnyKernel3 kernel package staged as a companion flashable (tag: $tag); marble boot.img itself left untouched by this pipeline"
log_info "Kernel integration complete. Flash order for the end user: ROM port ZIP, then this kernel ZIP, in the same recovery session."
