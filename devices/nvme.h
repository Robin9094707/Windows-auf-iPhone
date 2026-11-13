#ifndef WINVM_NVME_H
#define WINVM_NVME_H

#include <pthread.h>
#include <stdint.h>

#include "disk.h"
#include "pcie.h"

#define HV_NVME_MAX_QUEUES 17 /* 0: Admin, 1..16: I/O */

typedef struct HvNvmeSq {
    uint64_t pa;
    uint16_t size;  /* number of 64-byte entries */
    uint16_t head;
    uint16_t tail;
    uint16_t cqid;
    int valid;
} HvNvmeSq;

typedef struct HvNvmeCq {
    uint64_t pa;
    uint16_t size;  /* number of 16-byte entries */
    uint16_t head;
    uint16_t tail;
    uint16_t irq_vec;
    uint8_t phase;
    uint8_t ien;
    uint8_t irq_pending;
    int valid;
} HvNvmeCq;

/* I/O commands run on worker threads (like a real SSD): the CPU that rings the
   doorbell only queues them; completions are posted by hv_nvme_poll on CPU 0. */
#define HV_NVME_RING 256
#define HV_NVME_WORKERS 4

typedef struct HvNvmeReq {
    uint8_t cmd[64];
    uint16_t sqid;
    uint16_t status;
    int done;    /* set by the worker (atomic) */
    int posted;  /* CQE written (CPU 0) */
} HvNvmeReq;

typedef struct HvNvme {
    HvPciDev pci;
    HvMachine *m;
    HvDisk *disk;
    pthread_mutex_t mu;
    char serial[24];

    uint64_t cap;
    uint32_t vs;
    uint32_t intms;
    uint32_t cc;
    uint32_t csts;
    uint32_t aqa;
    uint64_t asq;
    uint64_t acq;

    uint32_t temp_thresh;
    uint32_t arb_feat;
    uint32_t pm_feat;
    uint32_t vwc_feat;
    uint32_t num_queues_feat;

    HvNvmeSq sq[HV_NVME_MAX_QUEUES];
    HvNvmeCq cq[HV_NVME_MAX_QUEUES];

    uint8_t *io_buf;
    uint32_t io_buf_cap;
    uint64_t rd_bytes, wr_bytes;

    /* Asynchronous I/O */
    HvNvmeReq ring[HV_NVME_RING];
    uint32_t submitted, claimed, completed, published; /* ring counters */
    uint32_t inflight;
    int fence;            /* a Flush waits for everything before it */
    uint32_t backlog;     /* bitmask of SQs with commands left (ring was full) */
    pthread_mutex_t wmu;
    pthread_cond_t wcv, done_cv;
    pthread_t worker[HV_NVME_WORKERS];
    int async;            /* 0: run I/O on the CPU thread (HV_NVME_SYNC) */
} HvNvme;

HvNvme *hv_nvme_create(HvMachine *m, HvPcie *bus, HvDisk *disk, const char *serial);
/* CPU 0 (board tick, device lock held): posts finished I/O and raises the interrupts. */
void hv_nvme_poll(HvNvme *nv);

#endif
