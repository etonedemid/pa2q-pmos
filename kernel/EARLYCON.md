# Galaxy S25 (SM8750) — earlycon bring-up

Serial console over the USB-C debug UART, as the first step toward booting a
mainline/postmarketOS userspace on this device.

## What changed

One line in `arch/arm64/configs/defconfig`:

```
-CONFIG_CMDLINE="console=ttynull stack_depot_disable=on ..."
+CONFIG_CMDLINE="console=ttynull earlycon=qcom_geni,0x00a9c000 keep_bootcon stack_depot_disable=on ..."
```

Nothing else was needed — this GKI config already ships everything required:

| Option | State | Why it matters |
|---|---|---|
| `CONFIG_SERIAL_EARLYCON=y` | already set | the `earlycon=` early_param |
| `CONFIG_SERIAL_QCOM_GENI=y` / `_CONSOLE=y` | already set | provides `OF_EARLYCON_DECLARE(qcom_geni, ...)` |
| `CONFIG_FIX_EARLYCON_MEM=y` | already set | earlycon maps via fixmap, before `ioremap` exists |
| `CONFIG_CMDLINE_EXTEND=y` | already set | our args are prepended to the bootloader's |

### Why each argument

- **`earlycon=qcom_geni,0x00a9c000`** — SM8750's debug UART is `uart7`
  (`qcom,geni-debug-uart`, 115200n8), per upstream `arch/arm64/boot/dts/qcom/sm8750.dtsi`.
  Same base as SM8550/SM8650; the QUPv3_1 SE7 address has been stable across generations.

  The explicit address matters: this tree is pure GKI with **no SM8750 DTS**, and the
  Samsung DTB almost certainly describes this UART with a downstream compatible
  (`qcom,msm-geni-console`) that the upstream driver won't bind to. `setup_earlycon()`
  matches the *name* `qcom_geni` against `__earlycon_table` and takes the address
  straight from the cmdline, so earlycon works with no matching DT node at all.

- **`keep_bootcon`** — **required, not optional.** `console=ttynull` registers a real
  console very early, and the kernel unregisters the boot console the moment one
  appears. Without `keep_bootcon` you'd lose earlycon within a few hundred lines of
  boot and see essentially nothing.

- Left `console=ttynull` alone so Android's `/dev/console` behaviour is unchanged.

### Why `CMDLINE_EXTEND` ordering is safe

`early_init_dt_scan_chosen()` (`drivers/of/fdt.c`) with `concat_cmdline` seeds the
buffer with `CONFIG_CMDLINE` and *appends* the bootloader's `bootargs`. Params are
parsed left to right and `setup_earlycon()` returns `-EALREADY` once a console is
registered, so our `earlycon=` wins even if Samsung's bootloader passes its own.

## Hardware side

The SoC UART is wired to the USB-C **SBU1/SBU2** pins. On Samsung devices it is only
muxed through when the MUIC/PDIC sees a **619 kΩ resistor between CC and GND** — the
classic "Samsung UART jig". Then:

- **115200 8N1**
- **1.8 V logic** — use a 1.8 V-capable USB-TTL adapter, *not* a 3.3 V one.

> Not verified on S25 hardware. The 619 kΩ / SBU / 1.8 V convention holds across
> recent Galaxy devices, but confirm before trusting it with your only phone.

## Two things that gate whether this works

1. **The bootloader must have brought the UART up.** `qcom_geni_serial_earlycon_setup()`
   does `geni_se_read_proto()` and bails with `-ENXIO` if the SE isn't already in UART
   protocol — and it configures **no clocks at all**, inheriting the bootloader's baud.
   In practice XBL/ABL initialises this SE when a UART jig is attached.

2. **If the SE is completely unclocked, the MMIO read can NoC-error → reset.** This is
   the one real bootloop risk. `qcom_geni_serial_poll_bit()` is bounded (20 ms timeout,
   returns false), so a *configured-but-idle* UART only slows boot; an *unclocked* one
   is the dangerous case. Test with the jig attached, and keep a known-good boot image
   plus download-mode/Odin recovery available.

`ioremap_guard` in the cmdline is **not** a problem: it only engages for pKVM *guests*
that get the MMIO-guard SMCCC services (`kvm_init_ioremap_services()`), and earlycon
uses `set_fixmap_io()` rather than `ioremap_prot()` regardless.

## Verifying

```bash
# after boot, with the console attached
adb shell cat /proc/cmdline          # should contain earlycon=qcom_geni,0x00a9c000
adb shell dmesg | head -40           # earlycon prints appear before console handover
```

If nothing comes out of the wire, `CONFIG_PSTORE_CONSOLE=y` is already enabled — check
`/sys/fs/pstore/console-ramoops*` after a reboot to see whether the kernel was logging
at all. That separates "kernel isn't booting" from "UART isn't wired up".

If earlycon works but you want a full console too, add `console=ttyMSM0,115200n8`
(the geni driver registers as `ttyMSM`) — it will only bind if the Samsung DTB happens
to expose a node the upstream driver matches.
