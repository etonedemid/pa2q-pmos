// SPDX-License-Identifier: GPL-2.0
/*
 * splashcon - boot splash rendered into the bootloader's continuous-splash
 * framebuffer, for a device with no accessible UART.
 *
 * The Samsung Galaxy S25+ (pa2q / SM8750) routes its debug UART to the USB-C
 * SBU pins behind a 619k jig. The bootloader leaves the panel scanning out of a
 * known DDR buffer and nothing tears it down until a display driver probes, so
 * we can render into it directly.
 *
 * Address comes from the device's own dtbo overlay:
 *
 *	splash_memory: splash_region {
 *		reg = <0x00 0xfc800000 0x00 0x2b00000>;
 *		label = "cont_splash_region";
 *	};
 *
 * Two properties of that node drive the implementation:
 *
 * 1. It has no "no-map", so the region stays in the kernel linear map, and
 *    ioremap() is therefore NOT usable - arch/arm64/mm/ioremap.c WARNs and
 *    returns NULL for pfn_is_map_memory(). (This is also why simplefb cannot
 *    drive this buffer: its probe uses devm_ioremap_wc().) We use
 *    phys_to_virt() instead.
 *
 * 2. Reaching it through the cacheable linear map means the display
 *    controller, which reads DDR directly, will not see our stores until they
 *    are cleaned to the point of coherency - hence dcache_clean_poc() after
 *    every update.
 *
 * This started life as a full console (kernel log, progress bar, milestone
 * captions), because for a long time the panel was the only way to find out
 * anything. USB networking gives a real shell now, so all that is left is the
 * postmarketOS mark, centred and spinning clockwise about its own centroid.
 *
 * The spinner is a kthread (from early_initcall: none can be created at
 * console_initcall time). The splash region stops being ours once the display
 * driver hands it back to the page allocator after its first real commit
 * (free_reserved_page() in SDE's _sde_kms_release_shared_buffer), so every
 * write here must end before that: msm_drm calls splashcon_stop() (looked up
 * with symbol_get(), so old kernels without it still work) right before
 * freeing, and as a second guard the spinner checks the region is still
 * PageReserved before every frame.
 */

#include <linux/delay.h>
#include <linux/export.h>
#include <linux/fixp-arith.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/kthread.h>
#include <linux/math64.h>
#include <linux/mm.h>
#include <linux/mmzone.h>
#include <linux/pfn.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/types.h>

#include <asm/cacheflush.h>

#include "splashcon_logo.h"

/*
 * The region is laid out for 1440x3200 (qcom,mdss-dsi-panel-width/-height),
 * but the mode the bootloader scans out, and msm_drm adopts, is 1440x3120:
 * centre on the visible part.
 */
#define SPLASH_PHYS		0xfc800000UL
#define SPLASH_SIZE		0x02b00000UL
#define FB_WIDTH		1440
#define FB_HEIGHT		3200
#define FB_VISIBLE_HEIGHT	3120
#define FB_STRIDE		(FB_WIDTH * 4)
#define FB_USED_BYTES		((size_t)FB_STRIDE * FB_HEIGHT)

#define COL_BG			0xff000000u	/* OLED, so an actual black */
#define COL_LOGO		0xff009900u	/* #090, the logo's own green */

#define SPIN_DEG_STEP		3		/* per frame, clockwise   */
#define SPIN_FRAME_MS		40		/* ~25 fps                */
#define SPIN_MAX_S		120		/* give up spinning after  */

static u32 *splash_fb;
static u8 *logo_cov;			/* PM_LOGO_W x PM_LOGO_H coverage */
static s32 piv_x, piv_y;		/* centroid in the map, 16.16    */
static unsigned int scr_x, scr_y, spin_r;	/* where it goes, swept radius */
static struct task_struct *spin_task;

static void splash_flush_rows(unsigned int y0, unsigned int y1)
{
	if (y1 > FB_HEIGHT)
		y1 = FB_HEIGHT;
	if (y0 >= y1)
		return;
	dcache_clean_poc((unsigned long)splash_fb + (size_t)y0 * FB_STRIDE,
			 (unsigned long)splash_fb + (size_t)y1 * FB_STRIDE);
}

static u32 splash_logo_px(unsigned int a)
{
	/* src over dst, dst is black, so just scale. */
	return 0xff000000u |
	       ((((COL_LOGO >> 16) & 0xff) * a / 255) << 16) |
	       ((((COL_LOGO >>  8) & 0xff) * a / 255) <<  8) |
	       ((((COL_LOGO      ) & 0xff) * a / 255));
}

static unsigned int splash_cov(int x, int y)
{
	if (x < 0 || y < 0 || x >= PM_LOGO_W || y >= PM_LOGO_H)
		return 0;
	return logo_cov[y * PM_LOGO_W + x];
}

/*
 * Draw the mark turned clockwise by deg (screen y points down) about its
 * centroid, sampling the coverage map bilinearly in 16.16 fixed point. Only
 * the circle the mark sweeps is touched; outside it stays background.
 */
static void splash_render_logo(unsigned int deg)
{
	s32 c = fixp_cos32(deg) >> 15, s = fixp_sin32(deg) >> 15;	/* 16.16 */
	int r = spin_r, dx, dy;

	for (dy = -r; dy <= r; dy++) {
		u32 *line = splash_fb + (size_t)(scr_y + dy) * FB_WIDTH + scr_x;
		int span = int_sqrt(r * r - dy * dy);
		/* source = R(-deg) * dest, about the centroid */
		s32 fx = c * -span + s * dy + piv_x - (1 << 15);
		s32 fy = -s * -span + c * dy + piv_y - (1 << 15);

		for (dx = -span; dx <= span; dx++, fx += c, fy -= s) {
			int x0 = fx >> 16, y0 = fy >> 16;
			unsigned int ax = (fx >> 8) & 0xff, ay = (fy >> 8) & 0xff;
			unsigned int top = splash_cov(x0, y0) * (256 - ax) + splash_cov(x0 + 1, y0) * ax;
			unsigned int bot = splash_cov(x0, y0 + 1) * (256 - ax) + splash_cov(x0 + 1, y0 + 1) * ax;
			unsigned int a = (top * (256 - ay) + bot * ay) >> 16;

			line[dx] = a ? splash_logo_px(a) : COL_BG;
		}
	}
	splash_flush_rows(scr_y - r, scr_y + r + 1);
}

static bool splash_region_ours(void)
{
	return PageReserved(pfn_to_page(PHYS_PFN(SPLASH_PHYS))) &&
	       PageReserved(pfn_to_page(PHYS_PFN(SPLASH_PHYS + FB_USED_BYTES - 1)));
}

static int splash_spin(void *unused)
{
	unsigned long end = jiffies + SPIN_MAX_S * HZ;
	unsigned int deg = 0;

	while (!kthread_should_stop() && time_before(jiffies, end) &&
	       splash_region_ours()) {
		deg = (deg + SPIN_DEG_STEP) % 360;
		splash_render_logo(deg);
		msleep(SPIN_FRAME_MS);
	}
	/* Stay until stopped, so kthread_stop() never sees a freed task. */
	while (!kthread_should_stop())
		msleep(1000);
	return 0;
}

/*
 * Called by msm_drm right before it frees the splash region: no write into
 * it may happen after this returns.
 */
void splashcon_stop(void)
{
	if (spin_task) {
		kthread_stop(spin_task);
		spin_task = NULL;
	}
	splash_fb = NULL;
	kfree(logo_cov);
	logo_cov = NULL;
}
EXPORT_SYMBOL_GPL(splashcon_stop);

static int __init splashcon_spin_init(void)
{
	if (splash_fb && logo_cov)
		spin_task = kthread_run(splash_spin, NULL, "splashcon");
	if (IS_ERR(spin_task))
		spin_task = NULL;
	return 0;
}
early_initcall(splashcon_spin_init);

/* ------------------------------------------------------------------- init */

/*
 * Decode the RLE coverage map (kept for the spinner; the RLE is __initconst)
 * and find the mark's centroid, so it spins about its own middle rather than
 * the middle of the square it was drawn in.
 */
static bool __init splash_decode_logo(void)
{
	unsigned int idx = 0, x, y, r2 = 0;
	u64 sum = 0, sx = 0, sy = 0;
	size_t i;

	logo_cov = kzalloc(PM_LOGO_W * PM_LOGO_H, GFP_NOWAIT);
	if (!logo_cov)
		return false;
	for (i = 0; i + 1 < ARRAY_SIZE(pm_logo_rle); i += 2) {
		unsigned int run = pm_logo_rle[i + 1];

		while (run-- && idx < PM_LOGO_W * PM_LOGO_H)
			logo_cov[idx++] = pm_logo_rle[i];
	}
	for (y = 0; y < PM_LOGO_H; y++)
		for (x = 0; x < PM_LOGO_W; x++) {
			unsigned int a = logo_cov[y * PM_LOGO_W + x];

			sum += a;
			sx += (u64)a * x;
			sy += (u64)a * y;
		}
	if (!sum)
		return false;
	/* centroid, 16.16, at pixel centres */
	piv_x = (s32)div64_u64((sx << 16) + (sum << 15), sum);
	piv_y = (s32)div64_u64((sy << 16) + (sum << 15), sum);

	/* radius the mark sweeps about that point */
	for (y = 0; y < PM_LOGO_H; y++)
		for (x = 0; x < PM_LOGO_W; x++)
			if (logo_cov[y * PM_LOGO_W + x]) {
				int dx = (int)x - (piv_x >> 16), dy = (int)y - (piv_y >> 16);

				r2 = max_t(unsigned int, r2, dx * dx + dy * dy);
			}
	spin_r = int_sqrt(r2) + 2;
	return true;
}

static int __init splashcon_init(void)
{
	BUILD_BUG_ON(FB_USED_BYTES > SPLASH_SIZE);

	/*
	 * phys_to_virt() is only meaningful for memory in the linear map. If
	 * the splash region is not - wrong address, a no-map carve-out, a
	 * different board revision - dereferencing it would fault here with
	 * nothing on screen to report it: a silent bootloop. Refuse instead of
	 * taking the kernel down.
	 */
	if (!pfn_valid(__phys_to_pfn(SPLASH_PHYS)) ||
	    !pfn_valid(__phys_to_pfn(SPLASH_PHYS + FB_USED_BYTES - 1))) {
		pr_warn("splashcon: %#lx not in the linear map, not drawing\n",
			SPLASH_PHYS);
		return 0;
	}
	if (!splash_decode_logo())
		return 0;
	if (2 * spin_r + 1 > FB_WIDTH || 2 * spin_r + 1 > FB_VISIBLE_HEIGHT)
		return 0;

	splash_fb = phys_to_virt(SPLASH_PHYS);
	scr_x = FB_WIDTH / 2;
	scr_y = FB_VISIBLE_HEIGHT / 2;

	memset32(splash_fb, COL_BG, (size_t)FB_WIDTH * FB_HEIGHT);
	splash_flush_rows(0, FB_HEIGHT);
	splash_render_logo(0);
	return 0;
}
console_initcall(splashcon_init);
