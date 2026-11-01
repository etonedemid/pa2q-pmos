#!/usr/bin/python3
# Screenshot whatever the display is scanning out, straight from DRM (run as
# root; works while a compositor owns the device). Writes a binary PPM.
# usage: drmshot.py [out.ppm] [card]
import ctypes, fcntl, mmap, os, struct, sys

def iowr(nr, size):
    return (3 << 30) | (size << 16) | (ord("d") << 8) | nr

GETPLANERESOURCES, GETPLANE, GETFB2, MAP_DUMB = iowr(0xB5, 16), iowr(0xB6, 32), iowr(0xCE, 104), iowr(0xB3, 16)
SET_CLIENT_CAP = (1 << 30) | (16 << 16) | (ord("d") << 8) | 0x0D
XR24, AR24, XB24, AB24, XR30, AR30, XB30, AB30 = (int.from_bytes(s.encode(), "little") for s in
    ("XR24", "AR24", "XB24", "AB24", "XR30", "AR30", "XB30", "AB30"))


def ioctl(fd, req, buf):
    buf = bytearray(buf)
    fcntl.ioctl(fd, req, buf, True)
    return buf


def planes(fd):
    n = struct.unpack_from("<Q I", ioctl(fd, GETPLANERESOURCES, bytes(16)))[1]
    arr = (ctypes.c_uint32 * n)()
    ioctl(fd, GETPLANERESOURCES, struct.pack("<Q I 4x", ctypes.addressof(arr), n))
    return list(arr)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/drmshot.ppm"
    fd = os.open(sys.argv[2] if len(sys.argv) > 2 else "/dev/dri/card0", os.O_RDWR)
    ioctl(fd, SET_CLIENT_CAP, struct.pack("<QQ", 2, 1))  # universal planes
    shots = []
    for pid in planes(fd):
        p = ioctl(fd, GETPLANE, struct.pack("<6I Q", pid, 0, 0, 0, 0, 0, 0))
        fb = struct.unpack_from("<3I", p)[2]
        if not fb:
            continue
        f = ioctl(fd, GETFB2, struct.pack("<I", fb) + bytes(100))
        _, w, h, fmt, _ = struct.unpack_from("<5I", f)
        handle, pitch, offset = struct.unpack_from("<I", f, 20)[0], struct.unpack_from("<I", f, 36)[0], struct.unpack_from("<I", f, 52)[0]
        modifier = struct.unpack_from("<Q", f, 68)[0]
        print("plane %d fb %d %dx%d fmt %s pitch %d mod 0x%x handle %d" % (pid, fb, w, h, fmt.to_bytes(4, "little").decode(errors="replace"), pitch, modifier, handle))
        if handle:
            shots.append((w * h, w, h, fmt, handle, pitch, offset, modifier))
    if not shots:
        sys.exit("no readable framebuffer (need root)")
    _, w, h, fmt, handle, pitch, offset, modifier = max(shots)   # the biggest plane = the desktop
    if fmt not in (XR24, AR24, XB24, AB24, XR30, AR30, XB30, AB30) or modifier not in (0, 0xFFFFFFFFFFFFFF):
        sys.exit("unsupported format/modifier for a plain read")
    off = struct.unpack_from("<Q", ioctl(fd, MAP_DUMB, struct.pack("<II Q", handle, 0, 0)), 8)[0]
    m = mmap.mmap(fd, offset + pitch * h, mmap.MAP_SHARED, mmap.PROT_READ, offset=off)
    rgb = bytearray(w * h * 3)
    swap = fmt in (XR24, AR24)  # little-endian B,G,R,X in memory
    if fmt in (XR30, AR30, XB30, AB30):  # 2:10:10:10: keep the top 8 bits of each
        import array
        rs, bs = (22, 2) if fmt in (XR30, AR30) else (2, 22)  # *R30: R in bits 20-29; *B30: R in 0-9
        for y in range(h):
            px = array.array("I", m[offset + y * pitch: offset + y * pitch + w * 4])
            i = y * w * 3
            for v in px:
                rgb[i], rgb[i + 1], rgb[i + 2] = (v >> rs) & 255, (v >> 12) & 255, (v >> bs) & 255
                i += 3
        h_done = h
    else:
        h_done = 0
    for y in range(h_done, h):
        row = m[offset + y * pitch: offset + y * pitch + w * 4]
        dst = memoryview(rgb)[y * w * 3:(y + 1) * w * 3]
        if swap:
            dst[0::3], dst[1::3], dst[2::3] = row[2::4], row[1::4], row[0::4]
        else:
            dst[0::3], dst[1::3], dst[2::3] = row[0::4], row[1::4], row[2::4]
    with open(out, "wb") as o:
        o.write(b"P6\n%d %d\n255\n" % (w, h))
        o.write(rgb)
    print("wrote", out)


if __name__ == "__main__":
    main()
