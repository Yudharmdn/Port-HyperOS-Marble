#!/usr/bin/env bash
# scripts/10_report.sh -- Phase G prep: consolidated reports.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/../config/port.env"

log_section 10 "GENERATE CONSOLIDATED REPORTS"

# partition-report.md from the classification TSV
{
    echo "# Partition report -- $SOURCE_DEVICE $SOURCE_BUILD -> $TARGET_DEVICE $TARGET_BUILD"
    echo
    echo "| Partition | Available | Classification | Selected origin | Size (bytes) | Filesystem |"
    echo "|---|---|---|---|---|---|"
    tail -n +2 "$REPORT_DIR/partition_classification.tsv" | awk -F'\t' '{printf "| %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6}'
    echo
    cat "$REPORT_DIR/dynamic_partition_sizing.txt" 2>/dev/null
} > "$REPORT_DIR/partition-report.md"

# compatibility.md: single entry point per spec section 34, linking the
# already-generated per-domain reports rather than duplicating them.
{
    echo "# Compatibility report -- $SOURCE_DEVICE $SOURCE_BUILD (Android $SOURCE_ANDROID) -> $TARGET_DEVICE $TARGET_BUILD (Android $TARGET_ANDROID)"
    echo
    echo "## ROM metadata"
    echo '```'
    cat "$REPORT_DIR/rom_metadata.tsv" 2>/dev/null
    echo '```'
    echo
    echo "## Sub-reports"
    echo "- partition-report.md -- classification + dynamic partition sizing"
    echo "- vintf-report.md -- HAL manifest/matrix name-level diff"
    echo "- selinux-report.md -- new SELinux context types needing manual sepolicy"
    echo "- linker-report.md -- missing SONAME dependencies"
    echo "- build-prop-diff.md -- identity/hardware property diff"
    echo "- avb-report.md -- AVB descriptor state"
    echo "- build-summary.md -- the full PASS/WARN/FAIL/NOT TESTED matrix and final statuses"
    echo
    echo "## Scope and honesty notes"
    echo "- Every automated check above is static analysis against extracted"
    echo "  files. None of it constitutes a device boot test."
    echo "- SELinux relabeling on rebuilt EXT4/EROFS images is a best-effort"
    echo "  userspace reimplementation (scripts/lib/apply_contexts.py), not"
    echo "  AOSP's own e2fsdroid/mkuserimg host tools. fs_config (uid/gid/"
    echo "  mode/capabilities) is not reproduced at all. Expect possible"
    echo "  avc: denied entries in logcat; boot with SELinux permissive"
    echo "  first if that happens, per the existing quick-port precedent."
    echo "- Dynamic partition sizing is estimated from shipped partition"
    echo "  sizes (no super.img metadata was available from either"
    echo "  payload.bin-based OTA); it is not a verified device group limit."
} > "$REPORT_DIR/compatibility.md"

record_status "reports_generated" PASS "compatibility.md, partition-report.md and per-domain reports written to $REPORT_DIR"
log_info "Reports ready: $REPORT_DIR"
