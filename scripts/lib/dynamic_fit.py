#!/usr/bin/env python3
"""dynamic_fit.py estimate <target_meta.json> <source_meta.json> <portable,csv>
   dynamic_fit.py built    <target_meta.json> <image_dir>

Checks the ported partition set against the TARGET device's real
dynamic partition group size(s), read from the target OTA payload
manifest (see payload_meta.py). Prints a human-readable report and
exits 0 if every group fits, 1 if any group overflows, 3 if the target
payload carries no dynamic partition metadata at all.

estimate: portable partitions (system/system_ext/product) sized from
          the SOURCE payload, everything else from the TARGET payload.
          Pre-build only -- the rebuilt images can differ (different
          compression, erofs->ext4 conversion), so the authoritative
          check is `built`.
built:    every group member sized from the actual image in image_dir;
          a member with no image there is reported (it would be left
          as-is / missing on device) and counted as 0.
"""
import json
import os
import sys


def load(p):
    with open(p) as f:
        return json.load(f)


def main():
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    mode, tgt = sys.argv[1], load(sys.argv[2])
    if not tgt.get("groups"):
        print("target payload has no dynamic_partition_metadata groups")
        sys.exit(3)

    if mode == "estimate":
        src = load(sys.argv[3])
        portable = set(sys.argv[4].split(",")) if len(sys.argv) > 4 else set()

        def size_of(p):
            if p in portable and src["partitions"].get(p) is not None:
                return src["partitions"][p], "source payload"
            return tgt["partitions"].get(p) or 0, "target payload"
    elif mode == "built":
        img_dir = sys.argv[3]

        def size_of(p):
            f = os.path.join(img_dir, p + ".img")
            if os.path.isfile(f):
                return os.path.getsize(f), "built image"
            return 0, "NO IMAGE"
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)

    overflow = False
    print(f"snapshot_enabled(virtual A/B)={tgt.get('snapshot_enabled')}")
    for g in tgt["groups"]:
        total = 0
        print(f"group {g['name']}: limit={g['size']} bytes")
        for p in g["partitions"]:
            s, origin = size_of(p)
            total += s
            print(f"  {p:<14} {s:>14}  ({origin})")
        free = (g["size"] or 0) - total
        state = "FITS" if free >= 0 else "OVERFLOW"
        print(f"  {'TOTAL':<14} {total:>14}  -> {state} (free={free} bytes, "
              f"{free / 1024 / 1024:.1f} MiB)")
        if free < 0:
            overflow = True
    sys.exit(1 if overflow else 0)


if __name__ == "__main__":
    main()
