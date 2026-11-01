#!/usr/bin/python3
# Boot-time escape hatch: if VOLUME-UP is held during early boot, switch the
# device back to Android. Runs from OpenRC sysinit, before udev and before any
# vendor module (msm_drm & co) is loaded, so a hang later in boot cannot keep
# it from running. Exit 10 = switch to Android, 0 = not held.
import fcntl, glob, os, sys, time

KEY_VOLUMEUP = 115
NBYTES = 96                                         # KEY_MAX/8 rounded up
EVIOCGKEY = (2 << 30) | (NBYTES << 16) | (ord("E") << 8) | 0x18           # key state


def has_bit(buf, bit):
    return bool(buf[bit // 8] & (1 << (bit % 8)))


def caps_have_volup(sysdir):
    """Key capabilities from sysfs, without opening the device: opening an
    evdev node runs the driver's open/close hooks, and sec_touchscreen's hooks power
    the touch IC up and down."""
    try:
        with open(sysdir + "/device/capabilities/key") as f:
            words = f.read().split()[::-1]          # least significant word first
    except OSError:
        return False
    i, bit = divmod(KEY_VOLUMEUP, 64)
    return i < len(words) and bool(int(words[i], 16) >> bit & 1)


def volup_devices():
    """Every input device that has VOLUME-UP (gpio-keys on pa2q), gpio-keys first.
    Found by capability, not by number: event numbering can change between boots."""
    found = []
    for sysdir in sorted(glob.glob("/sys/class/input/event*")):
        if not caps_have_volup(sysdir):
            continue
        try:
            with open(sysdir + "/device/name") as f:
                name = f.read().strip()
        except OSError:
            name = ""
        found.append((name != "gpio-keys", "/dev/input/" + os.path.basename(sysdir)))
    return [dev for _, dev in sorted(found)]


def held(fds):
    for fd in fds:
        buf = bytearray(NBYTES)
        try:
            fcntl.ioctl(fd, EVIOCGKEY, buf, True)
        except OSError:
            continue
        if has_bit(buf, KEY_VOLUMEUP):
            return True
    return False


def main():
    devs = volup_devices()
    if not devs:
        print("bootkey-recovery: no input device reports VOLUME-UP", file=sys.stderr)
        return 0
    fds = []
    for dev in devs:
        try:
            fds.append(os.open(dev, os.O_RDONLY | os.O_NONBLOCK))
        except OSError:
            pass
    # ~3 s window; 3 consecutive held samples (0.3 s) so a bounce can't trigger it
    hits = 0
    for _ in range(30):
        hits = hits + 1 if held(fds) else 0
        if hits >= 3:
            return 10
        time.sleep(0.1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
