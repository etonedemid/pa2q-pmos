# pa2q: GPU-accelerated KWin/Plasma (2026-10-04). Install as
# ~/.config/plasma-workspace/env/pa2q-gpu.sh (sourced before kwin starts).
# The display (downstream SDE msm_drm, DRM name "msm" 1.4) has no GPU, and the
# Adreno is behind KGSL, which is not a DRM device. Mesa bridges them with
# kmsro: scanout buffers are dumb buffers on msm_drm, rendering is zink on
# turnip's KGSL backend. The packaged turnip is built without KGSL, so use the
# KGSL build installed as its own ICD (an apk upgrade cannot overwrite it).
# Older, faster Turnip build (26.0.99, Wayland only). The 26.1.6 build
# (freedreno_kgsl_drm_icd.json) made kwin noticeably slower (2026-10-31).
# This binary is patched with device/turnip-kgsl-sw-wsi-binpatch.py, otherwise
# every Vulkan window crashes in vkCreateSwapchainKHR.
export VK_DRIVER_FILES=/etc/vulkan/icd.d/freedreno_kgsl_icd.json
# The A8xx community Turnip (device/build-turnip-a8xx.sh, Mesa 27) is installed
# as freedreno_a8xx_icd.json but was noticeably slower on the desktop
# (2026-10-31), so it is not the default.
export VK_ICD_FILENAMES=$VK_DRIVER_FILES
export MESA_LOADER_DRIVER_OVERRIDE=kmsro
# Concurrent binning (A7xx+ BV pipe) drops whole triangles on KGSL whenever more
# than one GPU client is busy (kwin overview: half-drawn window quads; black
# pixels in apps). Off for the whole session; apps inherit it (2026-10-31).
export TU_DEBUG=nocb
# Qt Quick inside widgets (QQuickWidget: System Settings pages, kcmshell6)
# renders blank on zink/KGSL: its depth-tested opaque pass rejects everything
# in the offscreen render target. Plain Qt Quick windows are fine. Use the
# painter's-algorithm path instead (2026-10-31).
export QSG_NO_DEPTH_BUFFER=1
