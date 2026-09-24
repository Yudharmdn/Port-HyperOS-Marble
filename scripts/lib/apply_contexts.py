#!/usr/bin/env python3
"""apply_contexts.py <file_contexts> <root_dir> [<partition_prefix>]

Best-effort re-implementation of Android's file_contexts path matching,
used to set the security.selinux xattr on an extracted tree BEFORE it is
repacked with plain mke2fs/mkfs.erofs (which, unlike AOSP's own forked
host tools, do not know about Android SELinux labeling at all).

KNOWN LIMITATIONS (documented deliberately, not silently skipped):
  * fs_config (uid/gid/mode/capabilities) is NOT reproduced here -- only
    the SELinux label. That is a separate AOSP mechanism.
  * Precedence follows "last matching pattern wins" as file_contexts is
    read top-to-bottom, which is close to but not a byte-exact
    reimplementation of libselinux's regex compilation and match order.
  * Requires CAP_SYS_ADMIN (root) to call os.setxattr for
    security.selinux; the workflow runs this under sudo.
Treat this as a stopgap. For production-fidelity labeling, prefer the
real AOSP host tools (e2fsdroid / mkuserimg_mke2fs / the AOSP fork of
mkfs.erofs with --file-contexts) if you have a verified build of them.
"""
import os
import re
import sys

def compile_patterns(contexts_path):
    patterns = []
    with open(contexts_path, "r", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            path_pat, ctx = parts[0], parts[-1]
            try:
                regex = re.compile(path_pat + "$")
            except re.error:
                continue
            patterns.append((regex, ctx))
    return patterns

def match_context(rel_path, patterns):
    best = None
    for regex, ctx in patterns:
        if regex.match(rel_path):
            best = ctx  # later matches override earlier ones
    return best

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    contexts_path, root_dir = sys.argv[1], sys.argv[2]
    prefix = sys.argv[3] if len(sys.argv) > 3 else ""
    patterns = compile_patterns(contexts_path)

    applied, unmatched = 0, 0
    for dirpath, dirnames, filenames in os.walk(root_dir):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            rel = "/" + prefix.strip("/") + "/" + os.path.relpath(full, root_dir)
            rel = re.sub(r"/+", "/", rel)
            ctx = match_context(rel, patterns)
            if ctx is None:
                unmatched += 1
                continue
            try:
                os.setxattr(full, "security.selinux", ctx.encode() + b"\x00", follow_symlinks=False)
                applied += 1
            except OSError as e:
                print(f"WARN: setxattr failed on {full}: {e}", file=sys.stderr)

    print(f"contexts applied={applied} unmatched(no-rule)={unmatched}")

if __name__ == "__main__":
    main()
