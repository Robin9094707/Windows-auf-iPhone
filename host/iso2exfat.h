/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_ISO2EXFAT_H
#define HV_ISO2EXFAT_H

#include <stddef.h>
#include <stdint.h>

typedef void (*hv_iso_progress_fn)(uint64_t done, uint64_t total, void *opaque);

/* Converts an ISO image (UDF – e.g. Windows installation media – or ISO9660/Joliet)
   into a raw disk image with one MBR partition formatted exFAT that holds the same
   files. Windows can read that volume from an NVMe disk; it can't read the ISO itself.
   Returns 0, or -1 with a message in err. */
int hv_iso_to_exfat(const char *iso_path, const char *out_path, hv_iso_progress_fn progress, void *opaque,
                    char *err, size_t errlen);

#endif
