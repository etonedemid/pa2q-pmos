// SPDX-License-Identifier: GPL-2.0
/*
 * splashcon - boot splash rendered into the bootloader's continuous-splash
 * framebuffer, for a device with no accessible UART.
 *
 * The Samsung Galaxy S25+ (pa2q / SM8750) routes its debug UART to the USB-C
 * SBU pins behind a 619k jig. Without that hardware an early boot failure is
 * completely silent. The bootloader leaves the panel scanning out of a known
 * DDR buffer and nothing tears it down until a display driver probes, so we
 * can render into it directly.
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
 * This started life as a full console: the kernel log, a per-module progress
 * bar and a row of milestone pips, because for a long time the panel was the
 * only way to find out anything. It is not any more - USB networking works and
 * gives a real root shell, so the log is read over that. What remains is a
 * plain boot splash: the mark, and one line naming the stage underneath it.
 *
 * We still register as a console, but only to watch the log go past: the
 * caption follows the furthest boot milestone reached. Nothing is rendered
 * from the log text itself.
 */

#include <linux/console.h>
#include <linux/font.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/mmzone.h>
#include <linux/pfn.h>
#include <linux/spinlock.h>
#include <linux/string.h>
#include <linux/types.h>

#include <asm/cacheflush.h>

#include "splashcon_logo.h"

/* Panel is 1440x3200: qcom,mdss-dsi-panel-width/-height = <0x5a0>/<0xc80>. */
#define SPLASH_PHYS		0xfc800000UL
#define SPLASH_SIZE		0x02b00000UL
#define FB_WIDTH		1440
#define FB_HEIGHT		3200
#define FB_STRIDE		(FB_WIDTH * 4)
#define FB_USED_BYTES		((size_t)FB_STRIDE * FB_HEIGHT)

#define COL_BG			0xff000000u	/* OLED, so an actual black */
#define COL_DIM			0xff6d6d78u	/* caption grey              */
#define COL_LOGO		0xff009900u	/* #090, the logo's own green */

/* ~500 dpi: an unscaled 8x16 glyph is ~0.4mm and unreadable on a handset. */
#define CAP_SCALE		3
#define CAP_GAP			96		/* logo baseline to caption */

static u32 *splash_fb;
static const struct font_desc *splash_font;
static unsigned int logo_y, cap_y;
static DEFINE_RAW_SPINLOCK(splash_lock);

/*
 * Boot milestones. The caption follows the furthest one reached, so a stall is
 * legible at a glance: whatever it says last is where it stopped.
 */
enum { STEP_PENDING = 0, STEP_OK, STEP_BAD };

static struct splash_step {
	const char *marker;
	const char *caption;
	u8 state;
} splash_steps[] = {
	{ "PMOS STAGE 1",		"starting"		},
	{ "vendor modules:",		"modules loaded"	},
	{ "STORAGE UP",			"storage ready"		},
	{ "STEP fw",			"firmware path"		},
	{ "STEP mdev",			"device nodes"		},
	{ "STEP usbnet",		"usb network"		},
	{ "STEP subparts",		"subpartitions"		},
	{ "Found root partition",	"root found"		},
	{ "STEP mountboot",		"mounting boot"		},
	{ "switch_root",		"starting postmarketOS"	},
	/* Userspace has taken the panel. If this caption appears and then
	 * stays put, the compositor started but never actually took over
	 * scanout - which is exactly the failure we are chasing. */
	{ "PANEL OWNED",		"userspace"		},
};

/* Anything here paints the caption red at the current stage. */
static const char * const splash_bad[] = {
	"STORAGE DOWN", "Kernel panic", "Unable to mount root",
};

#define COL_BAD			0xffe74c3cu

static void splash_flush_rows(unsigned int y0, unsigned int y1)
{
	unsigned long start, end;

	if (y1 > FB_HEIGHT)
		y1 = FB_HEIGHT;
	if (y0 >= y1)
		return;

	start = (unsigned long)splash_fb + (size_t)y0 * FB_STRIDE;
	end   = (unsigned long)splash_fb + (size_t)y1 * FB_STRIDE;
	dcache_clean_poc(start, end);
}

static void splash_fill(unsigned int x0, unsigned int y0,
			unsigned int w, unsigned int h, u32 colour)
{
	unsigned int x, y;
	u32 *line;

	if (x0 + w > FB_WIDTH || y0 + h > FB_HEIGHT)
		return;

	for (y = y0; y < y0 + h; y++) {
		line = splash_fb + (size_t)y * FB_WIDTH + x0;
		for (x = 0; x < w; x++)
			line[x] = colour;
	}
}

/* ---------------------------------------------------------------- caption */

static void splash_text_at(unsigned int x, unsigned int y, const char *str,
			   u32 colour)
{
	unsigned int gx, gy, sx, sy, w, h;
	const u8 *glyph;
	u32 *line;
	u8 bits;

	if (!splash_font)
		return;
	w = splash_font->width;
	h = splash_font->height;

	for (; *str; str++, x += w * CAP_SCALE) {
		if (x + w * CAP_SCALE > FB_WIDTH)
			return;
		glyph = (const u8 *)splash_font->data +
			(unsigned char)*str * h;
		for (gy = 0; gy < h; gy++) {
			bits = glyph[gy];
			for (sy = 0; sy < CAP_SCALE; sy++) {
				if (y + gy * CAP_SCALE + sy >= FB_HEIGHT)
					return;
				line = splash_fb +
				       (size_t)(y + gy * CAP_SCALE + sy) *
				       FB_WIDTH + x;
				for (gx = 0; gx < w; gx++)
					for (sx = 0; sx < CAP_SCALE; sx++)
						line[gx * CAP_SCALE + sx] =
							(bits & (0x80 >> gx)) ?
							colour : COL_BG;
			}
		}
	}
}

/* One centred line, redrawn in place. */
static void splash_draw_caption(const char *str, u32 colour)
{
	unsigned int cw = splash_font->width * CAP_SCALE;
	unsigned int ch = splash_font->height * CAP_SCALE;
	unsigned int len = strlen(str);
	unsigned int x;

	if (len * cw > FB_WIDTH)
		len = FB_WIDTH / cw;
	x = (FB_WIDTH - len * cw) / 2;

	splash_fill(0, cap_y, FB_WIDTH, ch, COL_BG);
	splash_text_at(x, cap_y, str, colour);
	splash_flush_rows(cap_y, cap_y + ch);
}

/* ------------------------------------------------------------- milestones */

/* strstr over a console record, which is not NUL-terminated */
static bool splash_has(const char *hay, unsigned int n, const char *needle)
{
	unsigned int nl = strlen(needle);
	unsigned int i;

	if (!nl || n < nl)
		return false;
	for (i = 0; i + nl <= n; i++)
		if (!memcmp(hay + i, needle, nl))
			return true;
	return false;
}

static void splash_track(const char *s, unsigned int n)
{
	unsigned int i;
	bool changed = false;

	for (i = 0; i < ARRAY_SIZE(splash_steps); i++) {
		if (splash_steps[i].state == STEP_PENDING &&
		    splash_has(s, n, splash_steps[i].marker)) {
			splash_steps[i].state = STEP_OK;
			changed = true;
		}
	}

	for (i = 0; i < ARRAY_SIZE(splash_bad); i++) {
		if (!splash_has(s, n, splash_bad[i]))
			continue;
		for (i = ARRAY_SIZE(splash_steps); i-- > 0; ) {
			if (splash_steps[i].state == STEP_OK) {
				splash_draw_caption(splash_steps[i].caption,
						    COL_BAD);
				return;
			}
		}
		splash_draw_caption("failed", COL_BAD);
		return;
	}

	if (!changed)
		return;

	for (i = ARRAY_SIZE(splash_steps); i-- > 0; ) {
		if (splash_steps[i].state == STEP_OK) {
			splash_draw_caption(splash_steps[i].caption, COL_DIM);
			return;
		}
	}
}

static void splash_write(struct console *con, const char *s, unsigned int n)
{
	unsigned long flags;

	if (!splash_fb || !splash_font)
		return;

	raw_spin_lock_irqsave(&splash_lock, flags);
	splash_track(s, n);
	raw_spin_unlock_irqrestore(&splash_lock, flags);
}

static struct console splash_console = {
	.name	= "splash",
	.write	= splash_write,
	.flags	= CON_PRINTBUFFER | CON_ENABLED | CON_ANYTIME | CON_EXTENDED,
	.index	= -1,
};

/* ------------------------------------------------------------------- init */

/*
 * Decode the RLE coverage map and alpha-blend the mark onto the background.
 * Blending rather than thresholding is what keeps the diagonals smooth; at
 * this pixel density a 1-bit mask is visibly stepped.
 */
static void __init splash_draw_logo(void)
{
	unsigned int ox = (FB_WIDTH - PM_LOGO_W) / 2;
	unsigned int idx = 0;
	size_t i;

	if (ox + PM_LOGO_W > FB_WIDTH || logo_y + PM_LOGO_H > FB_HEIGHT)
		return;

	for (i = 0; i + 1 < ARRAY_SIZE(pm_logo_rle); i += 2) {
		u8 a = pm_logo_rle[i];
		unsigned int run = pm_logo_rle[i + 1];

		while (run--) {
			unsigned int x = idx % PM_LOGO_W;
			unsigned int y = idx / PM_LOGO_W;
			u32 *px;

			idx++;
			if (y >= PM_LOGO_H)
				return;
			if (!a)
				continue;

			px = splash_fb + (size_t)(logo_y + y) * FB_WIDTH + ox + x;
			if (a == 0xff) {
				*px = COL_LOGO;
				continue;
			}
			/* src over dst, dst is black, so just scale. */
			*px = 0xff000000u |
			      ((((COL_LOGO >> 16) & 0xff) * a / 255) << 16) |
			      ((((COL_LOGO >>  8) & 0xff) * a / 255) <<  8) |
			      ((((COL_LOGO      ) & 0xff) * a / 255));
		}
	}
}

static int __init splashcon_init(void)
{
	unsigned int cap_h, block_h;

	BUILD_BUG_ON(FB_USED_BYTES > SPLASH_SIZE);

	splash_font = find_font("VGA8x16");
	if (!splash_font)
		splash_font = &font_vga_8x16;

	/*
	 * phys_to_virt() is only meaningful for memory in the linear map. If
	 * the splash region is not - wrong address, a no-map carve-out, a
	 * different board revision - dereferencing it would fault here at
	 * console_init with no console yet registered to report it: a silent
	 * bootloop. Refuse instead of taking the kernel down.
	 */
	if (!pfn_valid(__phys_to_pfn(SPLASH_PHYS)) ||
	    !pfn_valid(__phys_to_pfn(SPLASH_PHYS + FB_USED_BYTES - 1))) {
		pr_warn("splashcon: %#lx not in the linear map, not registering\n",
			SPLASH_PHYS);
		return 0;
	}

	splash_fb = phys_to_virt(SPLASH_PHYS);

	/* Centre the mark-and-caption block on the panel as a whole. */
	cap_h   = splash_font->height * CAP_SCALE;
	block_h = PM_LOGO_H + CAP_GAP + cap_h;
	logo_y  = (FB_HEIGHT - block_h) / 2;
	cap_y   = logo_y + PM_LOGO_H + CAP_GAP;

	splash_fill(0, 0, FB_WIDTH, FB_HEIGHT, COL_BG);
	splash_draw_logo();
	splash_flush_rows(0, FB_HEIGHT);
	splash_draw_caption("starting", COL_DIM);

	register_console(&splash_console);
	return 0;
}
console_initcall(splashcon_init);
