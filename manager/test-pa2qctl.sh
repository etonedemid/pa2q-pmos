#!/bin/sh
# Runs assets/pa2qctl.sh on the host against files standing in for partitions.
#   sh manager/test-pa2qctl.sh
set -u
CTL=$(dirname "$(readlink -f "$0")")/assets/pa2qctl.sh
T=$(mktemp -d)
trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
fails=0

check() {	# description, then a command that must succeed
	d=$1; shift
	if "$@" >/dev/null 2>&1; then echo "ok   $d"; else echo "FAIL $d"; fails=$((fails + 1)); fi
}

# An image: 16 byte header + a fill byte, padded to a partition size if asked
mkimg() {	# file magic fill size
	{ printf "$2"; head -c 4096 /dev/zero | tr '\0' "$3"; } > "$1"
	[ -n "${4:-}" ] && truncate -s "$4" "$1"
}
BOOT='ANDROID!' VB='VNDRBOOT' DT='\327\267\253\036'

setup() {
	chmod -R u+w "$T" 2>/dev/null; rm -rf "${T:?}"/*
	mkdir -p "$T/blk" "$T/data" "$T/bin" "$T/root/var/lib/dualboot/pmos"
	mkimg "$T/blk/boot_a" "$BOOT" a 1048576
	mkimg "$T/blk/vendor_boot_a" "$VB" b 1048576
	mkimg "$T/blk/dtbo_a" "$DT" c 1048576
	P=$T/root/var/lib/dualboot/pmos
	mkimg "$P/boot-ns-heap.img" "$BOOT" x
	mkimg "$P/vendor_boot-current.img" "$VB" y
	mkimg "$P/dtbo-noidlepc-nocbc.img" "$DT" z
	echo 1 > "$T/root/var/lib/dualboot/bootfails"
	printf '#!/bin/sh\necho "${MODEL:-SM-S936B}"\n' > "$T/bin/getprop"
	printf '#!/bin/sh\n[ "$*" = "sys.powerctl reboot" ] && touch "%s/rebooted"\n' "$T" > "$T/bin/setprop"
	chmod +x "$T/bin/getprop" "$T/bin/setprop"
}

ctl() {
	PATH="$T/bin:$PATH" PA2Q_BLOCK_DIR="$T/blk" PA2Q_DATA="$T/data" PA2Q_ROOTFS="$T/root" PA2Q_REBOOT_WAIT=0 PA2Q_SYSRQ="$T/sysrq" sh "$CTL" "$@"
}

same_head() { [ "$(head -c "$(stat -c %s "$1")" "$2" | md5sum)" = "$(md5sum < "$1")" ]; }
installed() { for p in "boot-ns-heap.img boot_a" "vendor_boot-current.img vendor_boot_a" "dtbo-noidlepc-nocbc.img dtbo_a"; do
	set -- $p; same_head "$T/root/var/lib/dualboot/pmos/$1" "$T/blk/$2" || return 1; done; }
fails_counter() { [ "$(cat "$T/root/var/lib/dualboot/bootfails")" = "$1" ]; }
not() { ! "$@"; }
status_has() { ctl status | grep -qx "$1"; }

# --- the normal switch
setup
cp "$T/blk/boot_a" "$T/android-boot"
check "status: Android chain detected" status_has chain=android
ctl switch > "$T/log" 2>&1
check "switch: exits ok" test $? = 0
check "switch: pmOS images on all three partitions" installed
check "switch: rebooted through sys.powerctl" test -e "$T/rebooted"
check "switch: forced reboot if still alive" grep -qx b "$T/sysrq"
check "switch: boot-fail counter cleared" fails_counter 0
B=$T/data/backups/$(ls "$T/data/backups")
check "switch: Android boot backed up" cmp "$B/boot.img" "$T/android-boot"
check "switch: return image for pmOS is Android's" cmp "$T/root/var/lib/dualboot/android/boot_a.img" "$T/android-boot"
check "status: pmOS chain detected" status_has chain=pmos

# --- check agrees and writes nothing
setup
cp "$T/blk/boot_a" "$T/android-boot"
ctl backup >/dev/null 2>&1; mkdir -p "$T/root/var/lib/dualboot/android"; for s in boot vendor_boot dtbo; do cp "$T/blk/${s}_a" "$T/root/var/lib/dualboot/android/${s}_a.img"; done
ctl check > "$T/log" 2>&1
check "check: passes on good images" test $? = 0
check "check: partition untouched" cmp "$T/blk/boot_a" "$T/android-boot"
printf garbage > "$T/root/var/lib/dualboot/pmos/boot-ns-heap.img"
ctl check > "$T/log" 2>&1
check "check: fails on a bad image" test $? != 0

setup
cp "$T/blk/boot_a" "$T/android-boot"
ctl switch > "$T/log" 2>&1
B=$T/data/backups/$(ls "$T/data/backups")

# --- a second switch must not overwrite the Android backup with pmOS images
rm "$T/rebooted"
ctl switch > "$T/log" 2>&1
check "already pmOS: still reboots" test -e "$T/rebooted"
check "already pmOS: no new backup" test "$(ls "$T/data/backups" | wc -l)" = 1
check "already pmOS: return image kept" cmp "$T/root/var/lib/dualboot/android/boot_a.img" "$T/android-boot"

# --- restore brings Android back
ctl restore "$(basename "$B")" > "$T/log" 2>&1
check "restore: exits ok" test $? = 0
[ -n "${SHOW:-}" ] && cat "$T/log"
check "restore: Android boot is back" cmp "$T/blk/boot_a" "$T/android-boot"

# --- a write failing halfway rolls back and does not reboot
setup
cp "$T/blk/boot_a" "$T/android-boot"
chmod a-w "$T/blk/vendor_boot_a"
ctl switch > "$T/log" 2>&1
check "failed write: exits with an error" test $? != 0
check "failed write: boot partition rolled back" cmp "$T/blk/boot_a" "$T/android-boot"
check "failed write: no reboot" not test -e "$T/rebooted"
check "failed write: no forced reboot" not test -e "$T/sysrq"
check "failed write: rollback got past the bad partition" grep -q "dtbo_a <- dtbo.img" "$T/log"
check "failed write: warns not to reboot" grep -q "Do NOT reboot" "$T/log"

# --- refusals, none of which may touch a partition
setup
cp "$T/blk/boot_a" "$T/android-boot"
printf 'garbage garbage' > "$T/root/var/lib/dualboot/pmos/boot-ns-heap.img"
ctl switch > "$T/log" 2>&1
check "bad image: refused" test $? != 0
check "bad image: partition untouched" cmp "$T/blk/boot_a" "$T/android-boot"

setup
cp "$T/blk/boot_a" "$T/android-boot"
rm "$T/root/var/lib/dualboot/pmos/dtbo-noidlepc-nocbc.img"
ctl switch > "$T/log" 2>&1
check "missing image: refused" test $? != 0
check "missing image: partition untouched" cmp "$T/blk/boot_a" "$T/android-boot"

setup
cp "$T/blk/boot_a" "$T/android-boot"
truncate -s 2097152 "$T/root/var/lib/dualboot/pmos/boot-ns-heap.img"
ctl switch > "$T/log" 2>&1
check "oversized image: refused" test $? != 0
check "oversized image: partition untouched" cmp "$T/blk/boot_a" "$T/android-boot"

setup
cp "$T/blk/boot_a" "$T/android-boot"
MODEL=SM-S931B ctl switch > "$T/log" 2>&1
check "other phone: refused" test $? != 0
check "other phone: partition untouched" cmp "$T/blk/boot_a" "$T/android-boot"

setup
dd if="$T/root/var/lib/dualboot/pmos/boot-ns-heap.img" of="$T/blk/boot_a" conv=notrunc 2>/dev/null
cp "$T/blk/vendor_boot_a" "$T/android-vb"
ctl switch > "$T/log" 2>&1
check "mixed chain: refused" test $? != 0
check "mixed chain: partition untouched" cmp "$T/blk/vendor_boot_a" "$T/android-vb"
check "mixed chain: no half-pmOS backup" test ! -d "$T/data/backups"

# --- backups only grow when something changed
setup
ctl backup >/dev/null 2>&1; ctl backup >/dev/null 2>&1
check "backup twice: one copy" test "$(ls "$T/data/backups" | wc -l)" = 1

# --- restore refuses a corrupt backup
setup
ctl backup >/dev/null 2>&1
B=$(ls "$T/data/backups")
cp "$T/blk/boot_a" "$T/android-boot"
dd if=/dev/zero of="$T/data/backups/$B/dtbo.img" bs=1 seek=100 count=1 conv=notrunc 2>/dev/null
mkimg "$T/blk/boot_a" "$BOOT" q 1048576
ctl restore "$B" > "$T/log" 2>&1
check "corrupt backup: refused" test $? != 0
check "corrupt backup: partition untouched" not cmp "$T/blk/boot_a" "$T/android-boot"

# --- installing an image keeps the old one and rejects the wrong kind
setup
mkimg "$T/new.img" "$BOOT" n
ctl install boot "$T/new.img" > "$T/log" 2>&1
check "install: new image in place" cmp "$T/new.img" "$T/root/var/lib/dualboot/pmos/boot-ns-heap.img"
check "install: old image kept" test -f "$T/root/var/lib/dualboot/pmos/boot-ns-heap.img.prev"
ctl install dtbo "$T/new.img" > "$T/log" 2>&1
check "install: wrong kind refused" test $? != 0

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails FAILED"; exit 1; }
