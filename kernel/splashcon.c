// SPDX-License-Identifier: GPL-2.0
/*
 * splashcon - the kernel log, scrolling like a PC text console, rendered into
 * the bootloader's continuous-splash framebuffer on a device with no fbcon
 * and no accessible UART.
 *
 * The Samsung Galaxy S25+ (pa2q / SM8750) leaves the panel scanning out of a
 * known DDR buffer and nothing tears it down until a display driver probes,
 * so we can render into it directly. Address from the device's dtbo:
 *
 *	splash_memory: splash_region {
 *		reg = <0x00 0xfc800000 0x00 0x2b00000>;
 *		label = "cont_splash_region";
 *	};
 *
 * 1. It has no "no-map", so the region stays in the kernel linear map, and
 *    ioremap() is NOT usable (arm64 WARNs and returns NULL for
 *    pfn_is_map_memory()). We use phys_to_virt().
 *
 * 2. Through the cacheable linear map the display controller does not see
 *    our stores until they are cleaned to the point of coherency - hence
 *    dcache_clean_poc() after every update.
 *
 * This is deliberately NOT a struct console. A console's write() runs under
 * console_lock from whoever calls printk; the slow qcom_geni UART console once
 * livelocked console_lock under a Wi-Fi printk flood. Instead a kthread reads
 * the printk ring buffer with kmsg_dump_get_line() (lockless) and redraws at
 * most every FRAME_MS, so printk never waits on us and console_loglevel
 * (lowered by userspace for the UART's sake) does not hide anything here.
 *
 * The region stops being ours once the display driver hands it back to the
 * page allocator after its first real commit (free_reserved_page() in SDE's
 * _sde_kms_release_shared_buffer): msm_drm calls splashcon_stop() (looked up
 * with symbol_get()) right before freeing, and as a second guard every frame
 * checks the region is still PageReserved. From there userspace carries on
 * (pa2q-bootlog, on DRM).
 */

#include <linux/delay.h>
#include <linux/export.h>
#include <linux/font.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/kmsg_dump.h>
#include <linux/kthread.h>
#include <linux/mm.h>
#include <linux/pfn.h>
#include <linux/string.h>
#include <linux/types.h>

#include <asm/cacheflush.h>

/*
 * The region is laid out for 1440x3200 (qcom,mdss-dsi-panel-width/-height),
 * but the mode the bootloader scans out, and msm_drm adopts, is 1440x3120.
 */
#define SPLASH_PHYS		0xfc800000UL
#define SPLASH_SIZE		0x02b00000UL
#define FB_WIDTH		1440
#define FB_HEIGHT		3200
#define FB_VISIBLE_HEIGHT	3120
#define FB_STRIDE		(FB_WIDTH * 4)
#define FB_USED_BYTES		((size_t)FB_STRIDE * FB_HEIGHT)

/*
 * Text runs in landscape, like the greeter and Plasma ("left"): landscape
 * pixel (lx, ly) is panel pixel (ly, LAND_W - 1 - lx).
 */
#define LAND_W			FB_VISIBLE_HEIGHT
#define LAND_H			FB_WIDTH
#define SCALE			3		/* VGA 8x16 -> 24x48 cells */
#define CELL_W			(8 * SCALE)
#define CELL_H			(16 * SCALE)
#define MARGIN			8
#define COLS			((LAND_W - 2 * MARGIN) / CELL_W)
#define ROWS			((LAND_H - 2 * MARGIN) / CELL_H)
#define FRAME_MS		33
#define MAX_LEVEL		6		/* show up to KERN_INFO, like loglevel=7 */

#define COL_BG			0xff000000u
#define COL_TEXT		0xffaaaaaau
#define COL_WARN		0xffffff55u
#define COL_ERR			0xffff5555u

static u32 *splash_fb;
static const struct font_desc *font;
static struct task_struct *log_task;

/* Ring of text rows; row (top + i) % ROWS is the i-th on screen. */
static char text[ROWS][COLS];
static u32 colour[ROWS];
static unsigned int top, cur_row, cur_col;

static void flush_rows(unsigned int y0, unsigned int y1)
{
	dcache_clean_poc((unsigned long)splash_fb + (size_t)y0 * FB_STRIDE,
			 (unsigned long)splash_fb + (size_t)y1 * FB_STRIDE);
}

static bool region_ours(void)
{
	return PageReserved(pfn_to_page(PHYS_PFN(SPLASH_PHYS))) &&
	       PageReserved(pfn_to_page(PHYS_PFN(SPLASH_PHYS + FB_USED_BYTES - 1)));
}

static void new_line(u32 col)
{
	if (cur_row + 1 < ROWS) {
		cur_row++;
	} else {
		top = (top + 1) % ROWS;	/* scroll: oldest row becomes the new one */
	}
	cur_col = 0;
	memset(text[(top + cur_row) % ROWS], ' ', COLS);
	colour[(top + cur_row) % ROWS] = col;
}

/* "<6>[    1.234567] msg\n", possibly several lines, each with a prefix. */
static void add_record(const char *s, size_t n)
{
	const char *end = s + n;
	u32 col = COL_TEXT;

	while (s < end) {
		int lvl = 7;

		if (s + 2 < end && s[0] == '<' && s[2] == '>' &&
		    s[1] >= '0' && s[1] <= '7') {
			lvl = s[1] - '0';
			s += 3;
		}
		col = lvl <= 3 ? COL_ERR : lvl == 4 ? COL_WARN : COL_TEXT;
		for (; s < end && *s != '\n'; s++) {
			if (lvl > MAX_LEVEL)
				continue;
			if (cur_col == COLS)
				new_line(col);
			text[(top + cur_row) % ROWS][cur_col++] =
				(*s >= 32 && *s < 127) ? *s : '?';
			colour[(top + cur_row) % ROWS] = col;
		}
		if (s < end)
			s++;			/* the '\n' */
		if (lvl <= MAX_LEVEL)
			new_line(COL_TEXT);
	}
}

static void draw_row(unsigned int r)
{
	const char *t = text[(top + r) % ROWS];
	u32 fg = colour[(top + r) % ROWS];
	unsigned int ly0 = MARGIN + r * CELL_H, lx, gy;

	for (lx = 0; lx < COLS * CELL_W; lx++) {
		unsigned int c = lx / CELL_W, bit = 0x80 >> ((lx % CELL_W) / SCALE);
		const u8 *glyph = (const u8 *)font->data + (unsigned char)t[c] * 16;
		u32 *px = splash_fb + (size_t)(LAND_W - 1 - (MARGIN + lx)) * FB_WIDTH + ly0;

		for (gy = 0; gy < CELL_H; gy++)
			px[gy] = (glyph[gy / SCALE] & bit) ? fg : COL_BG;
	}
}

static int log_thread(void *unused)
{
	static char buf[1024];
	struct kmsg_dump_iter iter = { 0 };	/* get_line clamps to the oldest */
	size_t len;

	while (!kthread_should_stop()) {
		bool got = false;
		unsigned int r;

		while (kmsg_dump_get_line(&iter, true, buf, sizeof(buf), &len)) {
			add_record(buf, len);
			got = true;
		}
		if (got && region_ours()) {
			for (r = 0; r < ROWS; r++)
				draw_row(r);
			flush_rows(0, FB_VISIBLE_HEIGHT);
		}
		if (!region_ours())
			break;
		msleep(FRAME_MS);
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
	if (log_task) {
		kthread_stop(log_task);
		log_task = NULL;
	}
	splash_fb = NULL;
}
EXPORT_SYMBOL_GPL(splashcon_stop);

static int __init splashcon_init(void)
{
	unsigned int r;

	BUILD_BUG_ON(FB_USED_BYTES > SPLASH_SIZE);

	/*
	 * phys_to_virt() is only meaningful for memory in the linear map. If the
	 * region is not (wrong address, a no-map carve-out, another board
	 * revision), touching it would fault with nothing on screen to say so.
	 */
	if (!pfn_valid(__phys_to_pfn(SPLASH_PHYS)) ||
	    !pfn_valid(__phys_to_pfn(SPLASH_PHYS + FB_USED_BYTES - 1))) {
		pr_warn("splashcon: %#lx not in the linear map, not drawing\n",
			SPLASH_PHYS);
		return 0;
	}
	font = find_font("VGA8x16");
	if (!font || font->width != 8 || font->height != 16)
		return 0;

	for (r = 0; r < ROWS; r++) {
		memset(text[r], ' ', COLS);
		colour[r] = COL_TEXT;
	}
	splash_fb = phys_to_virt(SPLASH_PHYS);
	memset32(splash_fb, COL_BG, (size_t)FB_WIDTH * FB_HEIGHT);
	flush_rows(0, FB_HEIGHT);

	log_task = kthread_run(log_thread, NULL, "splashcon");
	if (IS_ERR(log_task))
		log_task = NULL;
	return 0;
}
/* kthreads cannot be created at console_initcall time. */
early_initcall(splashcon_init);
