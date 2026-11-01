#!/bin/bash
# Host-side hang detector for pa2q pmOS. Exits with a one-line verdict (and a
# critical desktop notification for the bad ones) as soon as something needs a
# human:
#   HUNG ...      pmOS on USB but not answering   -> force-restart, hold Vol-Up
#   RESET ...     dropped off USB (crash / watchdog reset)
#   DOWNLOAD      sitting in download mode
#   ANDROID       it left pmOS (escape hatch / boot-loop fallback)
# Otherwise it watches the running session until --minutes runs out.
# usage: pmos-watch.sh [--boot] [--minutes N]
#   --boot  a pmOS boot is starting: allow 120 s from USB gadget to ping
set -u
BOOT=no; MINUTES=240
while [ $# -gt 0 ]; do
	case "$1" in --boot) BOOT=yes ;; --minutes) MINUTES=$2; shift ;; esac
	shift
done
IP=172.16.42.1
usb() { lsusb | grep -q "$1"; }
gadget() { usb 18d1:d001; }
android() { usb 04e8:6860; }
download() { usb 04e8:685d; }
alert() {
	echo "$1"
	notify-send -u critical -a pa2q "pa2q: $1" "Force-restart: hold Power+Vol-Down ~10 s, then hold Vol-Up to get back to Android." 2>/dev/null
	canberra-gtk-play -i dialog-warning 2>/dev/null
	exit 1
}
end=$((SECONDS + MINUTES * 60))

if [ "$BOOT" = yes ]; then
	# started right before the switch: let Android leave the bus first
	while android && [ $SECONDS -lt 90 ]; do sleep 1; done
	until gadget || android || download; do
		[ $SECONDS -gt 180 ] && alert "HUNG: nothing on USB 3 min after reboot"
		sleep 2
	done
	android && { echo "ANDROID"; exit 0; }
	download && alert "DOWNLOAD: phone is in download mode"
	# alive = answering ping (usb0 is configured in the boot runlevel); ssh can
	# legitimately lag behind slow default-runlevel services
	t0=$SECONDS
	until ping -c1 -W2 $IP >/dev/null 2>&1; do
		android && { echo "ANDROID"; exit 0; }
		[ $((SECONDS - t0)) -gt 120 ] && alert "HUNG: pmOS on USB but no ping after 120 s"
		sleep 3
	done
	echo "BOOT_OK: ping after $((SECONDS - t0)) s from USB"
fi

misses=0; gone=0
while [ $SECONDS -lt $end ]; do
	if ping -c1 -W2 $IP >/dev/null 2>&1; then
		misses=0; gone=0
	elif gadget; then
		gone=0; misses=$((misses + 1))
		[ $misses -ge 3 ] && alert "HUNG: pmOS stopped answering (on USB, 3 missed pings)"
	elif android; then
		echo "ANDROID"; exit 0
	elif download; then
		alert "DOWNLOAD: phone is in download mode"
	else
		gone=$((gone + 1))
		[ $gone -ge 2 ] && alert "RESET: phone dropped off USB (crash or watchdog reset)"
	fi
	sleep 10
done
echo "WATCH_END"
