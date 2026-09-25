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
# Never assume a tool exists -- and never assume a *package name* is
# right, or that installing it yields a *working* binary, either.
# simg2img/img2simg and unpack_bootimg are confirmed real, working
# packages/binaries on Ubuntu 24.04 (noble), checked directly rather
# than guessed. unpack_bootimg ships from the "mkbootimg" apt package,
# which ALSO installs an mkbootimg binary -- but that one is verified
# BROKEN on noble: it crashes on every invocation, even --version,
# because the package unconditionally imports a "gki" Python module
# (gki.generate_gki_certificate) it never bundles or declares as a
# dependency. This pipeline never calls mkbootimg itself, only
# unpack_bootimg, so that binary being present-but-broken is noted
# and otherwise ignored rather than silently assumed to work.
# lpunpack, lpmake, and avbtool have NO official Ubuntu/Debian package
# at all -- deliberately absent from this map rather than pointed at a
# guessed name. lpmake is not used anywhere in this pipeline. avbtool
# is fetched directly as a single, dependency-free file in
# 01_toolchain.sh (see there). lpunpack is only needed for the rare
# ROM that ships a standalone super.img (today's payload.bin-based
# annibale/marble pair does not); 03_extract_detect.sh checks for it
# lazily, right where it would actually be used.
declare -A _APT_PKG_FOR=(
    [simg2img]=android-sdk-libsparse-utils [img2simg]=android-sdk-libsparse-utils
    [unpack_bootimg]=mkbootimg
    [e2fsck]=e2fsprogs [resize2fs]=e2fsprogs [tune2fs]=e2fsprogs [debugfs]=e2fsprogs
    [zstd]=zstd [lz4]=liblz4-tool [jq]=jq [7z]=p7zip-full [xmllint]=libxml2-utils
    [shellcheck]=shellcheck [rsync]=rsync [file]=file [cpio]=cpio
)

ensure_tools() {
    local missing_bins=()
    for bin in "$@"; do
        command -v "$bin" >/dev/null 2>&1 || missing_bins+=("$bin")
    done
    if [ "${#missing_bins[@]}" -eq 0 ]; then
        return 0
    fi
    log_warn "Missing tools: ${missing_bins[*]}"
    # Install ONE package at a time. apt-get aborts an entire multi-
    # package transaction the moment any single named package can't be
    # resolved -- a wrong or unavailable mapping for tool X must not be
    # able to take perfectly-installable tool Y down with it (this
    # exact failure mode blocked xmllint/simg2img/erofs-utils earlier
    # over one unrelated bad name, despite all three being fine).
    declare -A seen_pkgs=()
    for bin in "${missing_bins[@]}"; do
        local pkg="${_APT_PKG_FOR[$bin]:-}"
        [ -n "$pkg" ] || continue
        [ -n "${seen_pkgs[$pkg]:-}" ] && continue
        seen_pkgs[$pkg]=1
        log_info "Attempting apt install: $pkg"
        sudo apt-get install -y -qq "$pkg" || log_warn "apt install failed for '$pkg' -- continuing; other packages are unaffected"
    done
    local still_missing=()
    for bin in "${missing_bins[@]}"; do
        command -v "$bin" >/dev/null 2>&1 || still_missing+=("$bin")
    done
    if [ "${#still_missing[@]}" -gt 0 ]; then
        die "Required tools still unavailable after install attempts: ${still_missing[*]}. Not silently continuing -- these have no working apt mapping in this environment; supply them another way before re-running."
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
