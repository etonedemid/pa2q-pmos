#!/usr/bin/env bash
# Rebuild ONLY the msm_drm.ko display module against the running kernel's
# objtree (k698/out-698ns), mirroring build-698-ns.sh's toolchain env.
set -euo pipefail
TOOLCHAIN="${TOOLCHAIN:-$HOME/Desktop/Projects/phone-pmos/toolchains/clang-r510928}"
export PATH="$TOOLCHAIN/bin:$HOME/bin:$PATH"
KROOT=$HOME/Desktop/Projects/phone-pmos/k698
OUT="$KROOT/out-698ns"
MOD=$HOME/Desktop/Projects/phone-pmos/samsung-src/kernel_platform/vendor/qcom/opensource/display-drivers
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu-
export KCFLAGS="-O2 -pipe -Wno-error -D__ANDROID_COMMON_KERNEL__"
export KCPPFLAGS="$KCFLAGS"

# make Image never wrote Module.symvers; modpost for external modules needs it
# to resolve (and version) the kernel's exported symbols. vmlinux.symvers holds
# exactly those, from this same kernel, so the CRCs match the running kernel.
[ -f "$OUT/Module.symvers" ] || cp "$OUT/vmlinux.symvers" "$OUT/Module.symvers"

# Cross-module imports (drm_display_helper, mmrm, sync_fence, ...) aren't in
# vmlinux.symvers; let modpost warn rather than error on them - they resolve at
# load time as unversioned imports (MODVERSIONS allows that).
export KBUILD_MODPOST_WARN=1

make -C "$OUT" \
    M="$MOD" \
    modules \
    ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1 LD=ld.lld HOSTLD=ld.lld \
    AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump OBJSIZE=llvm-size \
    CONFIG_DRM_MSM=m \
    CONFIG_ARCH_SUN=y \
    DISPLAY_ROOT="$MOD" \
    -j"$(nproc)"

echo "=== result ==="
find "$MOD" -name "msm_drm.ko" -exec ls -l {} \;
