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
             simg2img img2simg lpunpack lpmake avbtool mkbootimg unpack_bootimg \
             e2fsck resize2fs tune2fs debugfs mkfs.erofs dump.erofs fsck.erofs

# payload-dumper-go (for OTA payload.bin) and lpunpack_and_lpmake are not
# apt packages; pin known-working release builds. If the pinned asset
# disappears upstream, fail loudly rather than silently falling back to
# an unpinned "latest" that hasn't been validated against this pipeline.
PDG_VERSION="1.3.2"
if ! command -v payload-dumper-go >/dev/null 2>&1; then
    log_info "Installing payload-dumper-go v$PDG_VERSION"
    curl -fL --retry 5 --retry-all-errors -o /tmp/pdg.tar.gz \
        "https://github.com/ssut/payload-dumper-go/releases/download/${PDG_VERSION}/payload-dumper-go_${PDG_VERSION}_linux_amd64.tar.gz"
    tar -xzf /tmp/pdg.tar.gz -C /tmp
    sudo install -m 0755 /tmp/payload-dumper-go /usr/local/bin/payload-dumper-go
fi
command -v payload-dumper-go >/dev/null 2>&1 || die "payload-dumper-go install failed"

for t in curl wget unzip zip git python3 jq lz4 zstd file rsync xmllint shellcheck \
         simg2img img2simg lpunpack lpmake avbtool mkbootimg unpack_bootimg \
         e2fsck resize2fs tune2fs debugfs mkfs.erofs dump.erofs fsck.erofs payload-dumper-go; do
    ver_line="$("$t" --version 2>&1 | head -n1 || true)"
    log_info "tool ok: $t (${ver_line:-no --version output})"
done

record_status "toolchain" PASS "all required tools present"
log_info "Environment ready."
