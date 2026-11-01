#!/usr/bin/env python3
# Writes Steam's shortcuts.vdf (binary VDF) with the pa2q non-Steam shortcuts.
# Run while Steam is stopped: pa2q-steam-shortcuts.py USERDATA/<id>/config/shortcuts.vdf
import struct
import sys
import zlib

SHORTCUTS = [("Reboot to Android", "/usr/local/bin/reboot-to-android")]


def entry(i, name, exe):
    appid = zlib.crc32((exe + name).encode()) | 0x80000000
    s = lambda k, v: b"\x01" + k.encode() + b"\0" + v.encode() + b"\0"
    n = lambda k, v: b"\x02" + k.encode() + b"\0" + struct.pack("<I", v)
    return (b"\x00" + str(i).encode() + b"\0"
            + n("appid", appid) + s("AppName", name) + s("Exe", '"%s"' % exe)
            + s("StartDir", '"/"') + s("icon", "") + s("ShortcutPath", "")
            + s("LaunchOptions", "") + n("IsHidden", 0) + n("AllowDesktopConfig", 1)
            + n("AllowOverlay", 1) + n("OpenVR", 0) + n("Devkit", 0) + s("DevkitGameID", "")
            + n("DevkitOverrideAppID", 0) + n("LastPlayTime", 0) + s("FlatpakAppID", "")
            + b"\x00tags\0\x08" + b"\x08")


data = b"\x00shortcuts\0" + b"".join(entry(i, *e) for i, e in enumerate(SHORTCUTS)) + b"\x08\x08"
open(sys.argv[1], "wb").write(data)
print("wrote %d shortcut(s) to %s" % (len(SHORTCUTS), sys.argv[1]))
