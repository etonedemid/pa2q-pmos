/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (c) 2023-2024 Qualcomm Innovation Center, Inc. All rights reserved.
 */

#define CONFIG_ARCH_SUN 1
/*
 * The running kernel uses the crm_v2 prebuilt module. Building against the GKI
 * tree (which lacks this msm-kernel config) left CONFIG_QCOM_CRM_V2 undefined,
 * so soc/qcom/crm.h gave sde_cesta the stub crm_get_device() that always
 * returns -ENODEV - cesta could never bind and the display never came up.
 * Define it so crm.h declares the real extern, resolved to crm_v2 at load.
 */
#define CONFIG_QCOM_CRM_V2 1
/*
 * This panel (PA2_S6E3HAF) draws panel_vddr from the s2dos07 sub-PMIC. The
 * MODULE_SOFTDEP("pre: s2dos07") in msm_drv.c is guarded by this kernel config,
 * absent from the GKI tree - without it the softdep was dropped, s2dos07 never
 * pre-loaded, panel_vddr was missing and the panel deferred forever.
 */
#define CONFIG_REGULATOR_S2DOS07 1
#define CONFIG_DRM_MSM 1
#define CONFIG_DRM_MSM_SDE 1
#define CONFIG_SYNC_FILE 1
#define CONFIG_DRM_MSM_DSI 1
#define CONFIG_DRM_MSM_DP 1
#define CONFIG_DRM_MSM_DP_MST 1
#define CONFIG_DSI_PARSER 1
#define CONFIG_DRM_SDE_WB 1
#define CONFIG_DRM_MSM_REGISTER_LOGGING 1
#define CONFIG_MSM_MMRM 1
#define CONFIG_DRM_SDE_EVTLOG_DEBUG 1
#define CONFIG_QCOM_MDSS_PLL 1
#define CONFIG_GKI_DISPLAY 1
#define CONFIG_MSM_EXT_DISPLAY 1
#define CONFIG_HDCP_QSEECOM 1
#define CONFIG_DRM_SDE_VM 1
#define CONFIG_QTI_HW_FENCE 1
#define CONFIG_QCOM_SPEC_SYNC 1
#define CONFIG_QCOM_WCD939X_I2C 1
#define CONFIG_DRM_SDE_CESTA 1
