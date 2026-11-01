# pa2q display bring-up — findings

Investigation notes for the Galaxy S25+ (pa2q / SM8750) display under postmarketOS.
Panel: **PA2_S6E3HAF_AMB666FM03**, 1440×3120, command-mode DSI, 120 Hz.

## Current status

**Fixed 2026-10-31** - see "Root cause" at the end: `debugcc_sun` was not
loaded, so `disp_cc` `sync_state()` never ran.

- **Greeter (SDDM) renders.** ✅
- **Login (greeter → session) goes black.** ❌
- **Power-button DPMS wake fails.** ❌ (same transition as login)

## The kernel objtree — the thing that wasted the most time

The running kernel is **`k698` / `out-698ns`**, release
`6.6.98-pd6ff1cd-abogkiS9380ZHUBCZF1-4k`, `module_layout` CRC **`0x81972209`**.

Vendor modules MUST be built **versioned against `out-698ns/Module.symvers`** so
`module_layout` = `0x81972209`. Building against
`msm-kernel/out_sun` yields `module_layout` **`0x630748eb`** — wrong — and the
symptoms are:

| build | result |
|---|---|
| versioned vs `out_sun` | `modprobe: Exec format error`, dmesg `disagrees about version of symbol module_layout` |
| unversioned vs `out_sun` (`KBUILD_MODPOST_WARN=1`) | no CRC check → loads → **SoC hang** (struct ABI wrong) |
| versioned vs `out-698ns` | `module_layout` OK, loads past ABI check |

The stock module ships on-device as `msm_drm.ko.prebuilt` (16 MB, vermagic
`6.6.77-…-BYI3`, `module_layout 0x81972209`). GKI tolerates the release-string
mismatch and gates only on `module_layout` + KMI CRCs, so this 6.6.77 module
loads fine on the 6.6.98 running kernel. **It is the known-good baseline.**

## The real root cause of the black screen

It is **not** the `sde_cesta` mode2 GDSC power-collapse path (that was the first
hypothesis; the patch below is real but targets the wrong failure).

At the greeter → session handover, kwin performs the **first real DRM atomic
modeset** — a genuine panel off→on. The kernel log:

```
sde_encoder_phys_cmd_wait_for_tx_complete  failed wait_for_idle: -110   (cmd-mode TX timeout)
ss_dbg_no_te : error: no TE                                             (LDI stops TE/vsync)
_sde_connector_report_panel_dead : Report Panel Dead
sde_kms_prepare_commit : initiating hw reset
dsi_panel_tx_cmd_set : failed to set cmds(267), rc=-22                  (-EINVAL on re-init)
ss_check_te : error: LDI doesn't generate TE     ,  display_on: 0
```

**Mechanism:** the greeter runs on the **bootloader continuous-splash handoff** —
the kernel adopts the already-lit panel and never runs its own panel-on
sequence (`MDPExitBoot: splash enabled`). The session is the first client to
force a real modeset, and the real **panel power-on / DSI init sequence fails
under pmOS**. DPMS wake is the same off→on, so both fail identically.

To fix this properly we need to iterate on `dsi_panel` enable / the panel power
& reset sequencing — which requires a from-source `msm_drm` that loads (see
blocker below).

### Secondary issue (chronic, probably not the trigger)

Every buffer import logs:

```
msm_gem_prime_import : get vmid list failure, ret:-22
```

`mem_buf_dma_buf_copy_vmperm()` (`msm_gem_prime.c:125`) fails for kwin's GBM
buffers because, under pmOS, they carry no `mem_buf` vmperm metadata. The caller
then `goto fail_put` (`msm_gem_prime.c:207`) and **fails the import entirely**.
This is present even at the working greeter, and the panel TX timeout precedes
the session's first vmid failure, so it is not what kills TE — but it is clearly
wrong for a non-Android userspace. Candidate fix: in
`msm_gem_prime_get_vmid_flags`, treat a `copy_vmperm` error as "plain
non-secure buffer" and `return 0` (default unsecure SMMU domain) instead of
propagating `-EINVAL`. See `msm_gem_prime.c` here.

## The blocker: from-source builds hang at init

A from-source `msm_drm` built against `out-698ns` gets `module_layout` right
(`0x81972209`) but **hangs the SoC at init**. MODVERSIONS catches *exporter* ABI
drift, not *importer*-side config-gated struct drift: the hand-made
`config/gki_sundispconf.h` sets display `CONFIG_*` that don't match what Samsung
built the stock 6.6.77 deps (`sync_fence`, `hw_fence`, `mmrm`, …) with, so a
shared struct's layout differs → wrong register/offsets → hang.

Samsung's display `CONFIG_*` are **not** in any kernel `.config` (`out_sun/.config`
lacks them too); they come from the module's own `gki_sundisp.conf` / `.h`, so
matching the exact production (bazel `sun_in_tree_modules`) config for a
GKI-external build is the hard part still to solve.

## The cesta mode2 binary patch (deployed, real but wrong target)

Since from-source builds hang, the `sde_cesta` mode2 fix was applied instead as a
**4-byte binary patch of the known-good `.prebuilt`** — see
[`msm_drm-cesta-mode2.patch.md`](msm_drm-cesta-mode2.patch.md). It loads cleanly
(byte-identical to stock except the patch) but does not fix the black screen,
because the black screen is the panel-on sequence, not mode2. Kept as a
robustness improvement and a template for further binary patches.

## 2026-10-31: DPMS off -> on, measured on the from-source module

Reproduce without a login: `kscreen-doctor --dpms off; sleep 4; kscreen-doctor --dpms on`
(as the session user). Panel off and power-off run cleanly; on power-on the
rails, reset GPIO and PHY come up, then **the very first DSI command DMA
(32 bytes) never completes**: `dsi_ctrl_dma_cmd_wait_for_done Timeout`,
`DSI_STATUS=0x00020003` (engine + DMA busy), lanes in stop state, all DSI
clocks enabled, no SMMU fault logged. Every following command does the same.
Before the off cycle the same buffer (IOVA `0xffd00000`) transfers in
~0.3 ms.

Ruled out:
- **Bandwidth.** After the first disable CESTA's SW client vote is gone and
  the `dsi0` HW client's SCC FSM is idle during panel-on, which looked like
  the cause. Re-placing the SW AOSS+BW vote on every
  `sde_cesta_resource_enable()` (verified active: 28.5 GB/s, AOSS 4) did
  **not** change anything. Reverted.
- `DSI_COMMAND_MODE_DMA_CTRL=0x10290000` - same value in the working state.

Register diff, working (after boot, bootloader-initialised link) vs stuck
(after Linux re-initialises it), via
`/sys/kernel/debug/dri/0/debug/dsi0_ctrl_{off,reg}`:

| reg | working | stuck |
|---|---|---|
| 0x040 COMMAND_MODE_MDP_CTRL | 06100009 | 00000009 |
| 0x060/0x064 MDP_STREAM1_CTRL/TOTAL | 0 / 0 | 02d10039 / 0c3000f0 |
| 0x0bc HS_TIMER_CTRL | 0004ea60 | 00049c3c |
| 0x0c4 CLKOUT_TIMING_CTRL | 00000000 | 00001819 |
| 0x0cc EOT_PACKET_CTRL | 00000001 | 00000011 |
| 0x10c ERR_INT_MASK0 | 13e0391f | 7fe039ff |
| 0x120 CLK_STATUS | 00002343 | 008037c3 |
| PHY 0x014 / 0x02c / 0x0f4 | 30 / 00 / 3d | 20 / 40 / 3c |

Further eliminations (same day), each tested with a DPMS off/on cycle:

- Forcing those register groups back to the bootloader values before every
  command DMA (runtime param `pa2q_fix`, incl. PHY 0x14/0x2c/0xf4): no change.
  PHY `CLK_CFG1` 0x30->0x20 is Linux clearing CLK_EN_SEL after the retime
  sync on purpose (`dsi_phy_hw_v7_2.c`), not a fault.
- Sending short commands from the DSI FIFO instead of memory (`pa2q_fifo`):
  still stalls (`STATUS=0x3`). So it is not AXI/SMMU/bandwidth - the engine
  cannot put any packet on the link.
- Keeping the DSI rails at AOSS CP level 1 instead of 0 on power-off
  (`pa2q_aoss`): no change. (With CESTA the PHY/ctrl supplies are voted through
  AOSS, which is why their regulator-framework counts are always 0.)
- MIPI clock: on pmOS `cached_clk_rate` is never set (Android sets it from the
  modem's RF info through the RIL bridge, `sdp_adaptive_mipi_v2`), so every
  wake runs the link at `clk_rate=0` -> 1362.25 MHz. Forcing Android's value
  (`echo 0 > /sys/class/lcd/panel/dynamic_freq` -> 1362000000) works and
  gets the right rate, but the stall is unchanged. Probably worth setting
  anyway.
- dtbo: the pmOS overlay differs from stock only by adding
  `qcom,mdss-disable-cesta-hw-sleep` and removing `qcom,sde-has-idle-pc`
  (plus Wi-Fi CBC). Dropping the hw-sleep flag: no change. The full stock
  display overlay (`pa2q-out/dtbo-stockdisp-nocbc.img`) now **boots fine**
  with the from-source module (the old "idle-pc hangs msm_drm" no longer
  applies) - but MDSS then power-collapses on idle and the first command
  after that collapse times out the same way: black screen, frozen cursor.

Android comparison (stock kernel/module, AOD off, `input keyevent 26`):
identical off/unprepare/prepare/enable sequence, panel rails, reset GPIO and
mafpc write; it just works (mafpc 21 ms, `tx ss on_cmd` 130 ms) and logs no
`mode2 entry failed`. On pmOS mode2 entry (MDSS GDSC collapse) always fails at
DPMS off, even though the dsi0 CESTA client is correctly downvoted
(`en 1->0`, AOSS 0) on a clean first off.

**Conclusion so far:** the first time MDSS is powered down and back up under
Linux - DPMS or idle-pc - the DSI link cannot transmit anything afterwards.
The software sequence matches Android, so look at what differs underneath:
the 6.6.98 kernel vs stock 6.6.77 (clock/GDSC/CRM providers - `disp_cc`,
`qcom-crm`, RSCC, AOP/AOSS), and why the GDSC never reports collapse.
Next steps: dump `scc_*`/`sde_rsc_rscc`/`sde_crm*` regs across an off cycle
on both OSes; try the stock Android kernel's vendor clock/CRM modules on pmOS.

## Root cause (2026-10-31) - disp_cc sync_state never ran

The decisive comparison was Android vs pmOS clock enable counts after a wake
(same `sde_dbg`/debugfs dumps on both, Android with idle-pc disabled via
`encoder*/idle_power_collapse`): every DSI/MDSS clock had one extra reference
on pmOS, already right after boot, and at screen-off pmOS left
byte0/pclk0/esc0/mdp enabled where Android had 0. Android's PHY, PLL and DSI
controller registers after a working wake matched pmOS's stuck state, which is
why every register experiment above failed.

`af00000.clock-controller/state_synced` was 0; its consumers were all bound
except `soc:qcom,cc-debug` (driver `debugcc_sun`, not loaded on pmOS). Loading
it makes disp_cc (and gpu_cc/cam_cc/eva_cc) reach `sync_state()`. Load it at
boot (`/etc/modules`): hot-loading it into a running session also syncs
gpu_cc under the live GPU and the compositor's page flips time out.

Side findings kept for reference: `cached_clk_rate` stays 0 on pmOS (Android
gets the MIPI clock from RIL), forcing it via `/sys/class/lcd/panel/dynamic_freq`
works; the stock display dtbo (idle-pc on) now boots with the from-source
module.
