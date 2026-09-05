#!/usr/bin/env bash
# Build on this machine (24 cores). MUST use AOSP clang r510928: kconfig
# cc-option probes differ per compiler, and a distro clang silently drops
# CFI_CLANG / SHADOW_CALL_STACK and flips KASAN_HW_TAGS -> KASAN_GENERIC,
# which breaks the GKI KMI and stops Samsung's prebuilt vendor modules loading.
set -euo pipefail
TOOLCHAIN="${TOOLCHAIN:-$HOME/toolchains/clang-r510928}"
[ -x "$TOOLCHAIN/bin/clang" ] || { echo "ERROR: need AOSP clang at $TOOLCHAIN/bin/clang"; exit 1; }
export PATH="$TOOLCHAIN/bin:$HOME/bin:$PATH"
KROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$KROOT/out-local}"
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu-
export KCFLAGS="-O2 -pipe -Wno-error -D__ANDROID_COMMON_KERNEL__"
export KCPPFLAGS="$KCFLAGS"
MK=(make O="$OUT" ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1 LD=ld.lld HOSTLD=ld.lld
    AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump OBJSIZE=llvm-size)
cd "$KROOT"
[ -e drivers/kernelsu/Kconfig ] || { mkdir -p drivers/kernelsu; echo "# stub" > drivers/kernelsu/Kconfig; : > drivers/kernelsu/Makefile; }
"${MK[@]}" defconfig >/dev/null
for o in CFI_CLANG SHADOW_CALL_STACK KASAN_HW_TAGS SPLASH_CONSOLE; do
  grep -qE "^CONFIG_$o=y" "$OUT/.config" || { echo "ERROR: CONFIG_$o missing"; exit 1; }
done
echo "config OK: mitigations + splashcon present"
"${MK[@]}" -j"$(nproc)" Image
echo "==> $OUT/arch/arm64/boot/Image ($(stat -c%s "$OUT/arch/arm64/boot/Image") bytes)"
