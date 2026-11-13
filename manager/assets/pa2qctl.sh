#!/system/bin/sh
# pa2q Manager backend: everything that touches partitions, run as root from
# the Android side. The app only draws buttons and shows this script's output.
#
#   status                     key=value lines for the dashboard
#   check                      every check switch does, writes nothing
#   switch [--no-reboot]       back up Android, install pmOS's boot chain, reboot
#   backup                     save the current boot chain (skipped if unchanged)
#   backups                    list saved backups, newest first
#   restore NAME               write a saved backup back, no reboot
#   mount | umount             keep the pmOS rootfs mounted rw at $MNT
#   install SLOT FILE          replace a pmOS image (boot|vendor_boot|dtbo)
#   bootlog [prev]             pmOS boot trace
#   reset-fails                clear pmOS's boot-loop counter
#   reboot
#
# Same three-partition switch as device/boot-switch, which is the pmOS side.
# PA2Q_BLOCK_DIR, PA2Q_DATA and PA2Q_ROOTFS exist for test-pa2qctl.sh.
set -u
# The app can die mid-flash: this script must finish regardless.
trap '' HUP PIPE

BLK=${PA2Q_BLOCK_DIR:-/dev/block/by-name}
DATA=${PA2Q_DATA:-/data/adb/pa2q-manager}
MNT=${PA2Q_ROOTFS:-/mnt/pmosroot}
ROOT_OFFSET=511705088	# rootfs inside pmOS_root, see README "Device facts"
SLOTS="boot vendor_boot dtbo"
OURS=""
LOOP=""

die() { echo "ERROR: $*"; exit 1; }

# A real kernel reboot. "svc power reboot" and the power menu can come back as
# a soft reboot here (only system_server restarts), and then the new boot chain
# never loads. sys.powerctl is what adb reboot uses; if we are somehow still
# alive after that, force it.
hard_reboot() {
	sync
	setprop sys.powerctl reboot
	sleep "${PA2Q_REBOOT_WAIT:-30}"
	sync
	echo b > "${PA2Q_SYSRQ:-/proc/sysrq-trigger}"
}

part() { echo "$BLK/$1_a"; }

pmos_img() {
	case "$1" in
	boot) echo "$MNT/var/lib/dualboot/pmos/boot-ns-heap.img" ;;
	vendor_boot) echo "$MNT/var/lib/dualboot/pmos/vendor_boot-current.img" ;;
	dtbo) echo "$MNT/var/lib/dualboot/pmos/dtbo-noidlepc-nocbc.img" ;;
	esac
}

android_img() { echo "$MNT/var/lib/dualboot/android/$1_a.img"; }

magic() {
	case "$1" in
	boot) echo "41 4e 44 52 4f 49 44 21" ;;	# ANDROID!
	vendor_boot) echo "56 4e 44 52 42 4f 4f 54" ;;	# VNDRBOOT
	dtbo) echo "d7 b7 ab 1e" ;;
	esac
}

check_device() {
	case "$(getprop ro.product.model) $(getprop ro.product.device)" in
	SM-S936*|*pa2q*) ;;
	*) die "this is not a Galaxy S25+ (pa2q), refusing to flash" ;;
	esac
}

partsize() { blockdev --getsize64 "$1" 2>/dev/null || stat -c %s "$1"; }

md5() { md5sum "$1" | cut -d' ' -f1; }

# md5 of the first $2 bytes of a partition
head_md5() { dd if="$1" bs="$2" count=1 2>/dev/null | md5sum | cut -d' ' -f1; }

# Refuse anything that is not an image of this kind or does not fit the partition
check_image() {
	[ -f "$2" ] || die "missing image: $2"
	want=$(magic "$1")
	got=$(od -An -tx1 -N"$(( (${#want} + 1) / 3 ))" "$2" | tr -s ' \n' ' ' | sed 's/^ //; s/ $//')
	[ "$got" = "$want" ] || die "$2 is not a $1 image"
	[ "$(stat -c %s "$2")" -le "$(partsize "$(part "$1")")" ] || die "$2 does not fit $1_a"
}

mounted() { grep -q " $MNT " /proc/mounts; }

mount_root() {	# rw|ro
	[ -n "${PA2Q_ROOTFS:-}" ] && return 0
	if mounted; then
		[ "$1" = ro ] || mount -o remount,rw "$MNT" || die "cannot remount $MNT rw"
		return 0
	fi
	dev=$BLK/pmOS_root
	[ -b "$dev" ] || dev=/dev/block/sda60
	[ -b "$dev" ] || die "pmOS partition not found"
	LOOP=$(losetup -f) || die "no free loop device"
	mkdir -p "$MNT"
	# 4K-logical disk: plain losetup -o gets EIO, see recovery/loopcfg.c
	"$DATA/bin/loopcfg" "$LOOP" "$dev" "$ROOT_OFFSET" 4096 >/dev/null || die "loopcfg failed on $dev"
	if [ "$1" = ro ]; then opts=ro,noload; else opts=rw; fi
	if ! mount -t ext4 -o "$opts" "$LOOP" "$MNT"; then
		losetup -d "$LOOP" 2>/dev/null
		die "cannot mount the pmOS rootfs"
	fi
	OURS=1
	trap release_root EXIT
}

release_root() {
	[ -n "$OURS" ] || return 0
	sync
	umount "$MNT" || echo "WARNING: could not unmount $MNT"
	losetup -d "$LOOP" 2>/dev/null	# already gone if the kernel auto-cleared it
	OURS=""
}

slot_state() {	# pmos|android
	img=$(pmos_img "$1")
	[ -f "$img" ] || { echo unknown; return; }
	if [ "$(head_md5 "$(part "$1")" "$(stat -c %s "$img")")" = "$(md5 "$img")" ]; then
		echo pmos
	else
		echo android
	fi
}

chain_state() {
	n=0; u=0
	for s in $SLOTS; do
		case "$(slot_state "$s")" in
		pmos) n=$((n + 1)) ;;
		unknown) u=1 ;;
		esac
	done
	if [ "$u" = 1 ]; then echo unknown
	elif [ "$n" = 3 ]; then echo pmos
	elif [ "$n" = 0 ]; then echo android
	else echo mixed
	fi
}

latest_backup() { ls -1 "$DATA/backups" 2>/dev/null | sort | tail -1; }

# Sets BACKUP to a backup holding the current chain; makes one only if needed.
do_backup() {
	mkdir -p "$DATA/backups"
	now=$(date +%Y%m%d-%H%M%S)
	tmp=$DATA/backups/.tmp-$now
	rm -rf "$tmp"; mkdir -p "$tmp"
	for s in $SLOTS; do
		dd if="$(part "$s")" of="$tmp/$s.img" bs=4M 2>/dev/null || die "cannot read ${s}_a"
		[ "$(md5 "$tmp/$s.img")" = "$(head_md5 "$(part "$s")" "$(stat -c %s "$tmp/$s.img")")" ] ||
			die "backup of $s does not match the partition"
		echo "$(md5 "$tmp/$s.img")  $s.img" >> "$tmp/md5sums"
	done
	last=$(latest_backup)
	if [ -n "$last" ] && cmp -s "$tmp/md5sums" "$DATA/backups/$last/md5sums"; then
		rm -rf "$tmp"
		BACKUP=$DATA/backups/$last
		echo "Backup: unchanged since $last"
	else
		mv "$tmp" "$DATA/backups/$now"
		BACKUP=$DATA/backups/$now
		echo "Backup: saved $now"
	fi
}

write_verify() {	# source slot
	dst=$(part "$2")
	size=$(stat -c %s "$1")
	echo "  $2_a <- $(basename "$1")"
	dd if="$1" of="$dst" bs=4M conv=notrunc,fsync 2>/dev/null || return 1
	[ "$(md5 "$1")" = "$(head_md5 "$dst" "$size")" ]
}

# Put the backup back after a failed write, so Android still boots.
rollback() {
	echo "Write failed, putting Android's boot chain back ..."
	ok=1
	for s in $SLOTS; do
		write_verify "$BACKUP/$s.img" "$s" || { ok=0; echo "  FAILED: ${s}_a"; }
	done
	sync
	[ "$ok" = 1 ] && die "pmOS was not installed; Android's boot chain is intact"
	die "ROLLBACK FAILED. Do NOT reboot. Backup is in $BACKUP"
}

# pmOS's boot-switch returns to Android from these. Keep them equal to what is
# running now, so an OTA or a re-root doesn't get undone on the way back.
sync_return_images() {
	mkdir -p "$MNT/var/lib/dualboot/android"
	for s in $SLOTS; do
		f=$(android_img "$s")
		if [ -f "$f" ] && [ "$(md5 "$f")" = "$(head_md5 "$BACKUP/$s.img" "$(stat -c %s "$f")")" ]; then
			continue
		fi
		echo "Return image: updating $s"
		[ -f "$f" ] && { cp "$f" "$f.prev" || die "cannot save $f.prev"; }
		cp "$BACKUP/$s.img" "$f.new" || die "no room for $f"
		[ "$(md5 "$f.new")" = "$(md5 "$BACKUP/$s.img")" ] || die "copy of $s is bad"
		mv "$f.new" "$f"
	done
}

cmd_status() {
	echo "model=$(getprop ro.product.model)"
	echo "kernel=$(uname -r)"
	if mounted || [ -n "${PA2Q_ROOTFS:-}" ]; then echo "mounted=yes"; else echo "mounted=no"; fi
	mount_root ro
	echo "chain=$(chain_state)"
	img=$(pmos_img boot)
	[ -f "$img" ] && echo "pmos_kernel=$(basename "$img") $(( $(stat -c %s "$img") / 1048576 )) MB"
	df -k "$MNT" | tail -1 | awk '{ printf "rootfs=%.1f GB free of %.1f GB\n", $4/1048576, $2/1048576 }'
	echo "fails=$(cat "$MNT/var/lib/dualboot/bootfails" 2>/dev/null || echo 0)"
	r=yes
	for s in $SLOTS; do [ -f "$(android_img "$s")" ] || r=no; done
	echo "return_images=$r"
	echo "backups=$(ls -1 "$DATA/backups" 2>/dev/null | wc -l | tr -d ' ')"
	echo "latest_backup=$(latest_backup)"
}

# Everything switch checks before it writes, without writing.
cmd_check() {
	check_device
	mount_root ro
	for s in $SLOTS; do
		check_image "$s" "$(pmos_img "$s")"
		echo "ok  $s: $(basename "$(pmos_img "$s")")"
	done
	for s in $SLOTS; do
		f=$(android_img "$s")
		check_image "$s" "$f"
		if [ "$(chain_state)" != android ] || [ "$(md5 "$f")" = "$(head_md5 "$(part "$s")" "$(stat -c %s "$f")")" ]; then
			echo "ok  return image $s"
		else
			echo "old return image $s (updated on the next switch)"
		fi
	done
	echo "Boot chain: $(chain_state)"
}

cmd_switch() {
	check_device
	mount_root rw
	for s in $SLOTS; do check_image "$s" "$(pmos_img "$s")"; done
	state=$(chain_state)
	echo "Boot chain now: $state"
	case "$state" in
	pmos) echo "pmOS is already installed" ;;
	android)
		do_backup
		sync_return_images
		# A fresh start: without this one old failed boot sends the phone
		# straight back to Android, see device/bootkey-recovery.initd
		echo 0 > "$MNT/var/lib/dualboot/bootfails"
		sync
		echo "Writing pmOS boot chain:"
		for s in $SLOTS; do
			write_verify "$(pmos_img "$s")" "$s" || rollback
		done
		sync
		;;
	*) die "boot chain is mixed; restore a backup first" ;;
	esac
	release_root
	if [ "${1:-}" = --no-reboot ]; then
		echo "All verified. Reboot when ready."
	else
		echo "All verified. Rebooting into postmarketOS ..."
		hard_reboot
	fi
}

cmd_restore() {
	check_device
	d=$DATA/backups/${1:-}
	[ -n "${1:-}" ] && [ -f "$d/md5sums" ] || die "no such backup: ${1:-}"
	for s in $SLOTS; do
		check_image "$s" "$d/$s.img"
		[ "$(md5 "$d/$s.img")  $s.img" = "$(grep " $s.img\$" "$d/md5sums")" ] || die "$s.img is corrupt"
	done
	echo "Restoring $1:"
	for s in $SLOTS; do
		write_verify "$d/$s.img" "$s" || die "writing ${s}_a failed. Do NOT reboot; try again."
	done
	sync
	echo "Restored. Reboot to use it."
}

cmd_install() {
	case "${1:-}" in boot|vendor_boot|dtbo) ;; *) die "slot must be boot, vendor_boot or dtbo" ;; esac
	check_image "$1" "${2:-}"
	mount_root rw
	f=$(pmos_img "$1")
	mkdir -p "$(dirname "$f")"
	cp "$2" "$f.new" || die "no room for $f"
	[ "$(md5 "$f.new")" = "$(md5 "$2")" ] || die "copy is bad"
	[ -f "$f" ] && { mv "$f" "$f.prev" || die "cannot save $f.prev"; }
	mv "$f.new" "$f"
	sync
	echo "Installed as $(basename "$f"); the old one is $(basename "$f").prev"
	echo "Takes effect on the next Boot postmarketOS."
}

cmd_bootlog() {
	mount_root ro
	f=$MNT/var/log/boot-trace.log
	[ "${1:-}" = prev ] && f=$f.prev
	[ -f "$f" ] || die "no boot trace yet"
	tail -n 200 "$f"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
status) cmd_status ;;
check) cmd_check ;;
switch) cmd_switch "$@" ;;
backup) check_device; do_backup ;;
backups) ls -1 "$DATA/backups" 2>/dev/null | sort -r ;;
restore) cmd_restore "$@" ;;
mount) mount_root rw; OURS=""; trap - EXIT; echo "Mounted at $MNT" ;;
umount)
	if mounted; then
		sync
		dev=$(grep " $MNT " /proc/mounts | cut -d' ' -f1)
		umount "$MNT" || die "cannot unmount; something is using $MNT"
		losetup -d "$dev" 2>/dev/null
		echo "Unmounted"
	else
		echo "Not mounted"
	fi
	;;
install) cmd_install "$@" ;;
bootlog) cmd_bootlog "$@" ;;
reset-fails) mount_root rw; echo 0 > "$MNT/var/lib/dualboot/bootfails"; echo "Boot-fail counter cleared" ;;
reboot) hard_reboot ;;
*) die "unknown command: $cmd" ;;
esac
