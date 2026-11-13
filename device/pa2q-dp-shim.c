/*
 * pa2q-dp-shim: LD_PRELOAD for the vendor agmplay (bionic, /opt/adroot) to play
 * on DISPLAY_PORT-RX-0. The vendor agmplay has no DisplayPort code, so it never
 * sends PARAM_ID_DISPLAY_PORT_INTF_CFG and the DSP refuses to start the graph
 * ("graph_start failed -131"). The open-source agmplay sets it right before
 * pcm_open; do the same with the vendor libagmmixer's own helpers.
 *
 * No NDK needed, no headers: build with
 *   clang --target=aarch64-linux-android29 -shared -fPIC -nostdlib -O2 \
 *         pa2q-dp-shim.c -o pa2q-dp-shim.so
 * (the symbols resolve from libs agmplay already loads).
 */
typedef unsigned int u32;
struct mixer;
struct pcm;

extern struct mixer *mixer_open(unsigned int card);
extern void mixer_close(struct mixer *mixer);
extern int agm_mixer_get_miid(struct mixer *mixer, int device, char *intf_name,
			      int stype, int tag_id, u32 *miid);
extern int set_agm_device_custom_payload(struct mixer *mixer, char *intf_name,
					 void *payload, unsigned long size);
extern void *dlsym(void *handle, const char *symbol);

#define RTLD_NEXT ((void *)-1L)
#define STREAM_PCM 0
#define DEVICE_HW_ENDPOINT_RX 0xC0000004
#define PARAM_ID_DISPLAY_PORT_INTF_CFG 0x08001154

static char intf[] = "DISPLAY_PORT-RX-0";

struct pcm *pcm_open(unsigned int card, unsigned int device, unsigned int flags,
		     void *config)
{
	struct pcm *(*real)(unsigned int, unsigned int, unsigned int, void *) =
		dlsym(RTLD_NEXT, "pcm_open");
	/* AGM's virtual card only: the plugin opens the real backend PCM too */
	struct mixer *m = card == 100 ? mixer_open(card) : 0;
	u32 miid;

	if (m && !agm_mixer_get_miid(m, device, intf, STREAM_PCM,
				     DEVICE_HW_ENDPOINT_RX, &miid)) {
		/* apm_module_param_data_t + {channel_allocation (0 = stereo),
		 * mst_idx, dptx_idx}, padded to 8 bytes */
		u32 p[8] = { miid, PARAM_ID_DISPLAY_PORT_INTF_CFG, 16, 0, 0, 0, 0, 0 };

		set_agm_device_custom_payload(m, intf, p, sizeof(p));
	}
	if (m)
		mixer_close(m);
	return real(card, device, flags, config);
}
