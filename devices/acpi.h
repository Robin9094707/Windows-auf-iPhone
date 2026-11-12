/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_ACPI_H
#define HV_ACPI_H

#include <stdint.h>
#include "fw_cfg.h"

/* Populate HvFwCfg with ACPI 6.4 tables (DSDT, FACP, APIC/MADT with GICv3 + GICv2m,
 * PPTT, GTDT, MCFG, SPCR, DBG2, IORT, XSDT), RSDP, BIOS table-loader script, and
 * SMBIOS 3.0 tables for EDK2 ArmVirtQemu and Windows 11 ARM64. */
void hv_acpi_build_and_register(HvFwCfg *fw, int ncpus, uint64_t ram_size, int spi_msi_base, int spi_msi_count);

/* Device identity reported to Windows via SMBIOS (System Information, Task Manager).
 * Call before hv_acpi_build_and_register; NULL / 0 keeps the defaults. */
void hv_smbios_set_device(const char *manufacturer, const char *product, const char *model_id,
                          const char *family, const char *cpu_name, uint16_t cpu_max_mhz,
                          const char *mem_type, uint16_t mem_mts);

/* Screen resolution the (patched) UEFI ramfb driver should use; 0x0 = firmware default. */
void hv_fw_set_resolution(uint32_t width, uint32_t height);

#endif
