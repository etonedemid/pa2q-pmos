#!/usr/bin/env python3
# Same fix as turnip-kgsl-sw-wsi.patch, for the prebuilt 26.0.99 KGSL Turnip
# (/usr/local/lib/libvulkan_freedreno_kgsl.so, BuildID 0b250cc2...) whose
# source is not kept. tu_wsi_init zeroes struct wsi_device_options at sp+16:
#   mov x0, #0 ; strh wzr, [sp, #16]   ->   mov w0, #1 ; strh w0, [sp, #16]
# so sw_device (first byte) becomes true. Usage: binpatch.py LIB
import struct
import sys

OFF = 0x1a3024  # file offset == vaddr (first LOAD segment at 0)
OLD = (0xd2800000, 0x790023ff)
NEW = (0x52800020, 0x790023e0)

b = bytearray(open(sys.argv[1], "rb").read())
cur = struct.unpack("<II", b[OFF:OFF + 8])
if cur == NEW:
    sys.exit("already patched")
assert cur == OLD, "unexpected bytes %s - different build?" % [hex(x) for x in cur]
b[OFF:OFF + 8] = struct.pack("<II", *NEW)
open(sys.argv[1], "wb").write(b)
print("patched")
