# pa2q display bring-up — findings

Investigation notes for the Galaxy S25+ (pa2q / SM8750) display under postmarketOS.
Panel: **PA2_S6E3HAF_AMB666FM03**, 1440×3120, command-mode DSI, 120 Hz.

## Current status

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
