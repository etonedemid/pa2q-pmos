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
| Audio — speaker (AudioReach/AGM, TAS25xx protection) | ✅ working, card up ~40 s into boot |
| Audio - desktop (PipeWire "Speaker" sink -> vendor agmplay bridge) | working, verified by ear |
| Bluetooth | NOT working: `btattach` with the chip off hangs the SoC (see Bluetooth notes) |
| SYSVIPC + namespaces (Android side, containers/chroot) | ✅ working |
| Display — Plasma (KWin, Wayland) on the panel | ✅ working: autologin, adopts the bootloader cont-splash |
| GPU — KWin composites on the Adreno 830 | ✅ OpenGL ES 3.2 via zink → turnip (KGSL) |
| Display - DPMS off/on (screen off, wake) | working since 2026-10-31: needs `debugcc_sun` in /etc/modules (see below) |

Still missing: Bluetooth, sensors (auto-rotate), cellular, camera. Plasma is
usable day to day: display, GPU, audio, Wi-Fi, touch, screen off/on.

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
  bootkey-recovery.py/.initd vol-up-at-boot / boot-loop → switch to Android (sysinit)
  boot-ok.initd             marks a pmOS boot as finished (resets the loop counter)
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
- **Switch to Android** desktop/menu icon:
  [`pa2q-switch-android.desktop`](device/pa2q-switch-android.desktop) runs
  `pkexec /usr/local/bin/boot-switch android`. The polkit action
  [`org.pa2q.boot-switch.policy`](device/org.pa2q.boot-switch.policy)
  (`/usr/share/polkit-1/actions/`) binds that exact path, and
  [`50-pa2q-boot-switch.rules`](device/50-pa2q-boot-switch.rules)
  (`/etc/polkit-1/rules.d/`) allows it without a password for active local
  `wheel` users.
- **Reboot to Android** inside Steam: a non-Steam library entry
  ([`pa2q-steam-shortcuts.py`](device/pa2q-steam-shortcuts.py) writes
  `userdata/<id>/config/shortcuts.vdf` while Steam is stopped) runs
  [`reboot-to-android`](device/reboot-to-android) in the Steam container. The
  container cannot reach the host's polkit (`distrobox-host-exec` needs a
  Flatpak D-Bus helper pmOS lacks), so it leaves `~/.cache/pa2q-reboot-android`
  and `pa2q-rotate-gesture` (host, both sessions) runs `pkexec boot-switch
  android`. Steam's right-side menu takes no custom entries without Decky.
  Helpers restarted over SSH must be put back into the seat session's cgroup
  (`echo PID > /sys/fs/cgroup/c1/cgroup.procs`) or polkit refuses them.
- **Escape hatch:** hold **Volume-Up** from the Samsung logo until it reboots →
  [`device/bootkey-recovery`](device/) switches back to Android. It runs in
  OpenRC **sysinit, before udev and before `modules`**, so a vendor module that
  hangs later in boot (msm_drm) can't block it, and `boot-switch` finds the
  partitions through sysfs because udev's links don't exist yet.
- **Boot-loop fallback:** the same service counts pmOS boots that never finish
  (`/var/lib/dualboot/bootfails`; `boot-ok` resets it 60 s into the default
  runlevel or on clean shutdown). After **1** unfinished boot the next boot
  switches to Android on its own, and a boot not confirmed by 240 s uptime stops
  petting the watchdog, so a hung phone resets itself and lands in Android.
- **Boot trace:** until `boot-ok`, the service rewrites
  `/var/log/boot-trace.log` every 2 s (dmesg + which OpenRC services are
  starting); the previous boot's is `boot-trace.log.prev`. `/proc/last_kmsg`
  only reaches ~0.7 s on this kernel, so this is where a hard hang shows up.
- **Hang watcher (host):** `build/pmos-watch.sh --boot` right before switching
  to pmOS; exits with a desktop alert on HUNG / RESET / DOWNLOAD.

---

## Kernel build

Toolchain is **mandatory**: AOSP **clang r510928** at `~/Desktop/Projects/phone-pmos/toolchains/clang-r510928`.
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

### Audio — load order matters (the 2026-10-03/04 "boot loops")

`pmos-audio` → [`device/vendor-up.sh`](device/vendor-up.sh) `audio` brings up the
ADSP, the LPASS macros and `machine_dlkm`, then
[`device/pmos-audio-card.sh`](device/pmos-audio-card.sh) burns through
`qcom,max_defer_count` so the card registers with the missing codecs dummied.

**`wcd9xxx_dlkm` must be loaded, and `soc:vote_lpass_{core,audio}_hw` bound,
before any LPASS macro.** It carries `audio-ext-clk-up` (`qcom,audio-ref-clk`),
the provider of lpass-cdc's `lpass_core_hw_vote`/`lpass_audio_hw_vote` clocks.
`lpass_cdc_probe()` takes them once and treats *any* error, -EPROBE_DEFER
included, as "no vote". With modules.alias disabled, nothing loaded
`wcd9xxx_dlkm` until `machine_dlkm` pulled it in, so whenever fw_devlink had
stopped holding lpass-cdc back (its deferred-probe timeout fires ~25 s into
boot) lpass-cdc probed unvoted. The first VA-macro register access during card
registration then hit unpowered LPASS and **warm-reset the SoC** — every boot,
~41 s in, with the last log line `lpass_cdc_runtime_resume ... hw_vote 0,
audio_vote 0, core_clk_vote 0`. The same bring-up run by hand minutes later
usually survived, which is why it looked random. `vendor-up.sh` now loads it
first and refuses to register the card if the votes aren't bound.

`agm_server` waits for the card inside its supervised process
([`device/pa2q-agm-server`](device/pa2q-agm-server)), not in `start_pre`, so a
missing card no longer holds the default runlevel (and sshd) for 120 s.

### Audio - desktop sound (PipeWire) goes through the vendor agmplay

Verified by ear 2026-10-31. **The native AudioReach stack is silent**: the
open-source `agm_server` + libagm/gsl/acdb runs the whole graph (amp reaches
`TAS_POWER_ACTIVE`, data flows, no errors) but nothing comes out, with the same
ACDB, card-defs and KVs that work for the vendor `agmplay` in `/opt/adroot`.
Root cause unknown; `agm_server` and `pa2q-spkprot` are out of the default
runlevel so the two stacks don't fight over the DSP.

- [`device/50-pa2q-speaker.conf`](device/50-pa2q-speaker.conf)
  (`/etc/pipewire/pipewire.conf.d/`): the "Speaker" sink is a `pipe-tunnel`
  writing S16LE/48k/stereo into `/run/pa2q-speaker.fifo`. It never suspends:
  agmplay starved of data for a while stays silent afterwards.
- [`device/pa2q-speaker-bridge`](device/pa2q-speaker-bridge) (+ `.initd`, before
  sddm): prepends an endless WAV header and feeds the stream to the vendor
  `agmplay` (LL graph, MBDRC, ikv 1).
- **The speaker backend must run at 24 bit.** The vendor `backend_conf.xml`
  says 16; the TAS25xx tuning blob only configures the amps' TDM receiver for
  24 bit, so at 16 they play nothing - unless a 24-bit run earlier in the boot
  already set them up, which made this look intermittent. The bridge
  bind-mounts a copy with `bits="24" format="PCM_FORMAT_S24_LE"` (the explicit
  format is required, else the open fails with -EIO).
- No TI speaker-protection params / VI feedback on this path: keep volume
  moderate.
- Latency: the relay shrinks both FIFOs to 8 KiB (`F_SETPIPE_SZ`); with the
  default 64 KiB pipes the never-suspending sink kept them full and audio lagged
  by up to ~0.7 s.

### Bluetooth - not working yet; don't power the chip off before `btattach`

BT is a WCN7850-class "kiwi" on `ttyHS5` (`a9c000.qcom,qup_hsuart`), powered
by `btpower` (`soc:bt_kiwi`; loading it auto-powers the chip via rfkill).
Firmware `hmtbtfw20.tlv`/`hmtnv20.bin` is in `/lib/firmware/qca`.
**Attaching `hci_uart` with the chip powered off hangs the SoC**: the dead
chip holds RX low, `msm_geni_serial` loops in an IRQ storm on CPU0
(`geni_se_dump_dbg_regs ... geni_ios:0x0`), and the watchdog keeps getting
petted from the other CPUs, so it needs a manual Vol-Down+Power reset. The old
`pmos-bt-up.sh` does exactly that (power off -> `btattach`); don't run it.

### SYSVIPC + namespaces (Android side)

For containers / chroot on the Android side: `SYSVIPC` enabled ABI-safely on
ReSukiSU + SuSFS, plus `PID_NS`, `DEVTMPFS`, `USER_NS`. Defconfig deltas in
[`kernel/defconfig-sysvipc.patch`](kernel/defconfig-sysvipc.patch) and
[`kernel/defconfig-namespaces.patch`](kernel/defconfig-namespaces.patch).

---

## Display + GPU — how Plasma runs today

- **`msm_drm` must load early** (`/etc/modules`, ~14 s): it adopts the
  bootloader's continuous splash (`cont_splash enabled in 1 of 1 display(s)`)
  and claims the panel rails. Loaded later, the regulator late-cleanup (~31 s)
  has already cut `panel_vci`/`panel_vdd3`, the adopted panel is dead, ESD
  recovery power-cycles it, and the broken panel-on sequence takes over. The
  module is the 6.6.98 from-source build from the BYI3 display source
  ([`build/build-msmdrm-byi3.sh`](build/build-msmdrm-byi3.sh)).
- [`device/sde-no-panic.initd`](device/sde-no-panic.initd) clears SDE's
  `panic_on_err` **before** sddm (it used to be a `local.d` script that ran
  after it).
- **One compositor, never a modeset:** SDDM autologins straight into Plasma
  (no greeter → session handover), and powerdevil's screen-off and
  auto-suspend are disabled (`TurnOffDisplayWhenIdle=false`,
  `AutoSuspendAction=0`). Don't change mode/rotation/scale at runtime.
- **GPU:** the display device has no GPU (the downstream SDE driver registers as
  DRM `msm` 1.4) and the Adreno is behind KGSL, which isn't DRM. Mesa's
  `kmsro` bridges them: scanout buffers are dumb buffers on `msm_drm` (so
  `msm_drm` never has to import a GPU buffer — the `vmid -22` issue below),
  rendering is **zink on turnip's KGSL backend**. The packaged turnip is built
  without KGSL, so a KGSL build (Mesa 26.1-devel +
  [`device/turnip-no-ubwc-modifier-on-kgsl.patch`](device/turnip-no-ubwc-modifier-on-kgsl.patch))
  is installed as its own ICD
  ([`device/freedreno_kgsl_icd.json`](device/freedreno_kgsl_icd.json)) and
  selected, with `MESA_LOADER_DRIVER_OVERRIDE=kmsro`, by
  [`device/pa2q-gpu.sh`](device/pa2q-gpu.sh) in
  `~/.config/plasma-workspace/env/`. KWin reports `zink Vulkan 1.4(Turnip
  Adreno (TM) 830)`, OpenGL ES 3.2.
- [`device/drmshot.py`](device/drmshot.py) screenshots whatever is being
  scanned out, straight from DRM (root; XR24/AR30/AB30 linear).

## Display - DPMS / wake: fixed by loading `debugcc_sun` (2026-10-31)

**Root cause of the black screen after any real panel off->on:** pmOS did not
load `debugcc_sun`, the driver for `soc:qcom,cc-debug`. That device is a
consumer of the display clock controller (`af00000`), and with
`fw_devlink.strict=1` a single unbound consumer blocks the controller's
`sync_state()` forever (`/sys/devices/platform/soc/af00000.clock-controller/state_synced`
stayed 0). Without `sync_state()` the clock driver never drops the votes it
took to keep the bootloader's splash clocks alive, so every DSI clock
(byte0/pclk0/esc0/mdp...) had one extra reference. At DPMS off they were never
really turned off (Android: 0, pmOS: 1, parked on XO), the PLL was then
reprogrammed underneath running RCGs, and the DSI could not put a single
packet on the link again: `dsi_ctrl_dma_cmd_wait_for_done Timeout`, panel
dead. The MDSS GDSC never collapsed for the same reason (`mode2 entry failed`).

Fix: `debugcc_sun` in `/etc/modules` (loaded at boot, like Android does). With
it, `gpu_cc`, `cam_cc` and `eva_cc` also finally reach `sync_state()`. No
driver change needed: the original `msm_drm.ko` survives repeated DPMS
cycles; the panel-on matches Android's timings (mafpc 20 ms, on-cmds 130 ms).
Debugging history: [display-driver/FINDINGS.md](display-driver/FINDINGS.md).

Check for the same trap elsewhere: any `.../state_synced` that is 0 on a
clock controller means some consumer never probed.

## GPU - A8xx community Turnip (built, not the default)

[`device/build-turnip-a8xx.sh`](device/build-turnip-a8xx.sh) builds the
Adreno 8xx Turnip the Android emulator drivers ship (Banners-Turnip A8xx
recipe: whitebelyash turnip/gen8 stack + WinNative A8xx fixes + Linux KGSL
patches, on Mesa main), natively for musl, plus our
[`turnip-no-ubwc-modifier-on-kgsl.patch`](device/turnip-no-ubwc-modifier-on-kgsl.patch)
and [`turnip-kgsl-khr-display-warn.patch`](device/turnip-kgsl-khr-display-warn.patch)
(upstream refuses the whole KGSL device if an app merely enables
VK_KHR_display; vulkaninfo does). Result: Mesa 27.0.0-devel, Adreno 830v1,
Vulkan 1.4.366. It is installed as `/etc/vulkan/icd.d/freedreno_a8xx_icd.json`
but the desktop was noticeably **slower** with it (2026-10-31), so
`pa2q-gpu.sh` keeps the Mesa 26.1 KGSL build. Not caused by GMEM being
disabled (`disable_gmem = False` for the 830).

`pa2q-gpu.sh` also sets `TU_DEBUG=nocb`: with concurrent binning on, kwin
drops whole triangles while any second GPU client is busy (3-finger overview
showed half-drawn window quads, apps got black pixels). Every app in the
session inherits it.

It also sets `QSG_NO_DEPTH_BUFFER=1`: Qt Quick embedded in widgets
(QQuickWidget - every System Settings page, `kcmshell6`) rendered blank on
zink/KGSL. Its depth-tested opaque pass into the offscreen target rejects
everything; plain Qt Quick windows (Discover, plasmashell) were unaffected.
Same with Mesa 26.2.2, so not caused by the upgrade.

Every Vulkan *window* (vkcube, Vulkan games, Wayland or X11) crashed with
SIGBUS in `vkCreateSwapchainKHR` on all KGSL builds: Turnip says its WSI is a
DRM device, but a KGSL-only build has no libdrm, so Mesa's WSI code has the
DRM branch compiled out and misreads the image params (jumps to address 0x1).
[`turnip-kgsl-sw-wsi.patch`](device/turnip-kgsl-sw-wsi.patch) makes KGSL
present through the shm path. It is applied to the 26.1.6 build
(`freedreno_kgsl_drm_icd.json`) and the Steam container's
`/opt/turnip-kgsl`. The session default stays the older, faster 26.0.99
build (`freedreno_kgsl_icd.json`; 26.1.6 made kwin noticeably slower), fixed
in place with
[`turnip-kgsl-sw-wsi-binpatch.py`](device/turnip-kgsl-sw-wsi-binpatch.py)
(original at `/root/libvulkan_freedreno_kgsl.so.orig`). That build has no
X11 WSI, so Vulkan on Xwayland reports "platform not available" instead of
crashing.

Steam ARM's gamepad UI straight on KDE's Xwayland gives an empty,
transparent fullscreen window (the client fails to name the webhelper's
window pixmap: Composite BadMatch, "failed to create glx pixmap"). The
desktop "Steam ARM" icon therefore runs
[`steam-arm-gamescope`](device/steam-arm-gamescope) (`/usr/local/bin`),
which nests it in a fullscreen gamescope using the DRM-reporting KGSL ICD.

**Gaming mode (Steam without Plasma).** SDDM autologins into
[`pa2q.desktop`](device/pa2q.desktop) ->
[`pa2q-session`](device/pa2q-session), which starts Plasma or, when
`~/.config/pa2q-session` says `gamescope`,
[`pa2q-gamescope-session`](device/pa2q-gamescope-session): gamescope's DRM
backend straight on the panel (`--force-composition-rotation`: SDE's inline
rotator rejects the 1440-line panel), Steam with `-usepipewireaudio` (else
its "default" audio manager shows the volume popup and changes nothing).
Enter: "Gaming Mode" icon ([`pa2q-session-select`](device/pa2q-session-select)
gamescope). Leave: Steam > Power > Switch to Desktop (the container's
[`steamos-session-select`](device/steamos-session-select)). A gaming session
that dies within 30 s falls back to Plasma. At boot and after a relogin,
[`pa2q-greeter`](device/pa2q-greeter) shows two buttons, SteamOS / Plasma
(last choice preselected), drawn straight into a KMS dumb buffer with Pillow
(no compositor); gamepad D-pad/stick/A, touch, volume keys and power work.
Deliberate switches skip it once (`~/.config/pa2q-session.switch`). In
Plasma, [`pa2q-gamepad-desktop`](device/pa2q-gamepad-desktop) (autostart)
makes the pad a mouse/keyboard (left stick pointer, right stick scroll,
A/R2 click, X/L2 right click, B Esc, Y Enter, D-pad arrows, L1/R1
Shift+Tab/Tab, Start launcher, Select overview); it pauses while gamescope
runs. Key daemon in gaming mode: [`pa2q-keys`](device/pa2q-keys) (volume
+-5% via wpctl, short power press suspends). Log:
`~/.local/state/pa2q-gamescope.log` (+ `.prev`). Status: Steam displayed and
was usable, then the phone hung and rebooted once (cause not found yet).

Signed in, but stuck on "Loading user data" (client login state 4,
"loading library", progress -1): the Debian `steam` container lacked
`libnm0`, so `dlmopen steamclient.so` failed (`libnm.so.0: cannot open
shared object file`). Installed in the container, as DroidDeck's runtime
does, along with `libusb-1.0-0 libpci3 libpcsclite1 libsamplerate0
libvdpau1 dbus-x11 xdg-utils x11-utils util-linux-extra python3-gi
pulseaudio-utils`. The library then loads in ~60 s on a cold start.

Restarting the Plasma session cleanly: kill `kwin_wayland_wrapper` and
`startplasma-wayland` of the old session first, then `sddm` (its supervisor
respawns it and autologin starts a new session). Killing only sddm leaves the
old wrapper respawning a second kwin.

## Sensors - accelerometer (in progress, not working yet)

The accelerometer (STM LSM6DSV), light, proximity etc. live in the ADSP's
Snapdragon Sensor Core (QMI service 400, node 5). `libssc`/`ssccli` and
`iio-sensor-proxy` (built with libssc) reach it, but its `registry` sensor
stays unavailable: the sensors PD needs a CPU-side FastRPC file server.
Tried:
- `hexagonrpcd` 0.4.0 (`-f /dev/fastrpc-adsp-secure -d adsp -s -R <root>`,
  root layout `sensors/config/`, `sensors/registry/`, `sensors/sns_reg.conf`,
  `dsp/adsp/`): serves the files, but the SM8750 firmware also calls a
  `sns_registry` interface and wants to write its registry; 0.4.0 does
  neither.
- Qualcomm `quic/fastrpc` `adsprpcd sensorspd adsp`: listener calls fail with
  EINVAL on this 6.6 upstream `qcom,fastrpc` driver.
- Android `sscrpcd` in the `/opt/adroot` chroot: expects the downstream
  adsprpc ABI (`Error Creating map -77`).
Next: newer hexagonrpc (0.6, Rust) which SM8550-era ports use with a
writable registry. **Never read every file in `/sys/devices/soc0/`** - Samsung's
`crash` attribute there panics the phone on read.

## Crash recovery - kwin, plasmashell, session

kwin still crashes now and then, seemingly at random but often while media
plays (no message before it dies). Recovery is automatic at three levels:
- **kwin**: `kwin_wayland_wrapper` restarts it (stock behaviour).
- **plasmashell**: exits when kwin dies and nothing relaunched it (no systemd
  user units) - black desktop with a cursor.
  [`device/pa2q-plasmashell-watchdog`](device/pa2q-plasmashell-watchdog)
  (Plasma autostart, [`.desktop`](device/pa2q-plasmashell-watchdog.desktop))
  relaunches it within ~3 s.
- **whole session**: `/etc/sddm.conf.d/10-autologin.conf` has `Relogin=true`,
  so sddm autologins again instead of stopping at the greeter.

To catch the kwin crash: `echo /var/tmp/cores/core.%e.%p.%t >
/proc/sys/kernel/core_pattern` and `prlimit --core=unlimited` on
`kwin_wayland_wrapper` (its respawned kwin inherits it); `gdb` is installed.

## Steam / gaming - removed (2026-11-01)

Steam ARM (Debian distrobox), the gamescope gaming session, the two-button
greeter, the gaming-mode key daemon and their helpers were removed from the
phone (Steam data, podman storage, `gamescope distrobox podman`), freeing
~15 GB; for gaming, DroidDeck on Android is the better-tuned option on this
phone. The files are kept in [`device/removed-gaming/`](device/removed-gaming/)
and the notes below describe how they worked. SDDM autologins straight into
Plasma again (`Session=plasma.desktop`).

Plasma power button: `powerdevilrc` `PowerButtonAction=128` (toggle screen
on/off) and `LockBeforeTurnOffDisplay=false` in every profile, plus
`kscreenlockerrc` `Autolock=false`, `LockOnResume=false`: it wakes straight
to the desktop, no lock screen.

## Touch gestures - rotation

Rotation (a real modeset) works since the DPMS fix. Until the accelerometer
does, [`device/pa2q-rotate-gesture`](device/pa2q-rotate-gesture) (Plasma
autostart: [`pa2q-rotate-gesture.desktop`](device/pa2q-rotate-gesture.desktop)
in `~/.config/autostart`, script in `/usr/local/bin`) watches `sec_touchscreen`
and flips landscape <-> reverse landscape on a four-finger double tap (from
portrait it goes to landscape). Back to portrait: `kscreen-doctor
output.DSI-1.rotation.normal` or Display Settings.

While gamescope runs, the same daemon maps a **three-finger tap** to the Steam
button (main menu) and a **three-finger double tap** to the quick access menu,
by pressing the hotkeys Steam registers in gamescope (Shift+Tab,
Ctrl+Shift+Tab) on a uinput keyboard (`/dev/uinput` access:
[`60-pa2q-gamepad.rules`](device/60-pa2q-gamepad.rules)). Tap timing check:
`python3 device/pa2q-rotate-gesture-test.py`.

USB gamepads: the phone switches the USB-C port to host mode by itself (SSH
over USB networking is gone while one is plugged in; use Wi-Fi). The kernel
binds them with `hid-generic`; `60-pa2q-gamepad.rules` gives the seat user
the `hidraw` nodes (Steam reads controllers there), which the rootless Steam
container can only use through that per-user ACL.

Installing a Windows game from Steam ARM pulls in Valve's ARM64 Proton (app
4427310) mid-install, and the client segfaulted doing that. DroidDeck
installs 4427310 on its own before any game; do the same. Forwarding
`steam://install/4427310` to a running client did nothing; passing it as a
startup argument works: `steam-arm-gamescope steam://install/4427310`
(about 500 MB download, 2 GB installed). With it in place, game installs
work (verified 2026-11-01).

## Display - earlier analysis (superseded)

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
