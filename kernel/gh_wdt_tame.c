// SPDX-License-Identifier: GPL-2.0
/*
 * gh_wdt_tame - keep the Gunyah hypervisor watchdog from resetting the device
 * during postmarketOS bring-up.
 *
 * Background
 * ----------
 * XBL arms a watchdog before Linux starts ("HW Wdog Setting from PCD: Enabled",
 * "ForceKeepAliveHwWdog is enabled"). On Android, gh_virt_wdt.ko registers with
 * qcom_wdt_core and a kernel thread pets it every ~9.5s. That module cannot be
 * used here: its probe warm-resets this device, deterministically, on both
 * 6.6.77 and 6.6.98, with or without delays before loading it. Without it,
 * nothing pets the watchdog and the device resets ~20s into boot.
 *
 * There is no MMIO node to poke - the watchdog lives behind the hypervisor and
 * is only reachable through SMCCC calls. The call IDs below were recovered by
 * disassembling gh_virt_wdt.ko:
 *
 *	gh_disable_wdt : SMC 0x86000005, w1 = 2
 *	gh_enable_wdt  : SMC 0x86000005, w1 = 3
 *	gh_reset_wdt   : SMC 0x86000007, x1 = 0     (this is the "pet")
 *	gh_set_wdt_*   : SMC 0x86000008, w1 = bark, w2 = bite
 *
 * Strategy
 * --------
 * Try to disable outright. If the hypervisor refuses (it may not permit this
 * VM to disable it, and gh_virt_wdt already reports "vWDT already disabled"
 * for the virtual one while the hardware one keeps running), fall back to
 * petting on a timer. Petting an already-disabled watchdog is harmless, so we
 * arm the timer either way rather than trusting the disable return value.
 *
 * This is a BRING-UP AID, not a shipping configuration: a device with no
 * working watchdog cannot recover from a hang on its own.
 */

#include <linux/arm-smccc.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/moduleparam.h>
#include <linux/timer.h>

#define GH_WDT_EN_DIS_FN	0x86000005	/* w1: 2 = disable, 3 = enable */
#define GH_WDT_PET_FN		0x86000007
#define GH_WDT_DISABLE		2
#define GH_WDT_ENABLE		3

/* Android pets every ~9.5s; be comfortably inside that. */
#define GH_WDT_PET_SECS		4

static struct timer_list gh_wdt_timer;
static bool gh_wdt_pet_failed;

/*
 * Petting is what keeps the device alive through boot, but it also means a
 * hang during bring-up sits there forever - and recovering from that costs a
 * download-mode flash cycle, because there is no console and no way in.
 *
 * Once userspace is up and reachable, that trade reverses: it is far better
 * for a hang to be cut short by the watchdog and come back on its own. Write
 * 0 here to stop petting and re-arm the hardware watchdog:
 *
 *	echo 0 > /sys/module/gh_wdt_tame/parameters/pet
 *
 * A subsequent hang then resets the device instead of stranding it.
 */
static bool gh_wdt_pet_enabled = true;

static long gh_wdt_call(unsigned long fn, unsigned long a1)
{
	struct arm_smccc_res res;

	arm_smccc_smc(fn, a1, 0, 0, 0, 0, 0, 0, &res);
	return (long)res.a0;
}

static void gh_wdt_pet(struct timer_list *t)
{
	long ret;

	if (!gh_wdt_pet_enabled) {
		/* Stop rearming: the next bark/bite resets the device. */
		pr_err("gh_wdt_tame: petting disabled, watchdog is live\n");
		return;
	}

	ret = gh_wdt_call(GH_WDT_PET_FN, 0);

	if (ret < 0 && !gh_wdt_pet_failed) {
		/* Complain once, then keep trying - a spurious failure should
		 * not stop us petting for the rest of the boot.
		 */
		gh_wdt_pet_failed = true;
		pr_err("gh_wdt_tame: pet returned %ld\n", ret);
	}
	mod_timer(&gh_wdt_timer, jiffies + GH_WDT_PET_SECS * HZ);
}

static int gh_wdt_pet_set(const char *val, const struct kernel_param *kp)
{
	int rc = param_set_bool(val, kp);

	if (rc)
		return rc;

	if (gh_wdt_pet_enabled) {
		/* Re-arm our timer if petting was switched back on. */
		mod_timer(&gh_wdt_timer, jiffies + GH_WDT_PET_SECS * HZ);
		pr_err("gh_wdt_tame: petting re-enabled\n");
	} else {
		/*
		 * Hand the watchdog back to the hypervisor. If it refuses the
		 * enable, simply not petting still lets the existing timeout
		 * expire, which is the behaviour we want.
		 */
		pr_err("gh_wdt_tame: enable -> %ld\n",
		       gh_wdt_call(GH_WDT_EN_DIS_FN, GH_WDT_ENABLE));
	}
	return 0;
}

static const struct kernel_param_ops gh_wdt_pet_ops = {
	.set = gh_wdt_pet_set,
	.get = param_get_bool,
};
module_param_cb(pet, &gh_wdt_pet_ops, &gh_wdt_pet_enabled, 0644);
MODULE_PARM_DESC(pet, "keep petting the Gunyah watchdog (0 = let a hang reset the device)");

static int __init gh_wdt_tame_init(void)
{
	long ret;

	ret = gh_wdt_call(GH_WDT_EN_DIS_FN, GH_WDT_DISABLE);
	pr_err("gh_wdt_tame: disable -> %ld\n", ret);

	/*
	 * Pet regardless of what disable returned. If the watchdog really is
	 * off, this is a no-op; if the hypervisor quietly ignored the disable,
	 * this is what actually keeps the device alive.
	 */
	timer_setup(&gh_wdt_timer, gh_wdt_pet, 0);
	gh_wdt_pet(&gh_wdt_timer);
	pr_err("gh_wdt_tame: petting every %ds\n", GH_WDT_PET_SECS);
	return 0;
}
/*
 * late_initcall, not early: SMCCC must be usable, and this only needs to be
 * running before userspace starts - the watchdog bite lands ~20s in.
 */
late_initcall(gh_wdt_tame_init);
