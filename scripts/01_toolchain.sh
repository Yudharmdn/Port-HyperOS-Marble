#!/usr/bin/env bash
# scripts/01_toolchain.sh -- Phase A step 1: environment preparation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=../config/port.env
source "$SCRIPT_DIR/../config/port.env"

log_section 1 "ENVIRONMENT PREPARATION"

mkdir -p "$SRC_DIR" "$TGT_DIR" "$WORK_TREE" "$IMG_DIR" "$REPORT_DIR" "$LOG_DIR"
: > "$STATUS_LEDGER"

sudo apt-get update -qq

ensure_tools curl wget unzip zip git python3 jq lz4 zstd file find grep sed awk \
             sha256sum rsync xmllint shellcheck 7z \
             simg2img img2simg unpack_bootimg \
             e2fsck resize2fs tune2fs debugfs mkfs.erofs dump.erofs fsck.erofs

# payload-dumper-go (for OTA payload.bin) is not an apt package; pin a
# known-working release build. If the pinned asset disappears upstream,
# fail loudly rather than silently falling back to an unpinned "latest"
# that hasn't been validated against this pipeline.
PDG_VERSION="1.3.2"
if ! command -v payload-dumper-go >/dev/null 2>&1; then
    log_info "Installing payload-dumper-go v$PDG_VERSION"
    curl -fL --retry 5 --retry-all-errors -o /tmp/pdg.tar.gz \
        "https://github.com/ssut/payload-dumper-go/releases/download/${PDG_VERSION}/payload-dumper-go_${PDG_VERSION}_linux_amd64.tar.gz"
    tar -xzf /tmp/pdg.tar.gz -C /tmp
    sudo install -m 0755 /tmp/payload-dumper-go /usr/local/bin/payload-dumper-go
fi
command -v payload-dumper-go >/dev/null 2>&1 || die "payload-dumper-go install failed"

# avbtool is also not an apt package on Ubuntu (confirmed absent, not
# assumed), but it IS a single, dependency-free Python 3 file straight
# from its own upstream -- no compilation, no third-party binary trust
# needed. Fetched via the standard googlesource/Gitiles raw-file
# convention (?format=TEXT returns base64). Verified with an actual
# invocation, not just a file-exists check, since a fetch can succeed
# and still hand back an HTML error page instead of the real script.
if ! command -v avbtool >/dev/null 2>&1; then
    log_info "Fetching avbtool.py (AOSP platform/external/avb, master)"
    curl -fsSL --retry 5 --retry-all-errors \
        "https://android.googlesource.com/platform/external/avb/+/master/avbtool.py?format=TEXT" \
        | base64 -d | sudo tee /usr/local/bin/avbtool > /dev/null
    sudo chmod +x /usr/local/bin/avbtool
fi
avbtool --help >/dev/null 2>&1 || die "avbtool fetch produced a file that doesn't run -- see /usr/local/bin/avbtool; the fetch likely returned an error page instead of the real script"

# lpunpack has NO official Ubuntu/Debian package and no single trusted
# prebuilt source this pipeline is willing to vouch for -- so unlike
# the two tools above, it is deliberately NOT fetched here. It is also
# only needed for a ROM that ships a standalone super.img; today's
# payload.bin-based annibale/marble pair never reaches that code path.
# Rather than hard-require it for every run regardless of ROM shape,
# 03_extract_detect.sh checks for it lazily, right where it would
# actually be used, and fails there with a specific, actionable
# message if that path is ever really taken. lpmake is not called
# anywhere in this pipeline and is simply not required at all.
if command -v lpunpack >/dev/null 2>&1; then
    log_info "lpunpack found ($(command -v lpunpack)) -- available if a standalone-super.img ROM ever needs it"
else
    log_info "lpunpack not present -- fine for today's payload.bin-based ROMs; only checked (and required) if 03_extract_detect.sh actually hits a standalone super.img"
fi

if command -v mkbootimg >/dev/null 2>&1; then
    log_info "Note: the 'mkbootimg' binary that ships alongside unpack_bootimg is confirmed broken on this image (crashes on any invocation -- a missing 'gki' module the apt package never declares as a dependency). This pipeline only calls unpack_bootimg, which works fine, so this is not fetched or worked around."
fi

for t in curl wget unzip zip git python3 jq lz4 zstd file rsync xmllint shellcheck \
         simg2img img2simg unpack_bootimg avbtool \
         e2fsck resize2fs tune2fs debugfs mkfs.erofs dump.erofs fsck.erofs payload-dumper-go; do
    ver_line="$("$t" --version 2>&1 | head -n1 || true)"
    log_info "tool ok: $t (${ver_line:-no --version output})"
done

record_status "toolchain" PASS "all required tools present"
log_info "Environment ready."
