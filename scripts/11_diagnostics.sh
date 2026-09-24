#!/usr/bin/env bash
# scripts/11_diagnostics.sh -- Phase F: optional device test.
# A standard GitHub-hosted runner cannot reboot or reach a physical
# marble phone. This script never pretends otherwise: it only collects
# real diagnostics when RUN_DEVICE_TEST=true AND an ADB device is
# actually present (i.e. a self-hosted runner with the phone attached).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/../config/port.env"

log_section 11 "OPTIONAL PHYSICAL DEVICE DIAGNOSTICS"

if [ "${RUN_DEVICE_TEST}" != "true" ]; then
    log_info "RUN_DEVICE_TEST=false. Static validation completed. Physical device boot verification was not performed."
    record_status "device_boot_test" "NOT TESTED" "RUN_DEVICE_TEST=false"
    exit 0
fi

if ! command -v adb >/dev/null 2>&1 || ! adb wait-for-device -s "${ADB_SERIAL:-}" 2>/dev/null; then
    log_warn "RUN_DEVICE_TEST=true but no ADB device is reachable from this runner (GitHub-hosted runners have no phone attached)."
    log_warn "Static validation completed. Physical device boot verification was not performed."
    record_status "device_boot_test" "NOT TESTED" "no ADB device reachable from this runner"
    exit 0
fi

mkdir -p "$LOG_DIR/device"
DEV="$LOG_DIR/device"
{
    adb shell getprop
    echo "--- key props ---"
    for p in ro.product.device ro.build.version.sdk ro.build.version.release ro.boot.verifiedbootstate sys.boot_completed; do
        printf '%s=' "$p"; adb shell getprop "$p"
    done
} > "$DEV/getprop.txt" 2>&1 || true
adb shell service list        > "$DEV/service_list.txt"        2>&1 || true
adb shell dumpsys package     > "$DEV/dumpsys_package.txt"     2>&1 || true
adb shell dumpsys SurfaceFlinger > "$DEV/dumpsys_surfaceflinger.txt" 2>&1 || true
adb shell dumpsys activity    > "$DEV/dumpsys_activity.txt"    2>&1 || true
adb shell dumpsys meminfo     > "$DEV/dumpsys_meminfo.txt"     2>&1 || true
adb logcat -b all -d          > "$DEV/logcat_all.txt"          2>&1 || true
adb shell dmesg               > "$DEV/dmesg.txt"               2>&1 || true
adb pull /data/tombstones "$DEV/tombstones" >/dev/null 2>&1 || true
adb pull /data/anr "$DEV/anr" >/dev/null 2>&1 || true

boot_completed="$(grep -oE '^sys.boot_completed=[01]' "$DEV/getprop.txt" | cut -d= -f2 || echo "")"
if [ "$boot_completed" = "1" ]; then
    record_status "device_boot_test" PASS "sys.boot_completed=1 observed on attached device; diagnostics collected to $DEV"
else
    record_status "device_boot_test" FAIL "device attached but sys.boot_completed != 1; diagnostics collected to $DEV for review"
fi
log_info "Diagnostics collected: $DEV"
