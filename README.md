# pa2q-pmos — postmarketOS on the Galaxy S25+ (SM-S936B / SM8750 "sun")

Bring-up work-product and findings for running **postmarketOS** on the Samsung
Galaxy S25+ — codename **pa2q**, SoC **SM8750 / "sun"**, panel
**PA2_S6E3HAF_AMB666FM03** — **dual-booting alongside stock Android**.

This repo is **not** the kernel tree. It collects the source changes, build
recipes, on-device tools, recovery tooling, and the investigation notes that
together make the device boot pmOS. The kernel source itself lives in the
`android_kernel_samsung_sm8750` fork; the pmOS-specific additions are mirrored
here under [`kernel/`](kernel/) so the whole picture is in one place.

---

## Status at a glance

| Area | State |
|---|---|
| Dual-boot Android ⇄ pmOS (one-command switch) | ✅ working |
| pmOS boots on internal storage, reaches SSH | ✅ working |
| Serial earlycon (UART jig) | ✅ documented, gated on hardware jig |
| Boot-splash console (no UART needed) | ✅ working |
| Gunyah hypervisor watchdog tamed | ✅ working (required for boot) |
| Wi-Fi | ✅ working |
| SYSVIPC + namespaces (Android side, containers/chroot) | ✅ working |
| Display — SDDM **greeter** renders | ✅ working (via bootloader cont-splash) |
| Display — greeter→session login, DPMS wake | ❌ panel-on sequence fails (see below) |

The **display is the remaining hard problem.** Everything else needed to live on
the device is in place.

---

## Repo layout

```
kernel/          pmOS-specific kernel additions + build recipes
  build-local.sh            Android-config kernel build (24-core host)
  build-pmos-local.sh       pmOS-config kernel build (rdinit, VT, devtmpfs, splash)
  build-698-ns.sh           k698 GKI "module-friendly" build (the running kernel)
  splashcon.c / _logo.h     boot-splash console (renders into cont-splash FB)
  gh_wdt_tame.c             tame the Gunyah hypervisor watchdog (SMCCC)
  EARLYCON.md               serial console bring-up over the USB-C debug UART
  kconfig-hooks.diff        the in-tree Kconfig/Makefile hooks for the above
  defconfig-namespaces.patch, defconfig-sysvipc.patch   defconfig deltas

display-driver/  the display stack work
  sde_cesta.c               cesta mode2 non-fatal source change
  msm_gem_prime.c           the vmid-import path (candidate pmOS fix, documented)
  config/                   gki_sundisp.conf, gki_sundispconf.h (GKI-external config)
  FINDINGS.md               full display investigation + real root cause
  msm_drm-cesta-mode2.patch.md   the 4-byte binary patch of the stock module

build/           display module build/deploy scripts
  build-msmdrm.sh, deploy-msmdrm.sh

device/          on-device tools
  boot-switch               write+verify boot chain, switch Android⇄pmOS
  bootkey-recovery.py/.initd vol-up-at-boot → switch to Android escape hatch
  dispcap                   capture the panel framebuffer

recovery/        rootfs repair from Android
  loopcfg.c                 4K-native loop mount helper (LOOP_CONFIGURE + DIRECT_IO)
  setloopbsz.c              set loop block size
```

---

## Device facts

- **SoC:** Qualcomm SM8750 "sun". **Panel:** PA2_S6E3HAF_AMB666FM03, 1440×3120,
  command-mode DSI, 120 Hz.
- **Running kernel:** `6.6.98-pd6ff1cd-abogkiS9380ZHUBCZF1-4k` (GKI 2.0), built
  from `k698` / `out-698ns`. `module_layout` CRC **`0x81972209`** — remember this
  number, it decides whether any vendor module will load.
- `CONFIG_MODVERSIONS=y`; `CONFIG_MODULE_SIG_PROTECT=y` but `SIG_FORCE` off, so
  foreign-signed / foreign-vermagic Samsung prebuilts load (GKI gates on
  `module_layout` + KMI CRCs, not the release string).
- **Partitions** (4K-logical GPT): `boot_a`=sda26, `init_boot_a`=sda27 (Android's
  `/init`, untouched), `vendor_boot_a`=sda28, `dtbo_a`=sda36, `userdata`=sda59,
  **`pmOS_root`=sda60**.
- **USB networking (pmOS):** CDC-NCM gadget, device `172.16.42.1`, host
  `172.16.42.2/24`. SSH in as `root`.

### Root and dual-boot (an unusual arrangement)

- **Android runs the stock `boot_a.img` byte-for-byte.** Root comes from
  **ReSukiSU in LKM mode** (a module loaded from `/data/adb`), not a patched boot
  image — the patched boot-ksu image bootloops this firmware. See the
  [ReSukiSU/SuSFS version ceiling](#credits--caveats) note.
- Samsung **ignores the AOSP boot-control BCB**: `init_boot`'s `/init` wins, and
  the recovery entry is `/system/bin/recovery`. So dual-boot is done by swapping
  the **`boot` / `vendor_boot` / `dtbo`** trio, not via slots.
- [`device/boot-switch`](device/boot-switch) writes and **md5-verifies** all three
  images, then reboots:
  ```
  boot-switch android     # stock kernel + ReSukiSU root
  boot-switch pmos        # postmarketOS on sda60
  ```
  It refuses to write a half-set (a missing image would leave an unbootable
  kernel/ramdisk mix).
- **Escape hatch:** hold **Volume-Up at boot** → [`device/bootkey-recovery`](device/)
  switches back to Android. The one reliable way out when the GUI is broken.

---

## Kernel build

Toolchain is **mandatory**: AOSP **clang r510928** at `~/toolchains/clang-r510928`.
A distro clang silently drops `CFI_CLANG` / `SHADOW_CALL_STACK` and flips
`KASAN_HW_TAGS`→`KASAN_GENERIC`, which **breaks the GKI KMI** and stops Samsung's
prebuilt vendor modules from loading. The build scripts assert these configs are
present and abort otherwise.

- [`kernel/build-local.sh`](kernel/build-local.sh) — Android defconfig build.
- [`kernel/build-pmos-local.sh`](kernel/build-pmos-local.sh) — pmOS build; uses the
  pmaports config carrying the pmOS delta (`VT`, `DEVTMPFS_MOUNT`, `SPLASH_CONSOLE`,
  `rdinit=/pmos-init`, `PANIC_ON_OOPS` off).
- [`kernel/build-698-ns.sh`](kernel/build-698-ns.sh) — the **k698** build that
  produces the running kernel and a usable `Module.symvers` for out-of-tree modules.

> **The single most important build fact:** vendor modules must be built
> **versioned against `out-698ns/Module.symvers`** (`module_layout 0x81972209`).
> Building against `msm-kernel/out_sun` gives `module_layout 0x630748eb` and every
> module fails to load (`disagrees about version of symbol module_layout`) or, if
> built unversioned, hangs the SoC. See [display-driver/FINDINGS.md](display-driver/FINDINGS.md).

### `rdinit` is the only pmOS boot path

pmOS boots via `rdinit=` into the initramfs on internal storage; the display must
be grabbed early. `gh_wdt_tame` is required or the device resets ~20 s in.

---

## pmOS bring-up pieces

### Boot visibility with no UART — `splashcon`

The debug UART is behind a 619 kΩ USB-C SBU jig, so an early boot failure is
otherwise **completely silent**. [`kernel/splashcon.c`](kernel/splashcon.c) renders
the kernel log straight into the **bootloader's continuous-splash framebuffer**
(addr from the dtbo `cont_splash_region`, `0xfc800000`). The region has no
`no-map`, so it stays in the linear map — `ioremap()` WARNs and returns NULL — so
splashcon uses `phys_to_virt()` + `dcache_clean_poc()` after every update so the
display controller sees the stores. Enable with `CONFIG_SPLASH_CONSOLE`
(pa2q-specific; do not enable elsewhere).

### Serial console — `EARLYCON.md`

If you *do* have the UART jig: [`kernel/EARLYCON.md`](kernel/EARLYCON.md) documents
`earlycon=qcom_geni,0x00a9c000 keep_bootcon` (SM8750 uart7, 115200 8N1, **1.8 V**),
why `keep_bootcon` is required, the `CMDLINE_EXTEND` ordering, and the one real
bootloop risk (an unclocked SE MMIO read NoC-erroring).

### Taming the watchdog — `gh_wdt_tame`

XBL arms a Gunyah hypervisor watchdog before Linux starts. Android's
`gh_virt_wdt.ko` **warm-resets this device on probe** (deterministically), so it
can't be used — but then nothing pets the watchdog and the device resets ~20 s
into boot. [`kernel/gh_wdt_tame.c`](kernel/gh_wdt_tame.c) talks to the watchdog via
the SMCCC IDs recovered from disassembling `gh_virt_wdt.ko` (`SMC 0x86000005` w1=2
disable / 3 enable, `SMC 0x86000007` pet): it tries to disable, and falls back to
petting on a timer. Bring-up aid — it leaves the device with no working watchdog.

### Wi-Fi

Working: **CBC disabled in the dtbo**, MAC read from `/efs`, a `/vendor` symlink so
firmware paths resolve, and the modem brought up. (dtbo variant
`dtbo-noidlepc-nocbc.img`.)

### SYSVIPC + namespaces (Android side)

For containers / chroot on the Android side: `SYSVIPC` enabled ABI-safely on
ReSukiSU + SuSFS, plus `PID_NS`, `DEVTMPFS`, `USER_NS`. Defconfig deltas in
[`kernel/defconfig-sysvipc.patch`](kernel/defconfig-sysvipc.patch) and
[`kernel/defconfig-namespaces.patch`](kernel/defconfig-namespaces.patch).

---

## Display — the remaining hard problem

Full write-up: **[display-driver/FINDINGS.md](display-driver/FINDINGS.md)**. Summary:

- The stock `msm_drm.ko` (shipped on-device as `msm_drm.ko.prebuilt`, vermagic
  `6.6.77-…-BYI3`, `module_layout 0x81972209`) **loads and drives the panel** — the
  SDDM greeter comes up. This is the known-good baseline.
- **The greeter only works because of the bootloader continuous-splash handoff:**
  the kernel adopts the already-lit panel and never runs a real panel-on sequence.
- **The bug:** at login, kwin does the first **real DRM modeset** — a genuine panel
  off→on — and the panel-on / DSI init sequence **fails under pmOS**
  (`wait_for_tx_complete -110` → `no TE` → `panel_dead` → `dsi cmd rc=-22`,
  `display_on:0`). DPMS/power-button wake is the same off→on, so both fail.
- A secondary chronic issue: `msm_gem_prime_import: get vmid list failure ret:-22`
  — kwin's GBM buffers carry no `mem_buf` vmperm metadata, so imports fail. A
  candidate fix (return "non-secure" instead of `-EINVAL`) is noted in FINDINGS.

### The objtree lesson (what wasted the most time)

An earlier effort rebuilt the whole vendor module set against the **wrong** kernel
objtree (`msm-kernel/out_sun`, `module_layout 0x630748eb`). That mismatch — not any
"6.6.77 vs 6.6.98 skew" — caused every `Exec format error` and SoC hang. Build
against **`out-698ns`** (the running kernel, `0x81972209`).

### The cesta mode2 patch (real, but wrong target)

The first hypothesis was the `sde_cesta` mode2 GDSC power-collapse path. Because
from-source builds hang at init (config-gated struct drift vs the stock deps), the
fix was applied as a **4-byte binary patch of the known-good stock module** —
[display-driver/msm_drm-cesta-mode2.patch.md](display-driver/msm_drm-cesta-mode2.patch.md).
It loads cleanly but does **not** fix the black screen, because the failure is the
panel-on sequence, not mode2. Kept as a robustness improvement and a worked
example of ABI-safe binary patching.

### The blocker for a proper fix

Fixing the panel-on sequence needs a **from-source `msm_drm` that loads without
hanging**. Building against `out-698ns` gets `module_layout` right but hangs at
init from importer-side config-gated struct drift: the hand-made
`config/gki_sundispconf.h` doesn't match the config Samsung built the stock 6.6.77
deps with. Matching the exact production (bazel `sun_in_tree_modules`) display
config for a GKI-external build is the open problem.

---

## Recovery — fixing the pmOS rootfs from Android

When a bad module bricks pmOS boot and SSH is gone, recover via Android (ReSukiSU
root can reach the pmOS partition):

1. `boot-switch android` (or Download-mode + `heimdall flash --BOOT_A boot_a.img
   --VENDOR_BOOT_A vendor_boot_a.img --DTBO_A dtbo_a.img`). This boots Android with
   root and **does not touch pmOS on sda60**.
2. `adb` + `su`. pmOS rootfs is **`/dev/block/sda60`** (`pmOS_root`).
3. sda60 is a **4K-logical GPT image**; rootfs (ext4) is partition 2 at **byte
   offset 511705088**. A normal `losetup -o` presents 512-byte sectors and gets
   **EIO** on the 4K disk.
4. Use [`recovery/loopcfg.c`](recovery/loopcfg.c) — `LOOP_CONFIGURE` with
   `block_size=4096` **and `LO_FLAGS_DIRECT_IO`** (direct-IO is what makes reads
   succeed):
   ```
   losetup -f
   loopcfg /dev/block/loopN /dev/block/sda60 511705088 4096
   mount -t ext4 -o rw /dev/block/loopN /mnt/pmosroot
   ```
   Build: `clang --target=aarch64-linux-gnu -static -nostdlib -ffreestanding -O2 loopcfg.c -o loopcfg`.
5. Restore the module: `cp .../vendor/msm_drm.ko.prebuilt .../vendor/msm_drm.ko`,
   then **`depmod -a`** on the pmOS tree (a plain `cp` leaves `modules.dep` stale →
   the prebuilt fails to pull `drm_display_helper` → unresolved `drm_dp_*` → no
   display).
6. Flash the pmOS boot chain back from the images on the rootfs itself
   (`/var/lib/dualboot/pmos/{boot-ns-heap.img,vendor_boot-current.img,dtbo-noidlepc-nocbc.img}`).

> The rootfs was created by **dd'ing `samsung-pa2q.img` to the partition** — never
> extract the tar into a hand-made filesystem.

---

## Safety net for module testing (never Download-mode again)

`msm_drm` auto-loads at boot from **`/etc/modules`** *and* via **udev coldplug**
(modalias). To fully stop boot-time loading you need **both**:

1. `/etc/modprobe.d/zz-test-msmdrm.conf` → `blacklist msm_drm` (stops coldplug)
2. comment `msm_drm` out of `/etc/modules` (stops explicit load)

Then boot always reaches SSH with no display; test with an explicit
`modprobe msm_drm` (blacklist doesn't block explicit loads). If it hangs the SoC,
the watchdog resets and it comes back clean (blacklisted) — no Download mode. Put
the `timeout` on the **remote** side of any test command; an orphaned poll left a
CPU busy and cooked the phone to 71 °C once.

---

## Credits & caveats

- **ReSukiSU/SuSFS version ceiling:** cannot update past `03b60f26` without bumping
  the in-tree SuSFS; the working pin is `b2ac2fc8`.
- The `gh_wdt_tame` and `splashcon` drivers are **bring-up aids**, not shipping
  configuration. A device with no working watchdog cannot self-recover from a hang.
- Everything here is specific to pa2q / SM8750. The compiled-in framebuffer
  address, panel geometry, partition offsets, and SMCCC IDs are **not** portable.
- Not legal/financial/warranty advice — this modifies a phone at a level that can
  brick it. Keep a known-good boot image and Download-mode/Odin recovery available.
