# Port HyperOS: annibale -> marble (POCO F5)

Cross-device HyperOS port pipeline. Ports the annibale (`OS4.0.0.31.XPKCNXM`,
Android 17) framework/UI onto marble's own hardware stack (`OS3.0.5.0.VMRCNXM`,
Android 15 vendor baseline) via GitHub Actions.

## Before you run it

- **Unlocked bootloader** on marble. A real build rebuilds system/
  system_ext/product/vendor/odm and (by default) swaps boot.img, so it can
  only boot with AVB verification disabled -- which needs an unlocked
  bootloader.
- **Run with `analysis_only: true` first** and read
  `build/reports/compatibility.md`.
- For `analysis_only: false`, also tick `disable_avb_for_testing`
  (explained under "AVB" below) -- without it the build FAILs on purpose.
- Flashing: custom recovery (OrangeFox/TWRP) **or** the generated
  `flash_fastboot.sh` / `.bat`. Use fastboot if the recovery reports that a
  partition is too small and it has no `lptools` -- fastbootd resizes
  logical partitions itself.

## What each check really decides

Static checks only; "Device boot test: NOT TESTED" stays until a real
device run (`11_diagnostics.sh` on a self-hosted runner) says otherwise.

- **VINTF** (`vintf_fcm_level`, `vintf_kernel`, `vintf_required_hals`):
  mirrors libvintf's decision -- picks the Android 17 framework matrix at
  marble's FCM `target-level`, FAILs if that level is no longer supported,
  if the matrix doesn't allow kernel `TARGET_KERNEL_VERSION` (5.10), or if
  a HAL marked `optional="false"` is missing. HALs without that marker are
  optional (default since the Android V-era libvintf change; the tag isn't
  supported from Android 16). Does not run libvintf itself.
- **SELinux** (`selinux_mapping`): FAILs if the source platform policy has
  no `mapping/<ver>.cil` for marble's `plat_sepolicy_vers.txt` -- without
  it the split policy cannot compile at boot. Runtime denials can only be
  found on a real boot.
- **Labels / fs_config** (`selinux_labels`): partitions are extracted as
  root with ownership, modes, SELinux labels and file capabilities
  preserved (patched erofs-utils 1.9.4, see `01_toolchain.sh`), so the
  images are rebuilt with the device maker's real metadata.
  `apply_contexts.py` only fills labels that are genuinely missing.
- **Linker** (`linker_analysis`): every DT_NEEDED of the ported framework
  must exist somewhere in source+target, including inside `.apex` and
  compressed `.capex` modules. Name-level only, not symbol-level ABI.
- **Dynamic partitions** (`dynamic_partition_sizing`): the limit is
  marble's real group size read from its own OTA payload manifest
  (`lib/payload_meta.py`); 04 records a pre-build estimate, 09 checks the
  actual built images and blocks packaging if they don't fit.
- **fstab** (`fstab_patch`, `first_stage_fstab`): vendor/odm converted to
  ext4 get an ext4 entry in `/vendor/etc/fstab.*`; and because first-stage
  init mounts from the **vendor_boot ramdisk** fstab, that fstab is
  unpacked and checked too -- FAIL if it has no ext4 entry for them
  (fix: `VENDOR_ODM_FS=erofs`; vendor_boot is not repacked).

## AVB

Rebuilt images and a replaced boot.img no longer match marble's
vbmeta/vbmeta_system descriptors. With `disable_avb_for_testing: true`
the **packaged** `vbmeta.img` and `vbmeta_system.img` are freshly authored
flags=3 images (verity + verification off); marble's originals stay in
`build/images/*.ORIGINAL.img` and are not flashed. Without the flag the
build FAILs (`avb_state`) -- re-signing is not implemented. This is an
explicit, logged opt-in, never a silent disable.

## Layout

```
config/port.env                        all tunables, defaults, no secrets
scripts/lib/common.sh                  logging + PASS/WARN/FAIL/NOT-TESTED ledger
scripts/lib/apply_contexts.py          fill-only SELinux labeling for unlabeled files
scripts/lib/payload_meta.py            reads groups/sizes from an OTA payload manifest
scripts/lib/dynamic_fit.py             group-capacity check (estimate / built images)
scripts/lib/erofs-fsck-preserve-caps.patch  keeps file capabilities on erofs extract
scripts/01_toolchain.sh ... 11_diagnostics.sh   phases A-G
.github/workflows/port-hyperos.yml     orchestrates all of the above
```

## Kernel integration

**1. The boot image -- `use_custom_boot_img: true` (default).** Fetches
`boot.img` from `Yudharmdn/boot-melt-rebase` (192MB, sha256
`29ea2b8f...c3fa3`) and replaces marble's boot.img. This is one reason AVB
must be disabled (see above). If marble ships a separate `init_boot`, the
fetched image is unpacked to check it isn't a combined-ramdisk image.

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

- No AVB re-signing; builds require an unlocked bootloader.
- vendor_boot is never repacked, so the first-stage fstab can't be
  changed by this pipeline -- only checked.
- The recovery installer can only grow a logical partition if the
  recovery ships `lptools`; otherwise use the fastboot script.
- VINTF, linker and SELinux checks are static. A clean matrix means
  "no known blocker", not "boots". Only `11_diagnostics.sh` on a real
  device can say more.
- `mi_product` (annibale-only, unknown role) is excluded; marble has no
  slot for it. Features that read from it will be missing.

## Bugs found by real runs (all fixed)

Toolchain package names and payload-dumper-go version; `set -e` crash on
ELFs with no NEEDED; SIGPIPE false negatives in grep checks; passthrough
silently copying annibale's `init_boot`; relabel running without root;
APEX/CAPEX libraries counted as missing; VINTF treating optional HALs as
required and picking an arbitrary matrix; sizing against a guessed limit;
fstab `ro->rw` writing a literal `\1rw\2` into the vendor mount flags;
ext4 vendor/odm with no ext4 fstab entry; extraction dropping SELinux
labels and file capabilities; installer flashing the original vbmeta over
rebuilt images and `dd`-ing into too-small logical partitions.
