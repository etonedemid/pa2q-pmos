#!/bin/sh
# Bring up Android vendor subsystems under postmarketOS on pa2q.
#
#   vendor-up.sh gpu      - Adreno 830: Vulkan 1.4 + GLES 3.2 via kgsl
#   vendor-up.sh modem    - mss remoteproc + rmtfs (56 QMI services incl. DMS)
#   vendor-up.sh display  - msm_drm. WARNING: a modeset currently HANGS the
#                           device in sde_cesta. Loading the driver is safe;
#                           modetest -s is not.
#   vendor-up.sh wifi     - wlan0: vendor config, EFS MAC, qca_cld3 host driver
#                           (brings the modem up first - DMS must exist)
#   vendor-up.sh audio    - ADSP + q6/machine drivers. INCOMPLETE: no card yet,
#                           the ADSP audio service never becomes ready.
#   vendor-up.sh deadman  - arm a ~30s deadman timer before something risky.
#                           The watchdog resets UNCONDITIONALLY unless petted,
#                           so this is not "reset on hang" - it is "reset in
#                           30s no matter what". Run 'vendor-up.sh alive' as
#                           soon as you survive, or the phone reboots itself.
#   vendor-up.sh alive    - resume petting (cancel the deadman timer)
#
# The module list in the initramfs already loads the transports (smp2p,
# qcom_q6v5_pas, msm_sharedmem, glink_probe, qrtr-smd, mhi, pci-msm-drv), so
# the remoteprocs are registered and offline at boot. Nothing here is enabled
# automatically: each subsystem is opt-in because each has bitten us.
set -u
log() { echo "vendor-up: $*"; echo "<3>vendor-up: $*" > /dev/kmsg 2>/dev/null; }

mount_vendor() {
	mountpoint -q /mnt/vendor && return 0
	OFF=$(lpdump /dev/disk/by-partlabel/super 2>/dev/null |
	      awk '/Name: vendor_a$/{f=1} f&&/linear super/{print $NF; exit}')
	mkdir -p /mnt/vendor
	losetup -r -o $(( ${OFF:-19603456} * 512 )) /dev/loop5 /dev/sda31 2>/dev/null
	mount -t erofs -o ro /dev/loop5 /mnt/vendor 2>/dev/null && log "vendor mounted"
}

case "${1:-}" in
gpu)
	# The Adreno microcode is the whole ballgame: without it both Vulkan and
	# EGL report "no device" and never say why - only the kernel does
	# ("Direct firmware load for gen80000_sqe.fw failed"). Keep it in
	# /lib/firmware rather than moving firmware_class.path, which must never
	# point at a directory containing ipa_fws.mdt.
	if [ ! -f /lib/firmware/gen80000_sqe.fw ]; then
		mount_vendor
		cp -f /mnt/vendor/firmware/gen80000_sqe.fw \
		      /mnt/vendor/firmware/gen80000_aqe.fw \
		      /mnt/vendor/firmware/gen80000_gmu.bin \
		      /mnt/vendor/firmware/gen80000_zap.mbn /lib/firmware/ 2>/dev/null
		log "adreno firmware installed"
	fi
	modprobe msm_kgsl 2>/dev/null
	sleep 3
	[ -e /dev/kgsl-3d0 ] && log "gpu ready: $(cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null)" \
	                     || log "gpu FAILED - see dmesg | grep kgsl"
	;;
modem)
	mount_vendor
	mountpoint -q /mnt/fw || { mkdir -p /mnt/fw; mount -o ro /dev/disk/by-partlabel/modem_a /mnt/fw; }
	# Modem images only - never a directory containing ipa_fws.mdt.
	if [ ! -f /lib/firmware/modem-only/modem.mdt ]; then
		mkdir -p /lib/firmware/modem-only
		cp -f /mnt/fw/image/modem.* /mnt/fw/image/modem_dtb.* /lib/firmware/modem-only/ 2>/dev/null
	fi
	# rmtfs needs the uio node from msm_sharedmem under the name it expects,
	# and serves file copies so the real EFS partitions are never written.
	ln -sf /dev/uio0 /dev/qcom_rmtfs_uio1
	ln -sf /dev/uio0 /dev/qcom_rmtfs_uio0
	mkdir -p /var/lib/rmtfs
	for p in modemst1 modemst2 fsg fsc; do
		[ -f /var/lib/rmtfs/$p ] || cp -f /root/efs-backup/$p.img /var/lib/rmtfs/$p 2>/dev/null
	done
	# rmtfs opens the basename of the requested path: modem_fs1, not modemst1.
	ln -sf modemst1 /var/lib/rmtfs/modem_fs1
	ln -sf modemst2 /var/lib/rmtfs/modem_fs2
	ln -sf fsg      /var/lib/rmtfs/modem_fsg
	ln -sf fsc      /var/lib/rmtfs/modem_fsc
	pidof rmtfs >/dev/null 2>&1 || { /usr/local/bin/rmtfs -o /var/lib/rmtfs -s -v > /var/log/rmtfs.log 2>&1 & sleep 3; }
	pidof rmtfs >/dev/null 2>&1 || { log "rmtfs failed to start - see /var/log/rmtfs.log"; exit 1; }
	log "rmtfs running"
	mount -t debugfs none /sys/kernel/debug 2>/dev/null
	# Without this a modem crash takes the whole system down.
	echo enabled > /sys/kernel/debug/remoteproc/remoteproc1/recovery 2>/dev/null
	echo -n /lib/firmware/modem-only > /sys/module/firmware_class/parameters/path
	echo start > /sys/class/remoteproc/remoteproc1/state 2>/dev/null
	sleep 20
	# firmware_class.path is a GLOBAL kernel parameter, not scoped to this
	# remoteproc load: leaving it pointed at modem-only starves every other
	# request_firmware() call for the rest of uptime of anything outside
	# that directory. This silently broke the TAS25XX speaker amp - its
	# codec_probe() calls request_firmware_nowait() for
	# tismartpa_driver_tuning.bin at ~48s (kernel-driven i2c probe, not
	# ordered against this script), found nothing under modem-only, and
	# took the driver's soft-fail path: -ENOENT is mapped to a successful
	# probe with the DSP profile never loaded. All the amp's mixer
	# controls, DAPM widgets and I2C power sequencing work fine because none
	# of that needs firmware - only the actual audio output stage silently
	# never gets configured. Reset it back to default now that the modem's
	# own load is done.
	echo "" > /sys/module/firmware_class/parameters/path
	log "modem: $(cat /sys/class/remoteproc/remoteproc1/state), $(qrtr-lookup 2>/dev/null | tail -n +2 | wc -l) QMI services"
	;;
display)
	modprobe msm_drm 2>/dev/null
	sleep 8
	log "drm: $(ls /dev/dri 2>/dev/null | tr '\n' ' ')  DSI-1: $(cat /sys/class/drm/card0-DSI-1/status 2>/dev/null)"
	log "NOTE: do not run 'modetest -s' - the modeset hangs in sde_cesta"
	;;
wifi)
	# Four things must be in place before the host driver will probe. Any one
	# of them missing surfaces as the same unhelpful line:
	#   cnss: Failed to probe host driver, err = -1
	# See PORTING-NOTES "Wi-Fi". DMS answering err 16 ("not provisioned") is
	# expected and harmless once macloader has supplied the MAC.
	mount_vendor
	# WCNSS_qcom_cfg.ini is a symlink into /vendor/etc/wifi/kiwi_v2, but
	# mount_vendor puts the erofs at /mnt/vendor. Without this the driver has
	# no config and the probe fails.
	[ -e /vendor ] || ln -s /mnt/vendor /vendor
	# The real MAC is in EFS. wlan_mac.bin points at a persist path
	# (/mnt/vendor/persist/kiwi_v2) that does not exist on this device.
	mountpoint -q /mnt/efs || { mkdir -p /mnt/efs
		mount -o ro /dev/disk/by-partlabel/efs /mnt/efs; }
	MAC=$(tr -d ' \t\r\n' < /mnt/efs/wifi/.mac.info 2>/dev/null)
	[ -n "$MAC" ] || { log "wifi: no MAC in /mnt/efs/wifi/.mac.info"; exit 1; }
	# DMS lives on the modem, so the modem has to be running first.
	[ "$(cat /sys/class/remoteproc/remoteproc1/state 2>/dev/null)" = "running" ] ||
		"$0" modem
	# cnss2 brings up the WLAN platform driver and creates the write-only
	# macloader nodes under /sys/wifi. Nothing loads it automatically here:
	# modules.alias is shipped renamed to modules.alias.disabled, so udev never
	# matches the PCIe modalias. Load it explicitly and wait for the nodes,
	# rather than assuming something else got there first.
	if [ ! -e /sys/wifi/mac_addr ]; then
		modprobe rfkill 2>/dev/null
		modprobe cfg80211 2>/dev/null
		modprobe cnss2 2>/dev/null
		i=0
		while [ $i -lt 15 ] && [ ! -e /sys/wifi/mac_addr ]; do sleep 1; i=$((i + 1)); done
	fi
	[ -e /sys/wifi/mac_addr ] || { log "wifi: cnss2 did not create /sys/wifi/mac_addr"; exit 1; }

	# Both macloader nodes are write-only, and both must be written *before*
	# the host driver loads.
	printf '%s' "$MAC" > /sys/wifi/mac_addr 2>/dev/null ||
		log "wifi: macloader mac_addr not writable"
	echo 1 > /sys/wifi/ant 2>/dev/null
	modprobe qca_cld3_kiwi_v2 2>/dev/null
	i=0
	while [ $i -lt 25 ] && [ ! -e /sys/class/net/wlan0 ]; do sleep 1; i=$((i + 1)); done
	[ -e /sys/class/net/wlan0 ] || { log "wifi FAILED - dmesg | grep cnss"; exit 1; }
	# wlan0 appears with a random MAC even when macloader accepted ours.
	if [ "$(cat /sys/class/net/wlan0/address)" != "$(echo "$MAC" | tr 'A-F' 'a-f')" ]; then
		ip link set wlan0 down
		ip link set wlan0 address "$MAC"
	fi
	ip link set wlan0 up
	log "wifi ready: wlan0 $(cat /sys/class/net/wlan0/address)"
	;;
audio)
	# INCOMPLETE - still no sound card, but much further than before.
	#
	# Working now (all of this was missing after the sda60 migration):
	#   * ADSP firmware. adsp.* AND adsp_dtb.* both live in the apnhlos
	#     partition, not in vendor/firmware. Without adsp_dtb the remoteproc
	#     fails with "Failed to load program segments: -2" and stays offline.
	#   * pd-mapper (apk add soc-qcom-pd-mapper pd-mapper-openrc) plus the PD
	#     map files: it exits with "no pd maps available" until the *.jsn from
	#     apnhlos are copied into /lib/firmware.
	#   * the dsp partition mounted where the DSP expects it, /vendor/dsp.
	#
	# Result: ADSP boots and runs, appears on QRTR node 5, GPR attaches
	# ("gpr-lite probe success"), and the kernel registers a PDR lookup for
	# avs/audio (msm/adsp/audio_pd).
	#
	# Still blocked: that audio protection domain never comes up, so
	#   spf-core-platform: __spf_core_is_apm_ready: send_command ret
	#   gpr_send_pkt: q6 state is down
	# repeat forever and no card registers. Node 5 exposes servreg, subsys
	# control, CoreSight and SLIMbus - but no audio/APM service.
	#
	# Compared against Android (which has working audio): it runs
	# /vendor/bin/audioadsprpcd audiopd adsp, uses the same
	# /dev/fastrpc-adsp-secure node, also runs pd-mapper, and its card is
	# "sun-mtp-snd-card" - the same machine driver we load.
	#
	# Remaining blocker: adsp_loader still refuses -
	#   adsp-loader: adsp_load_fw: ADSP state = 0
	#   adsp-loader: adsp_load_fw: failed to read adsp state
	#   adsp-loader: adsp_load_fw: Q6 image loading failed
	# so the audio PD never starts and no card registers.
	mount_vendor
	[ -e /vendor ] || ln -s /mnt/vendor /vendor

	# ADSP firmware from apnhlos, if not already staged.
	if [ ! -f /lib/firmware/adsp.mdt ] || [ ! -f /lib/firmware/adsp_dtb.mdt ]; then
		mkdir -p /mnt/apn
		mountpoint -q /mnt/apn || mount -o ro /dev/disk/by-partlabel/apnhlos_a /mnt/apn
		cp -f /mnt/apn/image/adsp.* /mnt/apn/image/adsp_dtb.* /lib/firmware/ 2>/dev/null
		cp -f /mnt/apn/image/*.jsn /lib/firmware/ 2>/dev/null
		log "adsp firmware + pd maps installed"
	fi

	# The DSP looks for its modules under /vendor/dsp.
	mountpoint -q /mnt/vendor/dsp ||
		mount -o ro /dev/disk/by-partlabel/dsp_a /mnt/vendor/dsp 2>/dev/null

	# PDR needs pd-mapper serving the maps before the ADSP is asked for a PD.
	pidof pd-mapper >/dev/null 2>&1 || rc-service pd-mapper start >/dev/null 2>&1
	pidof pd-mapper >/dev/null 2>&1 || log "audio: pd-mapper not running"

	if [ "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" != "running" ]; then
		echo start > /sys/class/remoteproc/remoteproc0/state 2>/dev/null
		sleep 8
	fi
	log "adsp: $(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)"

	# Start the audio protection domain. This is the piece Android provides as
	# /vendor/bin/audioadsprpcd audiopd adsp, and without it spf_core never
	# becomes ready. pmos-audiopd holds the fd, so it must keep running.
	if [ -e /dev/fastrpc-adsp-secure ]; then
		pidof pmos-audiopd >/dev/null 2>&1 ||
			rc-service pmos-audiopd start >/dev/null 2>&1
		sleep 2
	fi

	modprobe q6_dlkm 2>/dev/null

	# LPASS power votes FIRST. lpass-cdc takes its lpass_core_hw_vote /
	# lpass_audio_hw_vote clocks once, at probe, and silently runs without
	# them if the provider is not there yet (any devm_clk_get error, even
	# -EPROBE_DEFER, becomes "no vote"). The provider is audio-ext-clk-up in
	# wcd9xxx_dlkm (qcom,audio-ref-clk), which only got loaded later as a
	# machine_dlkm dependency - so whenever fw_devlink had already given up
	# waiting (deferred-probe timeout, ~25 s into boot) lpass-cdc probed
	# unvoted, and the first VA macro register access during card
	# registration reset the SoC (2026-10-03/04 boot loops).
	votes_bound() {
		[ -e /sys/bus/platform/devices/soc:vote_lpass_core_hw/driver ] &&
			[ -e /sys/bus/platform/devices/soc:vote_lpass_audio_hw/driver ]
	}
	if grep -q "^lpass_cdc_dlkm " /proc/modules && ! votes_bound; then
		log "audio: lpass_cdc probed before its LPASS vote clocks existed - NOT registering the card (it would reset the SoC); reboot"
		exit 1
	fi
	modprobe wcd9xxx_dlkm 2>/dev/null
	i=0
	until votes_bound || [ $i -ge 10 ]; do sleep 1; i=$((i + 1)); done
	if ! votes_bound; then
		log "audio: LPASS hw vote clocks not bound - NOT registering the card (it would reset the SoC)"
		exit 1
	fi
	log "audio: LPASS hw vote clocks bound"

	# The LPASS macros supply the DAIs the machine driver links against; the
	# module list does not pull them in on its own.
	for m in lpass_cdc_rx_macro_dlkm lpass_cdc_tx_macro_dlkm \
	         lpass_cdc_va_macro_dlkm swr_dmic_dlkm swr_haptics_dlkm; do
		modprobe "$m" 2>/dev/null
	done

	modprobe machine_dlkm 2>/dev/null

	# Ask the adsprpc driver to bring up the ADSP audio PD. This is what
	# postmarketOS's adsp-audio service does, and it is the mainline equivalent
	# of Android's /vendor/bin/audioadsprpcd audiopd adsp - without some such
	# request the PD is never started and PDR waits forever. It gets us as far
	# as msm_asoc_machine_probe() running and stops the endless
	# "gpr_send_pkt: q6 state is down".
	[ -e /sys/kernel/boot_adsp/boot ] && echo 1 > /sys/kernel/boot_adsp/boot 2>/dev/null
	sleep 5

	# The card will not register on its own: the DT sound node asks for BT
	# audio, whose btfmcodec_dev component we can never produce, so the
	# machine driver defers.  pmos-audio-card.sh drives it past
	# qcom,max_defer_count so it drops those links and registers anyway.
	/usr/local/bin/pmos-audio-card.sh 2>&1 | while read -r l; do log "$l"; done

	if [ -e /proc/asound/cards ] && ! grep -q "no soundcards" /proc/asound/cards; then
		log "audio ready: $(sed -n 1p /proc/asound/cards | tr -s \" \")"
	else
		log "audio INCOMPLETE - no sound card"
	fi
	;;
deadman)
	echo 0 > /sys/module/gh_wdt_tame/parameters/pet 2>/dev/null &&
		log "DEADMAN ARMED - reboots in ~30s unless 'vendor-up.sh alive' runs" ||
		log "no gh_wdt_tame pet parameter in this kernel"
	;;
alive)
	echo 1 > /sys/module/gh_wdt_tame/parameters/pet 2>/dev/null &&
		log "petting resumed" || log "no gh_wdt_tame pet parameter"
	;;
*)
	echo "usage: vendor-up.sh {gpu|modem|display|deadman|alive}" >&2
	exit 2
	;;
esac
