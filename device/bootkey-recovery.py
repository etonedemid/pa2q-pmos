#!/usr/bin/python3
# Boot-time escape hatch: if VOLUME-UP is held during early boot,
# switch the device back to Android. Lets you recover when the pmOS
# GUI is broken and SSH may be unavailable.
import fcntl, os, sys, time

DEV = "/dev/input/event0"          # gpio-keys
KEY_VOLUMEUP = 115                 # verified via capabilities bitmask
NBYTES = 96                        # KEY_MAX/8 rounded up

def _ioc(d, t, nr, sz):
    return (d << 30) | (sz << 16) | (t << 8) | nr

EVIOCGKEY = _ioc(2, ord("E"), 0x18, NBYTES)  # _IOC_READ

def held():
    try:
        fd = os.open(DEV, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return False
    try:
        buf = bytearray(NBYTES)
        fcntl.ioctl(fd, EVIOCGKEY, buf, True)
        return bool(buf[KEY_VOLUMEUP // 8] & (1 << (KEY_VOLUMEUP % 8)))
    except OSError:
        return False
    finally:
        os.close(fd)

# Sample a short window; require it held on two consecutive reads so a
# transient bounce cannot trigger a reboot-to-Android by accident.
hits = 0
for _ in range(6):
    if held():
        hits += 1
        if hits >= 2:
            sys.exit(10)   # signal: switch to android
    else:
        hits = 0
    time.sleep(0.15)
sys.exit(0)
