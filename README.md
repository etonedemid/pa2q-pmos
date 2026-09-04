# pa2q-pmos — postmarketOS display bring-up on Galaxy S25+ (SM-S936B / SM8750 "sun")

Work-product and findings for getting the internal DSI panel working under
postmarketOS on the Samsung Galaxy S25+ (codename **pa2q**, SoC **SM8750 / "sun"**,
panel **PA2_S6E3HAF_AMB666FM03**), dual-booting with stock Android.

This repo is **not** the kernel tree — it holds the display-driver source changes,
the build recipe, the recovery tooling, and the investigation notes.

---

## TL;DR of the current state

- Stock Android's `msm_drm.ko` (a **prebuilt**, vermagic `6.6.77-android15…abogkiS936B…`)
  loads on our rebuilt **6.6.98** GKI kernel and drives the panel fine (this is the
  known-good baseline: SDDM greeter comes up).
- We **can build a custom `msm_drm.ko` from source** that loads and runs on our kernel
  (vermagic matches exactly, symbol CRCs accepted). This was the make-or-break
  feasibility question — answered yes.
- **BUT**: our from-source module, built against the GKI kernel tree (`k698`),
  **hard-hangs the SoC** shortly after the panel comes up (splash renders, then the
  whole SoC freezes — no display handover, no WiFi, no ssh).
- **Isolation result (important):** a *control* build with **none** of our logic
  patches — only the config changes needed to compile against `k698` — hangs
  identically. **So the hang is caused by how the module is built, not by any code
  patch.** The prime remaining suspects are the disabled DP/DeX/HDCP/VM feature set
  and/or a silently-missing `CONFIG_*` that changes the ABI of a struct shared with
  the kernel or another prebuilt module.

---

## The original problem we set out to fix

With the **prebuilt** module, the panel works but the display **cannot survive a
disable→enable transition**:

- SDDM **greeter → user session handover** goes black (the greeter's compositor is
  torn down and the session's compositor re-enables the display).
- **Power-button DPMS wake** fails the same way.

Captured failure signature (prebuilt module, via `/sys/kernel/debug/dri/0/debug/dump`
and dmesg):

```
sde_cesta: cesta:0 mode2 entry failed, trial:10, status:0x0
sde_cesta_resource_disable: mode2 entry failed ret:-16
... on re-enable:
dsi_ctrl_dma_cmd_wait_for_done: Timeout!!  → panel_dead 1
sde_crm_reg = all zeros   (CRM wedged)
```

**Root cause (confirmed):** on a full display disable, `sde_cesta` asks the MDSS GDSC
to power-collapse (mode2). On this port the GDSC never reports collapse
(`BIT(12)` of the RSCC pwr-ctrl status never sets), so `_sde_cesta_check_mode2_entry_status()`
returns `-EBUSY` after 10×50µs, `sde_cesta_resource_disable()` bails **early** leaving
clocks gated + GDSC on + CRM mid-sequence, and the next enable can't talk to the panel
(`dsi_ctrl_dma_cmd_wait_for_done` timeouts → `panel_dead`). The display works only as
long as it **never** fully power-collapses (which is also why idle-pc is removed from
the dtbo).

**Attempted fix** (`display-driver/sde_cesta.c`, see the FIX note below): make the
mode2-collapse failure non-fatal in `sde_cesta_resource_disable()` and treat the block
as never-power-collapsing (same model as idle-pc-off). This is *logically* the right
direction, but we could never validate it because the from-source module hangs the SoC
for an unrelated (build) reason — see next section.

---

## What is actually built wrong (the current blocker)

The prebuilt was built by Samsung **against the Qualcomm `msm-kernel` tree** with the
full SoC defconfig. Our from-source build is **against the GKI common kernel (`k698`)**,
which is missing many `CONFIG_*` symbols the display code checks with `IS_ENABLED()`.
Each missing one either failed the build or silently changed behavior. Found so far:

| Missing `CONFIG_*` | Symptom | Fix |
|---|---|---|
| `CONFIG_ARCH_SUN` | `MASS_CMD_ALIGN` undeclared (build error) | force-define in `gki_sundispconf.h` |
| `CONFIG_QCOM_CRM_V2` | `soc/qcom/crm.h` gave `sde_cesta` a **stub** `crm_get_device()` returning `-ENODEV`; cesta never bound → no `/dev/dri` | force-define |
| `CONFIG_REGULATOR_S2DOS07` | `MODULE_SOFTDEP("pre: s2dos07")` dropped → sub-PMIC never pre-loaded → `panel_vddr` missing → panel deferred forever | force-define |

DP / DeX / HDCP / Trusted-VM were **disabled** (`CONFIG_DRM_MSM_DP`,
`CONFIG_DRM_MSM_DP_MST`, `CONFIG_HDCP_QSEECOM`, `CONFIG_DRM_SDE_VM`) because their
source needs `msm-kernel`-only headers absent from `k698` (`linux/gunyah/gh_irq_lend.h`,
`linux/hdcp_qseecom.h`). Symbol diff vs the prebuilt: the **only** differences are
DP (670 syms), HDCP (111), VM (45) — everything else is byte-identical source, and the
two `soc/qcom/crm.h` are identical (no crm ABI mismatch).

**Open question / next step:** whether the SoC hang is caused by disabling DP/VM, or by
another silently-missing `CONFIG_*` that changes a *shared* struct's layout (an ABI
break invisible to the symbol diff, since we bypass modversions CRC on cross-module
imports). The clean way forward is to build **with the full msm-kernel config** (i.e.
match the prebuilt's config exactly), rather than a GKI subset.

---

## Build recipe (from-source `msm_drm.ko`)

- Toolchain: `~/toolchains/clang-r510928` (AOSP clang).
- Kernel objtree: `k698/out-698ns` (the running 6.6.98 kernel; built by `k698/build-698-ns.sh`).
  `make Image` doesn't write `Module.symvers`, so copy `vmlinux.symvers` → `Module.symvers`
  and set `KBUILD_MODPOST_WARN=1` so cross-module imports become unversioned (accepted
  at load; the running kernel loads foreign-vermagic prebuilts anyway).
- External-module build: `make -C out-698ns M=<display-drivers> modules CONFIG_DRM_MSM=m CONFIG_ARCH_SUN=y`.
- See `build/build-msmdrm.sh` (build) and `build/deploy-msmdrm.sh` (build+strip+push+swap+depmod+reboot).

The rebuilt module's vermagic matches the running kernel exactly, so it loads cleanly;
`depmod -a` on-device is required after swapping so `modules.dep` resolves the deps
(the from-source `.ko` has empty modinfo `depends:` because no cross-module symvers).

---

## Safety net for testing (never download-mode again)

`msm_drm` auto-loads at boot from **`/etc/modules`** (explicit) — but a device-side
`depmod` regenerates `modules.alias`, and then **udev coldplug** also auto-loads it by
modalias. So to fully stop boot-time loading you need **both**:

1. `/etc/modprobe.d/zz-test-msmdrm.conf` → `blacklist msm_drm`  (stops coldplug/alias load)
2. comment `msm_drm` out of `/etc/modules`  (stops explicit load)

Then boot always reaches ssh with no display, and you test with an **explicit**
`modprobe msm_drm` (blacklist doesn't block explicit loads). If the module hangs the
SoC, it resets and comes back clean (blacklisted) — **no download mode needed**.
There is also a vol-up-at-boot → switch-to-Android escape hatch
(`device/bootkey-recovery.py` + `.initd`).

---

## Recovery: fixing the pmOS rootfs from Android

When a bad module bricks the pmOS boot and ssh is gone, recover via Android (which has
ReSukiSU root and can reach the pmOS partition):

1. Download mode → `heimdall flash --BOOT_A boot_a.img --VENDOR_BOOT_A vendor_boot_a.img --DTBO_A dtbo_a.img`
   (stock Android set; boots Android with root; **does not** touch pmOS on sda60).
2. `adb` + `su`. pmOS rootfs is **`/dev/block/sda60`** (by-name `pmOS_root`), separate
   from userdata (sda59).
3. sda60 is a **4K-logical GPT disk image** (dd'd from `samsung-pa2q.img`). GPT header is
   at byte 4096 (4K LBA 1). Rootfs = partition 2 at **byte offset 511705088** (255 GB);
   partition 1 (8 MB…, 480 MB) is pmOS /boot.
4. A normal `losetup -o` loop presents **512-byte** sectors and gets EIO on the 4K disk.
   Use `recovery/loopcfg.c` (freestanding aarch64, `LOOP_CONFIGURE` with `block_size=4096`
   **and `LO_FLAGS_DIRECT_IO`** — direct-IO is what finally makes reads succeed):
   ```
   losetup -f                       # pick a free /dev/block/loopN
   loopcfg /dev/block/loopN /dev/block/sda60 511705088 4096
   mount -t ext4 -o rw /dev/block/loopN /mnt/pmosroot
   ```
   Build: `clang --target=aarch64-linux-gnu -static -nostdlib -ffreestanding -O2 loopcfg.c -o loopcfg`.
5. Restore the module: `cp .../vendor/msm_drm.ko.prebuilt .../vendor/msm_drm.ko`.
6. Flash the pmOS boot chain back from the images on the rootfs itself
   (`/mnt/pmosroot/var/lib/dualboot/pmos/{boot-ns-heap.img,vendor_boot-current.img,dtbo-noidlepc-nocbc.img}`
   → `/dev/block/by-name/{boot_a,vendor_boot_a,dtbo_a}` with `dd … conv=fsync`).
7. `umount`, `losetup -D`, `adb reboot`.
8. **After restoring the module, run `depmod -a` on pmOS** (a plain `cp` leaves
   `modules.dep` stale → the prebuilt fails to pull `drm_display_helper` → unresolved
   `drm_dp_*` symbols → no display).

---

## Device facts

- Partitions (4K logical): `boot_a`=sda26, `vendor_boot_a`=sda28, `dtbo_a`=sda36,
  `init_boot_a`=sda27 (untouched, Android's `/init`), `userdata`=sda59, `pmOS_root`=sda60.
- Dual-boot switcher: `device/boot-switch` (writes+verifies boot/vendor_boot/dtbo, reboots).
- `heimdall` PIT partition names: `BOOT_A`, `VENDOR_BOOT_A`, `DTBO_A`.
- SSH host alias `pa2w` (config-only alias, not DNS-resolvable) = 192.168.31.228.
- Kernel: `6.6.98-pd6ff1cd-abogkiS9380ZHUBCZF1-4k`; `CONFIG_MODVERSIONS=y`,
  `CONFIG_MODULE_SIG_PROTECT=y` but `SIG_FORCE` off (foreign-signed prebuilts load).

## FIX note (sde_cesta.c)

The committed `display-driver/sde_cesta.c` is currently the **control** (stock cesta:
mode2 failure returns `-EBUSY`) plus one harmless robustness change — `crm_get_device`
failure returns `-EPROBE_DEFER` instead of a hard fail, so the module can be loaded
on-demand after boot without racing crm_v2's registration. The **display-handover fix**
(make `sde_cesta_resource_disable` mode2 failure non-fatal) is described above under
"The original problem"; re-apply it once the from-source build no longer hangs.
