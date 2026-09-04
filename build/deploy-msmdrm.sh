#!/usr/bin/env bash
# Build msm_drm.ko, strip, push to device, swap in, depmod, reboot, wait.
set -euo pipefail
SCR=/tmp/claude-1000/-home-etonedemid-android-kernel-samsung-sm8750-sysvipc/d8904cf2-44e0-4ae9-bfd3-970b8ee8a055/scratchpad
STRIP=/home/etonedemid/toolchains/clang-r510928/bin/llvm-strip
MOD=/home/etonedemid/samsung-src/kernel_platform/vendor/qcom/opensource/display-drivers/msm/msm_drm.ko

echo "### BUILD"
bash "$SCR/build-msmdrm.sh" 2>&1 | grep -vE "^  (CC|LD|AR|GEN|WRAP|BTF|MODPOST) |WARNING: modpost|suppressed" | tail -6
[ -f "$MOD" ] || { echo "BUILD FAILED (no .ko)"; exit 1; }

echo "### STRIP + PUSH"
cp "$MOD" /tmp/msm_drm-new.ko
$STRIP --strip-debug /tmp/msm_drm-new.ko
ls -l /tmp/msm_drm-new.ko | awk '{print "  ko size:", $5}'
scp -o ConnectTimeout=10 -q /tmp/msm_drm-new.ko pa2w:/tmp/msm_drm-new.ko

echo "### SWAP + DEPMOD + REBOOT"
ssh -o ConnectTimeout=10 pa2w 'timeout 30 sh -c "M=/lib/modules/\$(uname -r)/vendor/msm_drm.ko; cp /tmp/msm_drm-new.ko \$M && depmod -a 2>/dev/null; sync; nohup reboot >/dev/null 2>&1 &"; echo reboot-issued'

echo "### WAIT FOR BOOT"
for i in $(seq 1 20); do sleep 6; ssh -o ConnectTimeout=5 -o BatchMode=yes pa2w 'echo alive' >/dev/null 2>&1 && { echo "  UP ~$((i*6))s"; break; }; done
