#!/usr/bin/env python3
"""payload_meta.py <payload.bin | ota.zip>

Reads the DeltaArchiveManifest of an A/B OTA payload and prints, as
JSON, the dynamic partition groups (name, maximum size, member
partitions) plus every partition's new_partition_info.size.

The group size is the REAL ceiling update_engine / fastbootd enforce
for the sum of the logical partitions in that group -- this replaces
the old "target's current usage + 10%" guess.

Dependency-free protobuf wire-format decoding; field numbers follow
AOSP update_metadata.proto:
  DeltaArchiveManifest.partitions                 = 13 (PartitionUpdate)
  DeltaArchiveManifest.dynamic_partition_metadata = 15
  PartitionUpdate.partition_name = 1, new_partition_info = 7
  PartitionInfo.size = 1
  DynamicPartitionMetadata.groups = 1, snapshot_enabled = 2
  DynamicPartitionGroup.name = 1, size = 2, partition_names = 3
"""
import json
import struct
import sys
import zipfile


def read_varint(buf, pos):
    result = shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, pos
        shift += 7


def fields(buf):
    """Yield (field_number, wire_type, value) for one message."""
    pos, end = 0, len(buf)
    while pos < end:
        key, pos = read_varint(buf, pos)
        fnum, wtype = key >> 3, key & 7
        if wtype == 0:
            val, pos = read_varint(buf, pos)
        elif wtype == 1:
            val = buf[pos:pos + 8]; pos += 8
        elif wtype == 2:
            ln, pos = read_varint(buf, pos)
            val = buf[pos:pos + ln]; pos += ln
        elif wtype == 5:
            val = buf[pos:pos + 4]; pos += 4
        else:
            raise ValueError(f"unsupported wire type {wtype}")
        yield fnum, wtype, val


def read_manifest(stream):
    head = stream.read(20)
    if head[:4] != b"CrAU":
        raise ValueError("not an update_engine payload (missing CrAU magic)")
    major, manifest_size = struct.unpack(">QQ", head[4:20])
    if major >= 2:
        stream.read(4)  # metadata_signature_size
    manifest = stream.read(manifest_size)
    if len(manifest) != manifest_size:
        raise ValueError("truncated payload manifest")
    return manifest


def parse(manifest):
    out = {"groups": [], "partitions": {}, "snapshot_enabled": False}
    for fnum, wtype, val in fields(manifest):
        if fnum == 13 and wtype == 2:
            name, size = None, None
            for f, w, v in fields(val):
                if f == 1 and w == 2:
                    name = v.decode()
                elif f == 7 and w == 2:
                    for f2, w2, v2 in fields(v):
                        if f2 == 1 and w2 == 0:
                            size = v2
            if name is not None:
                out["partitions"][name] = size
        elif fnum == 15 and wtype == 2:
            for f, w, v in fields(val):
                if f == 1 and w == 2:
                    g = {"name": None, "size": None, "partitions": []}
                    for f2, w2, v2 in fields(v):
                        if f2 == 1 and w2 == 2:
                            g["name"] = v2.decode()
                        elif f2 == 2 and w2 == 0:
                            g["size"] = v2
                        elif f2 == 3 and w2 == 2:
                            g["partitions"].append(v2.decode())
                    out["groups"].append(g)
                elif f == 2 and w == 0:
                    out["snapshot_enabled"] = bool(v)
    return out


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            member = next(n for n in z.namelist() if n.endswith("payload.bin"))
            with z.open(member) as s:
                manifest = read_manifest(s)
    else:
        with open(path, "rb") as s:
            manifest = read_manifest(s)
    print(json.dumps(parse(manifest), indent=1))


if __name__ == "__main__":
    main()
