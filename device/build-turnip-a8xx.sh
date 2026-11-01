#!/bin/sh
# Build the community A8xx Turnip (KGSL) natively on the phone, as a Vulkan ICD.
#
# Source recipe: The412Banner/Banners-Turnip, branch A8xx, Linux leg
# (build_turnip_linux.sh with EXTRA_PATCH=patches/a8xx_gen8.patch,
# EXTRA_SCRIPT=patches/a8xx_shared_mem.py) - the same patch stack the Android
# emulator drivers (AdrenoTools / Winlator / DroidDeck) ship for Adreno 830,
# whitebelyash's turnip/gen8 series on current Mesa. Their ZIPs are bionic or
# glibc builds; this rebuilds the same tree against pmOS's musl.
#
# usage: build-turnip-a8xx.sh <Banners-Turnip checkout> [workdir]
# Installs nothing; prints the .so path. pa2q-gpu.sh selects the ICD.
set -eu
REPO=$(cd "${1:?usage: $0 <Banners-Turnip dir> [workdir]}" && pwd)
W=${2:-/root/turnip-a8xx}
HERE=$(cd "$(dirname "$0")" && pwd)
MESA_COMMIT=$(cat "$REPO/mesa_hash.txt")

mkdir -p "$W"
cd "$W"
if [ ! -d mesa/.git ]; then
	git init -q mesa
	git -C mesa remote add origin https://gitlab.freedesktop.org/mesa/mesa.git
fi
cd mesa
git fetch -q --depth=1 origin "$MESA_COMMIT"
git checkout -q -f FETCH_HEAD
git clean -qfdx

p() { echo ">> $1"; patch -p1 -N --fuzz=${2:-3} --no-backup-if-mismatch < "$1"; }

# 1. Linux KGSL fixes (render node naming, no calibrated timestamps on KGSL -
#    the "vkGetCalibratedTimestampsEXT failed" spam under zink)
p "$REPO/patches/linux/kgsl-drm-node.patch"
p "$REPO/patches/linux/kgsl-no-calibrated-timestamps.patch"
# 2. A8xx hang fixes + mesh/wave32 (WinNative 0001-0005), as apply_common.sh does for A8xx
for f in "$REPO"/patches/a8xx-winnative/0*.patch; do p "$f"; done
# 3. the gen8 stack + its script
p "$REPO/patches/a8xx_gen8.patch" 4
python3 "$REPO/patches/a8xx_shared_mem.py"
# 4. pa2q: KGSL cannot round-trip UBWC dmabufs - never advertise the modifier
p "$HERE/turnip-no-ubwc-modifier-on-kgsl.patch"
# 5. pa2q: enabling VK_KHR_display must not hide the GPU (vulkaninfo enables it)
p "$HERE/turnip-kgsl-khr-display-warn.patch"
find . -name '*.rej' | grep -q . && { echo "rejected hunks"; exit 1; }

meson setup build --buildtype=release --prefix=/usr/local \
	-Dvulkan-drivers=freedreno -Dfreedreno-kmds=msm,kgsl -Dgallium-drivers= \
	-Dplatforms=wayland,x11 -Dopengl=false -Dgbm=disabled -Dglx=disabled \
	-Degl=disabled -Dllvm=disabled -Dvulkan-layers= -Dtools= -Dxmlconfig=disabled
ninja -C build src/freedreno/vulkan/libvulkan_freedreno.so
echo "BUILT: $W/mesa/build/src/freedreno/vulkan/libvulkan_freedreno.so ($MESA_COMMIT)"
