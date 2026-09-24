#!/usr/bin/env bash
# scripts/lib/common.sh
# Shared helpers. Sourced by every phase script. Never run directly.
set -euo pipefail

# ---- logging --------------------------------------------------------
_STEP_TOTAL="${_STEP_TOTAL:-11}"
log_section() {
    # log_section N "TITLE"
    printf '==================================================\n'
    printf '[%s/%s] %s\n' "$1" "$_STEP_TOTAL" "$2"
    printf '==================================================\n'
}
log_info()  { printf '[INFO] %s\n' "$*"; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

die() { log_error "$*"; exit 1; }

# ---- status ledger ----------------------------------------------------
# Every check in the pipeline appends exactly one line here via
# record_status. Statuses are never invented after the fact: this file
# is the single source of truth for the final validation matrix
# (see scripts/10_report.sh) and for whether the run is allowed to
# proceed past analysis. Valid states: PASS WARN FAIL "NOT TESTED".
STATUS_LEDGER="${STATUS_LEDGER:-${REPORT_DIR:-/tmp}/status_ledger.tsv}"

record_status() {
    # record_status "<check name>" "<PASS|WARN|FAIL|NOT TESTED>" "<detail>"
    local name="$1" state="$2" detail="${3:-}"
    mkdir -p "$(dirname "$STATUS_LEDGER")"
    case "$state" in
        PASS|WARN|FAIL|"NOT TESTED") ;;
        *) die "record_status: invalid state '$state' for '$name' (must be PASS/WARN/FAIL/'NOT TESTED')" ;;
    esac
    printf '%s\t%s\t%s\n' "$name" "$state" "$detail" >> "$STATUS_LEDGER"
    case "$state" in
        PASS) log_info  "[PASS] $name -- $detail" ;;
        WARN) log_warn  "[WARN] $name -- $detail" ;;
        FAIL) log_error "[FAIL] $name -- $detail" ;;
        *)    log_info  "[NOT TESTED] $name -- $detail" ;;
    esac
}

ledger_has_fail() {
    [ -f "$STATUS_LEDGER" ] && grep -qP '\tFAIL\t' "$STATUS_LEDGER" 2>/dev/null
}

# ---- tool detection ---------------------------------------------------
# Never assume a tool exists. require_tools lists what a stage needs;
# missing tools are installed via apt where a package is known, else
# the stage fails loudly instead of silently degrading.
declare -A _APT_PKG_FOR=(
    [simg2img]=android-sdk-libsparse-utils [img2simg]=android-sdk-libsparse-utils
    [lpunpack]=android-sdk-libufdt-utils   [lpmake]=android-sdk-libufdt-utils
    [mkbootimg]=android-sdk-libufdt-utils  [unpack_bootimg]=android-sdk-libufdt-utils
    [avbtool]=android-sdk-libufdt-utils
    [mkfs.erofs]=erofs-utils [dump.erofs]=erofs-utils [fsck.erofs]=erofs-utils
    [e2fsck]=e2fsprogs [resize2fs]=e2fsprogs [tune2fs]=e2fsprogs [debugfs]=e2fsprogs
    [zstd]=zstd [lz4]=liblz4-tool [jq]=jq [7z]=p7zip-full [xmllint]=libxml2-utils
    [shellcheck]=shellcheck [rsync]=rsync [file]=file
)

ensure_tools() {
    local missing_pkgs=() missing_bins=()
    for bin in "$@"; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            missing_bins+=("$bin")
            local pkg="${_APT_PKG_FOR[$bin]:-}"
            if [ -n "$pkg" ]; then
                missing_pkgs+=("$pkg")
            fi
        fi
    done
    if [ "${#missing_bins[@]}" -eq 0 ]; then
        return 0
    fi
    log_warn "Missing tools: ${missing_bins[*]}"
    if [ "${#missing_pkgs[@]}" -gt 0 ]; then
        log_info "Attempting apt install: ${missing_pkgs[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${missing_pkgs[@]}" || true
    fi
    local still_missing=()
    for bin in "${missing_bins[@]}"; do
        command -v "$bin" >/dev/null 2>&1 || still_missing+=("$bin")
    done
    if [ "${#still_missing[@]}" -gt 0 ]; then
        die "Required tools still unavailable after install attempt: ${still_missing[*]}. Not silently continuing -- install them explicitly in the workflow's toolchain step."
    fi
}

# ---- GitHub API convenience ------------------------------------------
# Always authenticate, even for public repos: anonymous API calls are
# rate-limited to 60/hr and this pipeline can burn that in one run.
gh_api() {
    local url="$1"
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --retry 5 --retry-all-errors -H "Authorization: Bearer $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github+json" "$url"
    else
        curl -fsSL --retry 5 --retry-all-errors -H "Accept: application/vnd.github+json" "$url"
    fi
}

require_not_analysis_only() {
    if [ "${ANALYSIS_ONLY:-true}" = "true" ]; then
        log_info "ANALYSIS_ONLY=true -- skipping $1 (analysis-only run)."
        exit 0
    fi
}
