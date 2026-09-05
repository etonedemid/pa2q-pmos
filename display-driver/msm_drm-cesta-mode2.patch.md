# msm_drm.ko — cesta mode2 non-fatal binary patch

A 4-byte patch of the **known-good stock `msm_drm.ko.prebuilt`** that makes the
`sde_cesta` mode2 (GDSC power-collapse) timeout non-fatal, without rebuilding
from source (from-source builds hang at init — see [FINDINGS.md](FINDINGS.md)).

## Why binary, not source

The stock module loads and works to the greeter. A from-source rebuild against
the correct objtree (`out-698ns`) still hangs at init from config-gated struct
drift. Patching the stock binary keeps 100 % of its ABI — only 4 bytes change,
inside one function body — so it loads exactly like the stock module.

## The bug (source view)

In `sde_cesta_resource_disable()` (called on every display-off), the inlined
`_sde_cesta_check_mode2_entry_status()` polls the RSCC GDSC power-collapse bit
`BIT(12)` for ~500 µs. On the S6E3HAF panel that bit is not always set within the
window during a full display-off, so it returns `-EBUSY`. Stock code treats that
as fatal (`return ret`), aborting the resource-disable and wedging the pipeline
so the next enable is a permanent black screen.

The intended fix: log the timeout, keep the NOC-safety `usleep`, and return 0.

## The patch

Located in `sde_cesta_resource_disable` (symbol `T`, the inlined check has no
own symbol). `.text` file offset `0x3c000`; the instruction lives at `.text +
0x1440dc` → **file offset `0x1800dc`**.

```
0x1440dc:  mov w25, wzr    (2a1f03f9)   -> mov w25, #1   (52800039)
0x1440e0:  mov w20, #-0x10  (=-EBUSY, the fatal return value)
0x1440e4:  b   0x143ec0
...
0x143fe0:  tbz w25, #0, 0x144034     (fail path, skips usleep, returns -EBUSY)
0x143ff4:  mov w20, wzr              (success path: return 0, after usleep)
```

`w25` is the "mode2 success" flag. Forcing it to `1` routes the timeout down the
success tail: the error is still logged (at `0x144080`), the NOC-safety
`usleep_range(500,510)` still runs, and `0x143ff4` sets the return to 0. This
mirrors the source fix exactly with a single instruction change.

### Apply

```python
off = 0x3c000 + 0x1440dc            # = 0x1800dc
old = bytes.fromhex("f9031f2a")     # mov w25, wzr  (little-endian)
new = bytes.fromhex("39008052")     # mov w25, #1
data = bytearray(open("msm_drm.ko.prebuilt","rb").read())
assert bytes(data[off:off+4]) == old
data[off:off+4] = new
open("msm_drm-cesta-fix.ko","wb").write(data)
```

Verify: `llvm-objdump -d --start-address=0x1440d8 --stop-address=0x1440e8 \
--section=.text msm_drm-cesta-fix.ko` shows `1440dc: mov w25, #0x1`, and
`modprobe --dump-modversions` still reports `module_layout 0x81972209`.

## Result

Loads cleanly (no hang), whole display stack comes up, greeter renders. Does
**not** fix greeter→session / DPMS black — that is the panel-on sequence, a
different code path. Kept as a real robustness improvement and a worked example
of ABI-safe binary patching for this stack.
