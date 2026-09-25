# Port HyperOS: annibale -> marble (POCO F5)

Cross-device HyperOS port pipeline. Ports the annibale (`OS4.0.0.31.XPKCNXM`,
Android 17) framework/UI onto marble's own hardware stack (`OS3.0.5.0.VMRCNXM`,
Android 15 vendor baseline) via GitHub Actions.

## Before you run it

- Bootloader unlocked on the target marble device (this only produces a
  recovery-flashable ZIP; nothing here unlocks anything).
- **Run with `analysis_only: true` first.** Android 17 framework against an
  Android 15 vendor baseline is a real framework/vendor boundary, not a
  cosmetic version bump -- read `build/reports/compatibility.md` from that
  run before ever setting `analysis_only: false`.
- A custom recovery (OrangeFox/TWRP) on marble. The output package is
  recovery-flash-only; there is no fastboot `flash.sh` path in this version.

## What "PASS" actually means here (read this)

Every check in `build/reports/build-summary.md` is real, but static:

- **VINTF / linker / SELinux-type checks** compare names and structural
  facts extracted from the ROMs. They catch missing HALs, missing shared
  libraries, and SELinux types with no target policy rule. They do **not**
  check runtime behavior, symbol-level ABI, or AIDL/HIDL semantic
  compatibility -- a PASS there is "nothing obviously missing," not
  "guaranteed to work."
- **SELinux relabeling on rebuilt vendor/odm EXT4 images is best-effort**
  (`scripts/lib/apply_contexts.py`), not AOSP's own `e2fsdroid`/
  `mkuserimg_mke2fs`. `fs_config` (uid/gid/mode/capabilities) is not
  reproduced at all. This is the same tradeoff the earlier quick-port hit
  in practice: if you see `avc: denied` in logcat after flashing, boot
  with SELinux permissive once to confirm, then expect to hand-patch
  policy for that path.
- **Dynamic partition sizing is an estimate.** Both ROMs ship as
  `payload.bin`-based full OTAs with no standalone `super.img` to `lpdump`,
  so capacity is inferred from marble's currently-shipped partition sizes
  plus a slack margin, not a verified device group limit.
- **`avb_boot_descriptor_mismatch` is a best-effort text match, not a
  parsed AVB structure.** When `use_custom_boot_img` replaces `boot.img`,
  `09_validate_package.sh` greps `avbtool info_image`'s human-readable
  output for a `Partition Name: boot` line to decide whether vbmeta
  still expects the original image. It errs toward FAIL when it finds
  that line and AVB isn't disabled -- but a WARN instead of a clean
  PASS/FAIL means the grep itself was inconclusive; read `avb-report.md`
  directly in that case rather than trusting the ledger alone.
- **"Device boot test: NOT TESTED" is the expected, honest default.** A
  GitHub-hosted runner cannot reboot your phone. `scripts/11_diagnostics.sh`
  only collects real ADB diagnostics if it's ever pointed at a self-hosted
  runner with the device attached; otherwise it says so plainly instead of
  guessing.

Build success, package success, static-validation success, and device-boot
success are four different claims. This pipeline only ever asserts the
first three, and labels the fourth "NOT TESTED" until it's actually true.

## Layout

```
config/port.env                    all tunables, defaults, no secrets
scripts/lib/common.sh               logging + the PASS/WARN/FAIL/NOT-TESTED ledger
scripts/lib/apply_contexts.py       best-effort SELinux relabeling (see caveat above)
scripts/01_toolchain.sh             Phase A: tool install
scripts/02_download_verify.sh       Phase A: download + integrity
scripts/03_extract_detect.sh        Phase A: payload.bin/super.img/loose-image detection
scripts/04_inventory_classify.sh    Phase A/B: partition classification + sizing
scripts/05_compatibility_analysis.sh Phase A/D: VINTF/SELinux/linker/ART/props
scripts/06_merge_port.sh            Phase C: workspace construction
scripts/07_rebuild_images.sh        Phase C: fstab patch + image rebuild
scripts/08_kernel_integration.sh    Phase C: custom boot.img swap + optional root-variant zip
scripts/09_validate_package.sh      Phase D/E: final gate + streaming-ZIP packaging
scripts/10_report.sh                Phase G prep: consolidated reports
scripts/11_diagnostics.sh           Phase F: optional real-device diagnostics
.github/workflows/port-hyperos.yml  orchestrates all of the above
```

## Kernel integration

Two independent mechanisms, confirmed by inspecting each repo's real
release assets rather than assumed:

**1. The boot image itself -- `use_custom_boot_img: true` (default).**
Fetches `boot.img` from `Yudharmdn/boot-melt-rebase`'s latest release
(confirmed: a single real 192MB `boot.img` asset, sha256 `29ea2b8f...
c3fa3`) and **replaces** marble's passthrough `boot.img` with it before
packaging. This is a real substitution, not a companion file -- and it
has a real consequence: vbmeta's original AVB hash descriptor for
`boot` no longer matches, so verification will fail on a locked/
enforcing bootloader. `09_validate_package.sh` checks for this
explicitly (`avb_boot_descriptor_mismatch` in the status ledger) and
**fails the build** unless `disable_avb_for_testing: true` is also set
or you re-sign vbmeta yourself. If the target ROM ships a separate
`init_boot` partition (common on Android 13+ GKI devices, which marble
likely is), this stage also unpacks the fetched `boot.img` to check
whether it still bundles its own ramdisk -- a combined-format image on
a split-scheme device is a common, distinct bootloop cause, and this
check exists specifically to catch that mismatch before you flash.

**2. An optional post-boot root solution -- `build_kernel: true`.**
Separate from (1) and not required for the port to boot. Inspecting
`yudharn/POCOF5-Melt-Rebase-Kernel-Marble`'s latest release shows it
actually ships **six** differently-named AnyKernel3-style zips --
KernelSU-Next, Official-KernelSU, and ReSukiSU, each in CORE and FULL
variants, all bundled with SuSFS-NoMount -- not one generic kernel zip.
These patch an *existing* boot image to add root management; they are
unrelated to which kernel actually boots the device. Because six
meaningfully different root solutions is a real decision, this
pipeline never glob-guesses one: set `KERNEL_ROOT_VARIANT_ASSET_NAME`
in `config/port.env` to the exact asset filename you want (e.g.
`Melt-Rebase-KernelSU-Next-FULL-SuSFS-NoMount-5.10.270.zip`), or it is
skipped with a WARN. `KERNEL_TRIGGER_PAT` can instead trigger a fresh
build via the private CI repo's `workflow_dispatch` (never a cross-repo
`workflow_call`, which is blocked public->private) before fetching the
same named asset. If used, flash the ROM ZIP (boot.img already swapped
inside it), then this zip, in the same recovery session.

## Known gaps, stated plainly

- No fastboot/`flash.sh` path (recovery-only, unlike the earlier quick-port).
- `fs_config` (uid/gid/mode/capabilities) is not reproduced on rebuilt images.
- Deep per-APK/per-service dependency semantics (spec sections 14-15,
  44) are classified at the whole-partition level, not the individual
  package level -- HyperOS app-by-app hardware-dependency classification
  is flagged as a manual-review checklist item in `compatibility.md`,
  not automated line-by-line.
- The repo name given for kernel integration in the original brief
  (`yudharn/Melt-Kernel-Marble`) didn't match any real repo.
  `KERNEL_SOURCE_REPO` / `KERNEL_BOOT_IMG_REPO` / `KERNEL_ARTIFACT_REPO`
  are separate, overridable inputs, each pointed at a repo whose actual
  release assets were checked directly (not assumed) -- see "Kernel
  integration" above for exactly what was found.
- `boot_init_boot_split_check` (when it runs) trusts `unpack_bootimg`'s
  text log to read the boot-image header version and ramdisk size; a
  malformed or unusually-formatted log falls back to a WARN rather than
  a false PASS, but isn't a substitute for confirming the split/combined
  format against Melt-Rebase's own build notes.
- No AVB re-signing is performed anywhere in this pipeline. Once
  `use_custom_boot_img` trips `avb_boot_descriptor_mismatch`, the only
  paths forward are `disable_avb_for_testing: true` (writes a separate,
  clearly-named disabled-verification vbmeta) or re-signing vbmeta
  yourself with a key the bootloader trusts -- this script does neither
  silently.
- `bash -n`/shellcheck do not catch every real failure mode. A live run
  found `readelf -d <elf> | grep NEEDED | ...` silently killing the
  entire script the moment it hit any binary with zero NEEDED entries
  (extremely common) -- under `set -e -o pipefail`, grep finding
  nothing is treated as a hard failure, with no error message at all,
  not a "no results" case. Fixed here and audited for the same pattern
  everywhere else in the codebase, but a shell script can still fail
  this way somewhere static analysis won't flag; a live run remains
  the real test.
- Toolchain package names were corrected after a real first run failed
  on them (`android-sdk-libufdt-utils` doesn't exist, and apt aborts an
  entire multi-package install the moment one name is unresolvable --
  which had also been silently blocking otherwise-fine packages in the
  same batch). `simg2img`/`img2simg`/`unpack_bootimg` are now confirmed,
  live-tested real packages, and `ensure_tools` now installs one
  package at a time so a single bad name can't take others down with
  it. Two things stay genuinely open rather than papered over: the
  `mkbootimg` binary that ships alongside `unpack_bootimg` is confirmed
  broken on Ubuntu 24.04 (crashes on any invocation from a dependency
  the package never declares) -- harmless here since only
  `unpack_bootimg` is ever called -- and `lpunpack` has no official
  package at all, so it's checked lazily where it would actually be
  used (a standalone-`super.img` ROM) rather than required for every
  run; today's payload.bin-based pair never reaches that path.
- The `payload-dumper-go` version this pipeline pins was also wrong
  (`1.3.2` never existed as a real tag -- confirmed via a live 404).
  Bumped to `2.1.0`, the real latest, with its CLI flags (`-list`/`-o`)
  confirmed unchanged from the 1.x line, and its download is now
  checksummed against the release's own published sha256 file.
