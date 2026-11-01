#!/bin/sh
# Bring up sun-mtp-snd-card.
#
# The machine driver (machine_dlkm, "sun-asoc-snd") builds its DAI links from
# the DT sound node, which has qcom,wcn-bt=1.  That pulls in the BTFM_PROXY
# links whose codec is "btfmcodec_dev" -- an ASoC component that only appears
# once the BT SoundWire transport enumerates.  We have no SWR master, so it
# never appears and the card would defer forever.
#
# The driver has an escape hatch: qcom,max_defer_count (13 on this device).
# Once it has been re-probed that many times it gives up on the missing
# codecs, rewrites those DAI links to DUMMY (see change_snd_card_dailinks)
# and registers the card anyway.  Deferred-probe retries only run when some
# driver binds/unbinds, so we cycle msm_geni_serial to generate them.
#
# tas25xx (the speaker amp) additionally needs tismartpa_driver_tuning.bin,
# which lives in the vendor image, not /lib/firmware.  Without it the amp
# probe spins and its DAI link gets dummied out too, losing the speaker.
set -u
MODDIR=/lib/modules/$(uname -r)/vendor

# /proc/asound/card0 appears slightly before /proc/asound/cards is filled
# in, so test the file we actually report from.
card_up() { [ -e /proc/asound/card0 ] && ! grep -q "no soundcards" /proc/asound/cards; }

# 1. Speaker amp tuning firmware must be in place *before* the card binds.
for f in /mnt/vendor/firmware/tismartpa*.bin; do
    [ -e "$f" ] || continue
    [ -e "/lib/firmware/${f##*/}" ] || cp "$f" /lib/firmware/
done

card_up && { echo "card already up"; exit 0; }

# 2. btfmcodec is a softdep of machine_dlkm.  Deliberately NOT btpower: it is
#    left alone here so Bluetooth can load it cleanly later.
[ -e /dev/btfmcodec_dev ] || insmod "$MODDIR/btfmcodec.ko" 2>/dev/null

# 3. Burn through max_defer_count.
# Re-probe the sound device directly instead of cycling a module.
#
# Earlier versions forced probe retries by repeatedly rmmod/insmod'ing a
# driver that binds something (btpower, then msm_geni_serial).  That works but
# is corrosive: the rapid cycling races the driver's probe and wedges it until
# the next reboot -- btpower ends up refusing to load ("btpower_init: coudn't
# create class"), msm_geni_serial ends up "Resource busy".  Both are needed by
# Bluetooth (btpower owns the chip's regulators/reset GPIO, msm_geni_serial
# provides the BT UART), so bringing up sound was breaking Bluetooth.
#
# Writing the device name to the bus's drivers_probe re-runs device_attach for
# just that device, which bumps the driver's defer_count exactly the same way
# without disturbing any other module.
SOUND_DEV=soc:spf_core_platform:sound
i=0
while [ $i -lt 40 ]; do
    card_up && break
    echo "$SOUND_DEV" > /sys/bus/platform/drivers_probe 2>/dev/null
    i=$((i + 1))
    sleep 1
done

# The card appears a moment after the last probe returns.
i=0
while [ $i -lt 20 ]; do
    card_up && break
    sleep 1
    i=$((i + 1))
done

if card_up; then
    echo "sound card up: $(sed -n "2p" /proc/asound/cards | tr -s " ")"
else
    echo "sound card did NOT come up" >&2
    exit 1
fi
