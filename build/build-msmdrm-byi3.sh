#!/usr/bin/env bash
# Build msm_drm.ko from the BYI3 (== installed firmware) display-drivers source,
# NO stubs: every cross-module symbol is resolved at load time against the STOCK
# vendor modules already on the phone, versioned via stock-vendor.symvers
# (gen-symvers.py: exports+CRCs of the stock .ko set, minus what the kernel provides).
set -euo pipefail
TOOLCHAIN="${TOOLCHAIN:-$HOME/Desktop/Projects/phone-pmos/toolchains/clang-r510928}"
export PATH="$TOOLCHAIN/bin:$HOME/bin:$PATH"
OUT=$HOME/Desktop/Projects/phone-pmos/k698/out-698ns
MOD=${MOD:-$HOME/Desktop/Projects/phone-pmos/samsung-src-byi3/x/vendor/qcom/opensource/display-drivers}
SYMV=$(dirname "$(readlink -f "$0")")/stock-vendor.symvers
export ARCH=arm64 SUBARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu-
export KCFLAGS="-O2 -pipe -Wno-error -D__ANDROID_COMMON_KERNEL__ -I$(dirname "$(readlink -f "$0")")/inc -include $(dirname "$(readlink -f "$0")")/inc/pa2q_stock_config.h"
export KCPPFLAGS="$KCFLAGS"
# Kbuild picks objects via these make vars (DP, VM, HDCP, cesta...); without them they compile out.
CONFARGS=$(sed -n "s/^export \(CONFIG_[A-Z0-9_]*\)=\(.*\)/\1=\2/p" "$MOD/config/gki_sundisp.conf" | sed "s/^CONFIG_DRM_MSM=y/CONFIG_DRM_MSM=m/" | tr "\n" " ")
# Samsung panel drivers + SECDP are selected by sec_display_defconfig (Bazel/Android.mk feed it in); without it the PA2 panel is never compiled.
CONFARGS="$CONFARGS $(sed -n "s/^\(CONFIG_[A-Z0-9_]*=[ym]\).*/\1/p" "$MOD/sec_display_defconfig" | tr "\n" " ")"
echo "conf args: $CONFARGS"
[ -f "$OUT/Module.symvers" ] || cp "$OUT/vmlinux.symvers" "$OUT/Module.symvers"
make -C "$OUT" M="$MOD" modules \
    ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1 LD=ld.lld HOSTLD=ld.lld \
    AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump OBJSIZE=llvm-size \
    CONFIG_ARCH_SUN=y DISPLAY_ROOT="$MOD" $CONFARGS \
    KBUILD_EXTRA_SYMBOLS="$SYMV" -j"$(nproc)"
ls -l "$MOD/msm/msm_drm.ko"
