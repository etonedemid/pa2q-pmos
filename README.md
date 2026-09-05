# pa2q-pmos — postmarketOS on the Galaxy S25+ (SM-S936B / SM8750 "sun")

Bring-up work-product and findings for running **postmarketOS** on the Samsung
Galaxy S25+ — codename **pa2q**, SoC **SM8750 / "sun"**, panel
**PA2_S6E3HAF_AMB666FM03** - **dual-booting alongside stock Android**.

This repo is **not** the kernel tree. It collects the source changes, build
recipes, on-device tools, recovery tooling, and the investigation notes that
together make the device boot pmOS. The kernel source itself lives in the
`android_kernel_samsung_sm8750` fork; the pmOS-specific additions are mirrored
here under [`kernel/`](kernel/) so the whole picture is in one place.

---

## Status at a glance

Dual-boot Android ⇄ pmOS
Wi-Fi - yes
Display - yes, but DPMS wake hangs kernel, i recommend autologin to your DE
Gpu - yes
Usb dock - yes, but no HDMI
Charging - yes, full support
Audio - no
Bluetooth - no


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
  from `k698` / `out-698ns`. `module_layout` CRC **`0x81972209`**
- `CONFIG_MODVERSIONS=y`; `CONFIG_MODULE_SIG_PROTECT=y` but `SIG_FORCE` off, so
  foreign-signed / foreign-vermagic Samsung prebuilts load (GKI gates on
  `module_layout` + KMI CRCs, not the release string).
- **Partitions** (4K-logical GPT): `boot_a`=sda26, `init_boot_a`=sda27 (Android's
  `/init`, untouched), `vendor_boot_a`=sda28, `dtbo_a`=sda36, `userdata`=sda59,
  **`pmOS_root`=sda60**.
- **USB networking (pmOS):** CDC-NCM gadget, device `172.16.42.1`, host
  `172.16.42.2/24`. SSH in as `root`.

## Kernel build

Toolchain is **mandatory**: AOSP **clang r510928** at `~/toolchains/clang-r510928`.

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


## Credits

- **ReSukiSU/SuSFS version ceiling:** cannot update past `03b60f26` without bumping
  the in-tree SuSFS; the working pin is `b2ac2fc8`.
- The `gh_wdt_tame` and `splashcon` drivers are **bring-up aids**, not shipping
  configuration. A device with no working watchdog cannot self-recover from a hang.
- Everything here is specific to pa2q / SM8750. The compiled-in framebuffer
  address, panel geometry, partition offsets, and SMCCC IDs are **not** portable.
- Not legal/financial/warranty advice - this modifies a phone at a level that can
  brick it. Keep a known-good boot image and Download-mode/Odin recovery available.
