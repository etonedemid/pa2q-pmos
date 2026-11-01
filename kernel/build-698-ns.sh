#!/usr/bin/env bash
# build-698.sh plus the namespace options flatpak needs, and a KMI check.
#
# CONFIG_USER_NS adds a field to struct cred and CONFIG_PID_NS changes nsproxy,
# so both are exactly the kind of change that can shift a CRC in
# android/abi_gki_aarch64_galaxy - the 269 symbols Samsung's prebuilt vendor
# modules bind against. If any of those CRCs move, the modules refuse to load,
# and ufs_qcom is one of them: that is a device with no rootfs. So this builds
# and then diffs CRCs against a baseline before anything gets flashed.
set -euo pipefail
TOOLCHAIN="${TOOLCHAIN:-$HOME/Desktop/Projects/phone-pmos/toolchains/clang-r510928}"
[ -x "$TOOLCHAIN/bin/clang" ] || { echo "ERROR: need AOSP clang at $TOOLCHAIN/bin/clang"; exit 1; }
export PATH="$TOOLCHAIN/bin:$HOME/bin:$PATH"
KROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$KROOT/out-698ns}"
BASELINE="${BASELINE:-$KROOT/out-698/vmlinux.symvers}"
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu-
export KCFLAGS="-O2 -pipe -Wno-error -D__ANDROID_COMMON_KERNEL__"
export KCPPFLAGS="$KCFLAGS"
MK=(make O="$OUT" ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1 LD=ld.lld HOSTLD=ld.lld
    AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump OBJSIZE=llvm-size)
cd "$KROOT"
[ -e drivers/kernelsu/Kconfig ] || { mkdir -p drivers/kernelsu; echo "# stub" > drivers/kernelsu/Kconfig; : > drivers/kernelsu/Makefile; }
"${MK[@]}" defconfig >/dev/null
# DMABUF_HEAPS_SYSTEM: turnip's KGSL backend opens /dev/dma_heap/system (or
# /dev/ion) to allocate exportable memory. Without it VK_KHR_external_memory_fd
# is unavailable, so zink cannot allocate dmabuf-backed images and every WebKit
# page fails with "couldn't allocate memory: heap=0". The qcom_dma_heaps module
# only registers qcom,* heaps - the generic system heap is a separate option.
# DYNAMIC_DEBUG / FW_LOADER_DEBUG: the running kernel has them, and stock
# vendor modules built against it may call __dynamic_pr_debug & co.
./scripts/config --file "$OUT/.config" -e USER_NS -e PID_NS -e DMABUF_HEAPS_SYSTEM -e DYNAMIC_DEBUG -e FW_LOADER_DEBUG
"${MK[@]}" olddefconfig >/dev/null
for o in USER_NS PID_NS DMABUF_HEAPS_SYSTEM DYNAMIC_DEBUG CFI_CLANG SHADOW_CALL_STACK KASAN_HW_TAGS SPLASH_CONSOLE; do
  grep -qE "^CONFIG_$o=y" "$OUT/.config" || { echo "ERROR: CONFIG_$o missing"; exit 1; }
done
echo "config OK: namespaces + dmabuf system heap + mitigations + splashcon present"
"${MK[@]}" -j"$(nproc)" Image
echo "==> $OUT/arch/arm64/boot/Image ($(stat -c%s "$OUT/arch/arm64/boot/Image") bytes)"

# Compare vmlinux.symvers, not Module.symvers: `make Image` never writes the
# latter, and a missing file here silently produces an empty diff that reads as
# "KMI intact" when nothing was actually compared. LC_ALL=C because sort and
# join must agree on collation or join bails out partway with the same effect.
echo "=== KMI check against $BASELINE ==="
export LC_ALL=C
NEW="$OUT/vmlinux.symvers"
[ -s "$BASELINE" ] || { echo "ERROR: baseline $BASELINE missing/empty"; exit 3; }
[ -s "$NEW" ]      || { echo "ERROR: $NEW missing/empty"; exit 3; }
awk '{print $1}' "$KROOT/android/abi_gki_aarch64_galaxy" | grep -E '^[a-zA-Z_][a-zA-Z0-9_]*$' | sort -u > /tmp/kmi-syms.txt
awk '{print $2, $1}' "$BASELINE" | sort -k1,1 > /tmp/kmi-base.txt
awk '{print $2, $1}' "$NEW"      | sort -k1,1 > /tmp/kmi-new.txt
join -j 1 /tmp/kmi-base.txt /tmp/kmi-new.txt > /tmp/kmi-joined.txt
awk '$2 != $3 {print $1, $2, $3}' /tmp/kmi-joined.txt | sort -k1,1 > /tmp/kmi-alldiff.txt
join -j 1 /tmp/kmi-syms.txt /tmp/kmi-alldiff.txt > /tmp/kmi-galaxydiff.txt
COMPARED=$(wc -l < /tmp/kmi-joined.txt)
[ "$COMPARED" -gt 10000 ] || { echo "ERROR: only $COMPARED symbols compared - check is not meaningful"; exit 3; }
echo "symbols compared   : $COMPARED"
echo "galaxy KMI symbols : $(join -j 1 /tmp/kmi-syms.txt /tmp/kmi-base.txt | wc -l) of $(wc -l < /tmp/kmi-syms.txt) present"
echo "CRC changes (all)  : $(wc -l < /tmp/kmi-alldiff.txt)"
echo "CRC MISMATCHES     : $(wc -l < /tmp/kmi-galaxydiff.txt)"
# Symbols the baseline exports but this build does not: a join only compares
# what both have, so a dropped export would otherwise pass as "intact".
awk '{print $2}' "$BASELINE" | sort -u > /tmp/kmi-base-names.txt
awk '{print $2}' "$NEW" | sort -u > /tmp/kmi-new-names.txt
comm -23 /tmp/kmi-base-names.txt /tmp/kmi-new-names.txt > /tmp/kmi-dropped.txt
echo "EXPORTS DROPPED    : $(wc -l < /tmp/kmi-dropped.txt)"
if [ -s /tmp/kmi-dropped.txt ]; then
  head -20 /tmp/kmi-dropped.txt
  echo "DO NOT FLASH: exports missing compared to the baseline."
  exit 2
fi
if [ -s /tmp/kmi-galaxydiff.txt ]; then
  echo "--- offending symbols (first 20) ---"
  head -20 /tmp/kmi-galaxydiff.txt
  echo "DO NOT FLASH: vendor modules will refuse to load."
  exit 2
fi
echo "KMI intact - safe to flash."
