/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * ISO (UDF or ISO9660/Joliet) -> MBR-partitioned exFAT disk image.
 *
 * Windows cannot mount an ISO that is attached as a plain (NVMe) disk: it only reads
 * CDFS/UDF from CD-ROM devices. UEFI boots such a disk fine, but Windows Setup then
 * stops with "a media driver your computer needs is missing" because it can't reach
 * \sources\install.wim. Re-packing the ISO's files into exFAT gives Windows a volume
 * it reads natively (install.wim > 4 GB rules out FAT32).
 */
#include "iso2exfat.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define SECTOR 512u
#define CLUSTER_SHIFT 6u                     /* 64 sectors = 32 KiB clusters */
#define CLUSTER (SECTOR << CLUSTER_SHIFT)
#define PART_LBA 2048u                       /* 1 MiB partition alignment */
#define ISO_BLOCK 2048u

typedef struct Extent { uint64_t off, len; } Extent;
#define ZERO_EXTENT UINT64_MAX

typedef struct Node {
    uint16_t name[256];
    int name_len;
    int is_dir;
    uint64_t size;
    Extent *ext; int next, cap_ext;
    uint8_t *inline_data;                    /* UDF embedded data */
    struct Node **kids; int nkids, cap_kids;
    /* exFAT layout */
    uint32_t first_cluster;
    uint64_t alloc;                          /* bytes allocated (cluster multiple) */
} Node;

typedef struct Ctx {
    int fd;
    char *err; size_t errlen;
    uint64_t iso_size;
} Ctx;

static int fail(Ctx *c, const char *fmt, ...) {
    if (c->err && c->errlen) {
        va_list ap; va_start(ap, fmt); vsnprintf(c->err, c->errlen, fmt, ap); va_end(ap);
    }
    return -1;
}

static int rd(Ctx *c, uint64_t off, void *buf, size_t len) {
    uint8_t *p = buf;
    while (len) {
        ssize_t n = pread(c->fd, p, len, (off_t)off);
        if (n <= 0) return -1;
        p += n; off += (uint64_t)n; len -= (size_t)n;
    }
    return 0;
}

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t le64(const uint8_t *p) { return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32; }
static void w16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void w32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void w64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }

static Node *node_new(void) { return calloc(1, sizeof(Node)); }

static void node_free(Node *n) {
    if (!n) return;
    for (int i = 0; i < n->nkids; i++) node_free(n->kids[i]);
    free(n->kids); free(n->ext); free(n->inline_data); free(n);
}

static int add_kid(Node *d, Node *k) {
    if (d->nkids == d->cap_kids) {
        int cap = d->cap_kids ? d->cap_kids * 2 : 16;
        Node **nk = realloc(d->kids, (size_t)cap * sizeof *nk);
        if (!nk) return -1;
        d->kids = nk; d->cap_kids = cap;
    }
    d->kids[d->nkids++] = k;
    return 0;
}

static int add_ext(Node *n, uint64_t off, uint64_t len) {
    if (!len) return 0;
    if (n->next && off != ZERO_EXTENT && n->ext[n->next - 1].off != ZERO_EXTENT &&
        n->ext[n->next - 1].off + n->ext[n->next - 1].len == off) {
        n->ext[n->next - 1].len += len;
        return 0;
    }
    if (n->next == n->cap_ext) {
        int cap = n->cap_ext ? n->cap_ext * 2 : 4;
        Extent *ne = realloc(n->ext, (size_t)cap * sizeof *ne);
        if (!ne) return -1;
        n->ext = ne; n->cap_ext = cap;
    }
    n->ext[n->next].off = off; n->ext[n->next].len = len; n->next++;
    return 0;
}

/* ------------------------------------------------------------------ UDF */

typedef struct Udf {
    uint32_t part_start;                     /* partition start (ISO blocks) */
    uint32_t bs;                             /* logical block size */
    int depth;
} Udf;

static int udf_dstring(const uint8_t *s, int len, uint16_t *out) {
    if (len <= 0) return 0;
    int n = 0;
    if (s[0] == 8) {
        for (int i = 1; i < len && n < 255; i++) out[n++] = s[i];
    } else if (s[0] == 16) {
        for (int i = 1; i + 1 < len && n < 255; i += 2) out[n++] = (uint16_t)(s[i] << 8 | s[i + 1]);
    }
    return n;
}

static int udf_read_entry(Ctx *c, Udf *u, uint32_t lbn, Node *n);

/* Reads the file/dir described by a (Extended) File Entry at partition block lbn into n. */
static int udf_read_entry(Ctx *c, Udf *u, uint32_t lbn, Node *n) {
    uint8_t *fe = malloc(u->bs);
    if (!fe) return fail(c, "out of memory");
    uint64_t base = (uint64_t)(u->part_start + lbn) * u->bs;
    if (rd(c, base, fe, u->bs) != 0) { free(fe); return fail(c, "UDF read error"); }
    uint16_t tag = le16(fe);
    uint32_t l_ea, l_ad, hdr;
    if (tag == 261) { l_ea = le32(fe + 168); l_ad = le32(fe + 172); hdr = 176; }
    else if (tag == 266) { l_ea = le32(fe + 208); l_ad = le32(fe + 212); hdr = 216; }
    else { free(fe); return fail(c, "UDF: unexpected descriptor %u", tag); }
    uint8_t ftype = fe[16 + 11];
    int adtype = le16(fe + 16 + 18) & 7;
    n->is_dir = ftype == 4;
    n->size = le64(fe + 56);
    if (hdr + l_ea + l_ad > u->bs) { free(fe); return fail(c, "UDF: oversized entry"); }
    const uint8_t *ad = fe + hdr + l_ea;
    if (adtype == 3) {                       /* embedded */
        n->inline_data = malloc(l_ad ? l_ad : 1);
        if (!n->inline_data) { free(fe); return fail(c, "out of memory"); }
        memcpy(n->inline_data, ad, l_ad);
        if (n->size > l_ad) n->size = l_ad;
    } else {
        uint32_t step = adtype == 0 ? 8 : 16;
        for (uint32_t i = 0; i + step <= l_ad; i += step) {
            uint32_t raw = le32(ad + i);
            uint32_t len = raw & 0x3fffffff;
            uint32_t kind = raw >> 30;
            uint32_t pos = le32(ad + i + 4);
            if (!len) break;
            if (kind == 3) { free(fe); return fail(c, "UDF: chained allocation descriptors not supported"); }
            uint64_t off = kind == 0 ? (uint64_t)(u->part_start + pos) * u->bs : ZERO_EXTENT;   /* unrecorded = zeros */
            if (add_ext(n, off, len) != 0) { free(fe); return fail(c, "out of memory"); }
        }
    }
    free(fe);
    if (!n->is_dir) return 0;

    /* Directory: read its File Identifier Descriptors */
    if (++u->depth > 64) return fail(c, "UDF: directory nesting too deep");
    uint64_t dlen = n->size;
    uint8_t *data = malloc(dlen ? dlen : 1);
    if (!data) return fail(c, "out of memory");
    if (n->inline_data) memcpy(data, n->inline_data, dlen);
    else {
        uint64_t got = 0;
        for (int i = 0; i < n->next && got < dlen; i++) {
            uint64_t take = n->ext[i].len < dlen - got ? n->ext[i].len : dlen - got;
            if (rd(c, n->ext[i].off, data + got, take) != 0) { free(data); return fail(c, "UDF read error"); }
            got += take;
        }
    }
    free(n->ext); n->ext = NULL; n->next = n->cap_ext = 0;
    free(n->inline_data); n->inline_data = NULL;

    for (uint64_t p = 0; p + 38 <= dlen;) {
        const uint8_t *f = data + p;
        if (le16(f) != 257) break;
        uint8_t chars = f[18];
        uint8_t l_fi = f[19];
        uint32_t icb_lbn = le32(f + 20 + 4);
        uint16_t l_iu = le16(f + 36);
        uint64_t sz = (38u + l_iu + l_fi + 3u) & ~3u;
        if (p + sz > dlen) break;
        if (!(chars & 0x08) && !(chars & 0x04) && l_fi > 0) {   /* not parent, not deleted */
            Node *k = node_new();
            if (!k) { free(data); return fail(c, "out of memory"); }
            k->name_len = udf_dstring(f + 38 + l_iu, l_fi, k->name);
            if (add_kid(n, k) != 0 || udf_read_entry(c, u, icb_lbn, k) != 0) { free(data); return -1; }
        }
        p += sz;
    }
    free(data);
    u->depth--;
    return 0;
}

static int has_udf(Ctx *c) {
    uint8_t s[ISO_BLOCK];
    for (uint32_t b = 16; b < 64; b++) {
        if (rd(c, (uint64_t)b * ISO_BLOCK, s, sizeof s) != 0) return 0;
        if (!memcmp(s + 1, "NSR02", 5) || !memcmp(s + 1, "NSR03", 5)) return 1;
        if (!memcmp(s + 1, "TEA01", 5)) break;
    }
    return 0;
}

static int udf_parse(Ctx *c, Node *root) {
    uint8_t avdp[ISO_BLOCK];
    if (rd(c, 256ull * ISO_BLOCK, avdp, sizeof avdp) != 0 || le16(avdp) != 2) return fail(c, "UDF: anchor not found");
    uint32_t vds_len = le32(avdp + 16), vds_loc = le32(avdp + 20);
    Udf u = {.bs = ISO_BLOCK};
    uint32_t fsd_lbn = 0; int have_pd = 0, have_lvd = 0;
    uint8_t d[ISO_BLOCK];
    for (uint32_t i = 0; i < vds_len / ISO_BLOCK && i < 64; i++) {
        if (rd(c, (uint64_t)(vds_loc + i) * ISO_BLOCK, d, sizeof d) != 0) break;
        uint16_t t = le16(d);
        if (t == 5 && !have_pd) { u.part_start = le32(d + 188); have_pd = 1; }
        else if (t == 6 && !have_lvd) { u.bs = le32(d + 212); fsd_lbn = le32(d + 248 + 4); have_lvd = 1; }
        else if (t == 8) break;
    }
    if (!have_pd || !have_lvd || u.bs != ISO_BLOCK) return fail(c, "UDF: unsupported volume layout");
    uint8_t fsd[ISO_BLOCK];
    if (rd(c, (uint64_t)(u.part_start + fsd_lbn) * u.bs, fsd, sizeof fsd) != 0 || le16(fsd) != 256)
        return fail(c, "UDF: file set descriptor not found");
    uint32_t root_lbn = le32(fsd + 400 + 4);
    return udf_read_entry(c, &u, root_lbn, root);
}

/* ------------------------------------------------------------- ISO9660 */

static int iso_dir(Ctx *c, Node *dir, uint32_t lba, uint32_t len, int joliet, int depth) {
    if (depth > 64) return fail(c, "ISO9660: directory nesting too deep");
    uint8_t *data = malloc(len ? len : 1);
    if (!data) return fail(c, "out of memory");
    if (rd(c, (uint64_t)lba * ISO_BLOCK, data, len) != 0) { free(data); return fail(c, "ISO read error"); }
    Node *multi = NULL;                      /* previous record of a multi-extent file */
    for (uint32_t p = 0; p < len;) {
        uint8_t rl = data[p];
        if (rl == 0) { p = (p / ISO_BLOCK + 1) * ISO_BLOCK; continue; }
        if (p + rl > len || rl < 34) break;
        const uint8_t *r = data + p;
        uint32_t ext = le32(r + 2), dl = le32(r + 10);
        uint8_t flags = r[25], nl = r[32];
        const uint8_t *nm = r + 33;
        p += rl;
        if (nl == 1 && (nm[0] == 0 || nm[0] == 1)) continue;   /* . and .. */
        uint16_t name[256]; int n = 0;
        if (joliet) { for (int i = 0; i + 1 < nl && n < 255; i += 2) name[n++] = (uint16_t)(nm[i] << 8 | nm[i + 1]); }
        else { for (int i = 0; i < nl && n < 255; i++) name[n++] = nm[i]; }
        for (int i = 0; i < n; i++) if (name[i] == ';') { n = i; break; }       /* strip ;1 */
        if (n > 0 && name[n - 1] == '.') n--;
        if (n == 0) continue;
        Node *k;
        if (multi && multi->name_len == n && !memcmp(multi->name, name, (size_t)n * 2)) {
            k = multi;                       /* continuation extent */
        } else {
            k = node_new();
            if (!k) { free(data); return fail(c, "out of memory"); }
            memcpy(k->name, name, (size_t)n * 2); k->name_len = n;
            k->is_dir = (flags & 2) != 0;
            if (add_kid(dir, k) != 0) { free(data); return fail(c, "out of memory"); }
        }
        if (k->is_dir) {
            if (iso_dir(c, k, ext, dl, joliet, depth + 1) != 0) { free(data); return -1; }
        } else {
            k->size += dl;
            if (add_ext(k, (uint64_t)ext * ISO_BLOCK, dl) != 0) { free(data); return fail(c, "out of memory"); }
        }
        multi = (flags & 0x80) ? k : NULL;
    }
    free(data);
    return 0;
}

static int iso_parse(Ctx *c, Node *root) {
    uint8_t vd[ISO_BLOCK];
    uint32_t pri_lba = 0, pri_len = 0, jol_lba = 0, jol_len = 0;
    for (uint32_t b = 16; b < 64; b++) {
        if (rd(c, (uint64_t)b * ISO_BLOCK, vd, sizeof vd) != 0) break;
        if (memcmp(vd + 1, "CD001", 5)) break;
        if (vd[0] == 255) break;
        const uint8_t *rr = vd + 156;
        if (vd[0] == 1 && !pri_lba) { pri_lba = le32(rr + 2); pri_len = le32(rr + 10); }
        if (vd[0] == 2 && vd[88] == 0x25 && vd[89] == 0x2f && (vd[90] == 0x40 || vd[90] == 0x43 || vd[90] == 0x45)) {
            jol_lba = le32(rr + 2); jol_len = le32(rr + 10);
        }
    }
    if (jol_lba) return iso_dir(c, root, jol_lba, jol_len, 1, 0);
    if (pri_lba) return iso_dir(c, root, pri_lba, pri_len, 0, 0);
    return fail(c, "Kein UDF/ISO9660-Dateisystem gefunden");
}

/* --------------------------------------------------------------- exFAT */

typedef struct Fs {
    uint32_t next_cluster;
    uint32_t cluster_count;
    uint32_t *ends; size_t nends, cap_ends;  /* last cluster of every contiguous run */
    uint16_t upcase[65536];
    uint32_t upcase_len;                     /* entries */
} Fs;

static uint16_t up(const Fs *fs, uint16_t ch) { return ch < fs->upcase_len ? fs->upcase[ch] : ch; }

static void build_upcase(Fs *fs) {
    for (uint32_t i = 0; i < 65536; i++) fs->upcase[i] = (uint16_t)i;
    for (uint32_t i = 'a'; i <= 'z'; i++) fs->upcase[i] = (uint16_t)(i - 32);
    for (uint32_t i = 0xe0; i <= 0xfe; i++) if (i != 0xf7) fs->upcase[i] = (uint16_t)(i - 32);
    fs->upcase_len = 65536;
}

/* On-disk up-case table in the compressed form Windows writes:
   0xFFFF, n = "the next n characters map to themselves". Returns length in uint16 units. */
static uint32_t compress_upcase(const Fs *fs, uint16_t *out) {
    uint32_t n = 0, i = 0;
    while (i < 65536) {
        if (fs->upcase[i] == i) {
            uint32_t j = i;
            while (j < 65536 && fs->upcase[j] == j && j - i < 0xFFFF) j++;
            if (j - i > 2) { out[n++] = 0xFFFF; out[n++] = (uint16_t)(j - i); i = j; continue; }
        }
        out[n++] = fs->upcase[i++];
    }
    return n;
}

static uint32_t dir_entries(const Node *d, int is_root) {
    uint32_t n = is_root ? 3 : 0;            /* label, bitmap, upcase */
    for (int i = 0; i < d->nkids; i++) n += 2 + (uint32_t)(d->kids[i]->name_len + 14) / 15;
    return n;
}

static void push_end(Fs *fs, uint32_t cl) {
    if (fs->nends == fs->cap_ends) {
        size_t cap = fs->cap_ends ? fs->cap_ends * 2 : 1024;
        uint32_t *ne = realloc(fs->ends, cap * sizeof *ne);
        if (!ne) return;                     /* caught later: chain end missing is still bounded by allocation */
        fs->ends = ne; fs->cap_ends = cap;
    }
    fs->ends[fs->nends++] = cl;
}

static uint64_t round_cluster(uint64_t b) { return (b + CLUSTER - 1) / CLUSTER * CLUSTER; }

static uint64_t dir_bytes(const Node *d, int is_root) {
    uint64_t b = round_cluster((uint64_t)dir_entries(d, is_root) * 32);
    return b ? b : CLUSTER;
}

/* Assigns contiguous clusters: directories first (breadth-first), then files. */
static void alloc_dirs(Fs *fs, Node *d, int is_root) {
    d->alloc = dir_bytes(d, is_root);
    d->first_cluster = fs->next_cluster;
    fs->next_cluster += (uint32_t)(d->alloc / CLUSTER);
    push_end(fs, fs->next_cluster - 1);
    for (int i = 0; i < d->nkids; i++) if (d->kids[i]->is_dir) alloc_dirs(fs, d->kids[i], 0);
}

static void alloc_files(Fs *fs, Node *d) {
    for (int i = 0; i < d->nkids; i++) {
        Node *k = d->kids[i];
        if (k->is_dir) { alloc_files(fs, k); continue; }
        k->alloc = round_cluster(k->size);
        k->first_cluster = k->alloc ? fs->next_cluster : 0;
        fs->next_cluster += (uint32_t)(k->alloc / CLUSTER);
        if (k->alloc) push_end(fs, fs->next_cluster - 1);
    }
}

static uint64_t total_bytes(const Node *d) {
    uint64_t t = 0;
    for (int i = 0; i < d->nkids; i++) t += d->kids[i]->is_dir ? total_bytes(d->kids[i]) : d->kids[i]->size;
    return t;
}

static uint16_t entry_set_checksum(const uint8_t *e, int count) {
    uint16_t c = 0;
    for (int i = 0; i < count * 32; i++) {
        if (i == 2 || i == 3) continue;
        c = (uint16_t)(((c & 1) ? 0x8000 : 0) + (c >> 1) + e[i]);
    }
    return c;
}

static uint16_t name_hash(const Fs *fs, const uint16_t *name, int n) {
    uint16_t h = 0;
    for (int i = 0; i < n; i++) {
        uint16_t u = up(fs, name[i]);
        h = (uint16_t)(((h & 1) ? 0x8000 : 0) + (h >> 1) + (u & 0xff));
        h = (uint16_t)(((h & 1) ? 0x8000 : 0) + (h >> 1) + (u >> 8));
    }
    return h;
}

typedef struct Out {
    int fd;
    uint64_t heap;                           /* byte offset of cluster 2 in the image */
    char *err; size_t errlen;
} Out;

static int wr(Out *o, uint64_t off, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len) {
        ssize_t n = pwrite(o->fd, p, len, (off_t)off);
        if (n <= 0) return -1;
        p += n; off += (uint64_t)n; len -= (size_t)n;
    }
    return 0;
}

static uint64_t cluster_off(const Out *o, uint32_t cl) { return o->heap + (uint64_t)(cl - 2) * CLUSTER; }

#define TS_2025 ((uint32_t)((2025 - 1980) << 25 | 1 << 21 | 1 << 16))

static int write_dir(Out *o, const Fs *fs, const Node *d, int is_root,
                     uint32_t bitmap_cl, uint64_t bitmap_len, uint32_t upcase_cl, uint64_t upcase_len, uint32_t upcase_sum) {
    uint8_t *buf = calloc(1, d->alloc);
    if (!buf) return -1;
    uint8_t *e = buf;
    if (is_root) {
        static const char label[] = "WINSETUP";
        e[0] = 0x83; e[1] = (uint8_t)strlen(label);
        for (size_t i = 0; i < strlen(label); i++) w16(e + 2 + 2 * i, (uint16_t)label[i]);
        e += 32;
        e[0] = 0x81; w32(e + 20, bitmap_cl); w64(e + 24, bitmap_len); e += 32;
        e[0] = 0x82; w32(e + 4, upcase_sum); w32(e + 20, upcase_cl); w64(e + 24, upcase_len); e += 32;
    }
    for (int i = 0; i < d->nkids; i++) {
        const Node *k = d->kids[i];
        int nn = (k->name_len + 14) / 15;
        uint8_t *set = e;
        set[0] = 0x85; set[1] = (uint8_t)(1 + nn);
        w16(set + 4, k->is_dir ? 0x10 : 0x20);          /* directory / archive */
        w32(set + 8, TS_2025); w32(set + 12, TS_2025); w32(set + 16, TS_2025);
        uint8_t *s = set + 32;
        s[0] = 0xC0; s[1] = 0x01;                        /* allocation possible, FAT chain */
        s[3] = (uint8_t)k->name_len;
        w16(s + 4, name_hash(fs, k->name, k->name_len));
        uint64_t len = k->is_dir ? k->alloc : k->size;
        w64(s + 8, len); w32(s + 20, k->first_cluster); w64(s + 24, len);
        for (int j = 0; j < nn; j++) {
            uint8_t *f = set + 64 + 32 * j;
            f[0] = 0xC1;
            for (int ch = 0; ch < 15; ch++) {
                int idx = j * 15 + ch;
                if (idx < k->name_len) w16(f + 2 + 2 * ch, k->name[idx]);
            }
        }
        w16(set + 2, entry_set_checksum(set, 2 + nn));
        e += 32 * (2 + nn);
    }
    int rc = wr(o, cluster_off(o, d->first_cluster), buf, d->alloc);
    free(buf);
    if (rc != 0) return -1;
    for (int i = 0; i < d->nkids; i++)
        if (d->kids[i]->is_dir && write_dir(o, fs, d->kids[i], 0, 0, 0, 0, 0, 0) != 0) return -1;
    return 0;
}

typedef struct Copy {
    Ctx *in; Out *out;
    uint8_t *buf;
    uint64_t done, total;
    hv_iso_progress_fn progress; void *opaque;
} Copy;

static int copy_files(Copy *cp, const Node *d) {
    for (int i = 0; i < d->nkids; i++) {
        const Node *k = d->kids[i];
        if (k->is_dir) { if (copy_files(cp, k) != 0) return -1; continue; }
        if (!k->size) continue;
        uint64_t dst = cluster_off(cp->out, k->first_cluster), left = k->size;
        if (k->inline_data) {
            if (wr(cp->out, dst, k->inline_data, (size_t)k->size) != 0) return -1;
            cp->done += k->size;
            continue;
        }
        for (int x = 0; x < k->next && left; x++) {
            uint64_t src = k->ext[x].off, el = k->ext[x].len < left ? k->ext[x].len : left;
            if (src == ZERO_EXTENT) {        /* image is sparse: zeros are already there */
                dst += el; left -= el; cp->done += el;
                continue;
            }
            while (el) {
                size_t chunk = el > (4u << 20) ? (4u << 20) : (size_t)el;
                if (rd(cp->in, src, cp->buf, chunk) != 0 || wr(cp->out, dst, cp->buf, chunk) != 0) return -1;
                src += chunk; dst += chunk; el -= chunk; left -= chunk; cp->done += chunk;
                if (cp->progress) cp->progress(cp->done, cp->total, cp->opaque);
            }
        }
    }
    return 0;
}

static int name_eq_ascii(const Node *n, const char *s, size_t len) {
    if ((size_t)n->name_len != len) return 0;
    for (size_t i = 0; i < len; i++) {
        uint16_t a = n->name[i], b = (uint8_t)s[i];
        if (a >= 'a' && a <= 'z') a -= 32;
        if (b >= 'a' && b <= 'z') b -= 32;
        if (a != b) return 0;
    }
    return 1;
}

/* Adds (or replaces) a fixed-size file at "dir/name" (one directory level max, the directory
   must exist). Its contents are filled with spaces; the caller rewrites them in place later. */
static Node *reserve_file(Node *root, const char *path, uint64_t size) {
    Node *dir = root;
    const char *slash = strchr(path, '/');
    if (slash) {
        dir = NULL;
        for (int i = 0; i < root->nkids; i++)
            if (root->kids[i]->is_dir && name_eq_ascii(root->kids[i], path, (size_t)(slash - path))) dir = root->kids[i];
        if (!dir) return NULL;
        path = slash + 1;
    }
    size_t len = strlen(path);
    Node *n = NULL;
    for (int i = 0; i < dir->nkids; i++)
        if (!dir->kids[i]->is_dir && name_eq_ascii(dir->kids[i], path, len)) n = dir->kids[i];
    if (!n) {
        n = node_new();
        if (!n || add_kid(dir, n) != 0) return NULL;
        for (size_t i = 0; i < len && i < 255; i++) n->name[i] = (uint8_t)path[i];
        n->name_len = (int)(len < 255 ? len : 255);
    }
    free(n->ext); n->ext = NULL; n->next = n->cap_ext = 0;
    free(n->inline_data);
    n->inline_data = malloc((size_t)size);
    if (!n->inline_data) return NULL;
    memset(n->inline_data, ' ', (size_t)size);
    n->size = size;
    return n;
}

int hv_iso_to_exfat(const char *iso_path, const char *out_path, hv_iso_progress_fn progress, void *opaque,
                    char *err, size_t errlen) {
    return hv_iso_to_exfat_reserve(iso_path, out_path, NULL, 0, 0, NULL, progress, opaque, err, errlen);
}

int hv_iso_to_exfat_reserve(const char *iso_path, const char *out_path,
                            const char *const *reserve_paths, int nreserve, uint64_t reserve_size,
                            uint64_t *reserve_offsets,
                            hv_iso_progress_fn progress, void *opaque, char *err, size_t errlen) {
    Ctx c = {.fd = open(iso_path, O_RDONLY), .err = err, .errlen = errlen};
    if (c.fd < 0) return fail(&c, "ISO kann nicht geöffnet werden (%s)", strerror(errno));
    Node *root = node_new();
    Fs *fs = calloc(1, sizeof *fs);
    int ret = -1, ofd = -1;
    uint8_t *big = NULL;
    if (!root || !fs) { fail(&c, "out of memory"); goto out; }
    root->is_dir = 1;
    if ((has_udf(&c) ? udf_parse(&c, root) : iso_parse(&c, root)) != 0) goto out;
    if (root->nkids == 0) { fail(&c, "Die ISO enthält keine Dateien"); goto out; }
    Node *reserved[8] = {0};
    if (nreserve > 8) nreserve = 8;
    for (int i = 0; i < nreserve; i++) {
        reserved[i] = reserve_file(root, reserve_paths[i], reserve_size);
        if (reserve_offsets) reserve_offsets[i] = 0;
    }

    build_upcase(fs);
    static uint16_t packed[65536 * 2];
    uint32_t packed_units = compress_upcase(fs, packed);
    uint64_t upcase_len = (uint64_t)packed_units * 2;
    uint32_t upcase_sum = 0;
    for (uint64_t i = 0; i < upcase_len; i++) {
        uint8_t b = (uint8_t)(packed[i / 2] >> ((i & 1) * 8));
        upcase_sum = ((upcase_sum & 1) ? 0x80000000u : 0) + (upcase_sum >> 1) + b;
    }

    /* Layout pass: bitmap size depends on the cluster count, so iterate. */
    uint32_t bitmap_clusters = 1, cluster_count = 0;
    for (int iter = 0; iter < 4; iter++) {
        fs->nends = 0;
        push_end(fs, 2 + bitmap_clusters - 1);
        push_end(fs, 2 + bitmap_clusters + (uint32_t)(round_cluster(upcase_len) / CLUSTER) - 1);
        fs->next_cluster = 2 + bitmap_clusters + (uint32_t)(round_cluster(upcase_len) / CLUSTER);
        alloc_dirs(fs, root, 1);
        alloc_files(fs, root);
        cluster_count = fs->next_cluster - 2 + 16;          /* a little slack */
        uint32_t need = (uint32_t)(round_cluster((cluster_count + 7) / 8) / CLUSTER);
        if (need == bitmap_clusters) break;
        bitmap_clusters = need;
    }
    uint32_t bitmap_cl = 2;
    uint32_t upcase_cl = 2 + bitmap_clusters;
    uint64_t bitmap_len = (cluster_count + 7) / 8;

    uint32_t fat_offset = 128;                                /* sectors, relative to volume */
    uint32_t fat_len = (uint32_t)(((uint64_t)(cluster_count + 2) * 4 + SECTOR - 1) / SECTOR);
    uint32_t spc = 1u << CLUSTER_SHIFT;
    uint32_t heap_offset = (fat_offset + fat_len + spc - 1) / spc * spc;
    uint64_t vol_sectors = heap_offset + (uint64_t)cluster_count * spc;
    uint64_t part_off = (uint64_t)PART_LBA * SECTOR;
    uint64_t image_size = part_off + vol_sectors * SECTOR;

    ofd = open(out_path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (ofd < 0) { fail(&c, "Ausgabedatei kann nicht erstellt werden (%s)", strerror(errno)); goto out; }
    if (ftruncate(ofd, (off_t)image_size) != 0) { fail(&c, "Nicht genug Speicherplatz (%s)", strerror(errno)); goto out; }
    Out o = {.fd = ofd, .heap = part_off + (uint64_t)heap_offset * SECTOR, .err = err, .errlen = errlen};

    /* MBR */
    uint8_t mbr[SECTOR] = {0};
    w32(mbr + 440, (uint32_t)time(NULL));
    uint8_t *pe = mbr + 446;
    pe[1] = 0xFE; pe[2] = 0xFF; pe[3] = 0xFF; pe[4] = 0x07; pe[5] = 0xFE; pe[6] = 0xFF; pe[7] = 0xFF;
    w32(pe + 8, PART_LBA);
    w32(pe + 12, vol_sectors > 0xffffffffull ? 0xffffffffu : (uint32_t)vol_sectors);
    mbr[510] = 0x55; mbr[511] = 0xAA;
    if (wr(&o, 0, mbr, sizeof mbr) != 0) goto ioerr;

    /* Boot region (main + backup) */
    uint8_t region[12 * SECTOR];
    memset(region, 0, sizeof region);
    uint8_t *bs = region;
    bs[0] = 0xEB; bs[1] = 0x76; bs[2] = 0x90;
    memcpy(bs + 3, "EXFAT   ", 8);
    w64(bs + 64, PART_LBA);
    w64(bs + 72, vol_sectors);
    w32(bs + 80, fat_offset);
    w32(bs + 84, fat_len);
    w32(bs + 88, heap_offset);
    w32(bs + 92, cluster_count);
    w32(bs + 96, root->first_cluster);
    w32(bs + 100, (uint32_t)time(NULL) ^ 0x57494e53u);
    w16(bs + 104, 0x0100);
    bs[108] = 9; bs[109] = CLUSTER_SHIFT; bs[110] = 1; bs[111] = 0x80;
    bs[112] = (uint8_t)((uint64_t)(fs->next_cluster - 2) * 100 / cluster_count);
    memset(bs + 120, 0xF4, 390);
    bs[510] = 0x55; bs[511] = 0xAA;
    for (int s = 1; s <= 8; s++) { region[s * SECTOR + 510] = 0x55; region[s * SECTOR + 511] = 0xAA; }
    uint32_t sum = 0;
    for (uint32_t i = 0; i < 11 * SECTOR; i++) {
        if (i == 106 || i == 107 || i == 112) continue;
        sum = ((sum & 1) ? 0x80000000u : 0) + (sum >> 1) + region[i];
    }
    for (uint32_t i = 0; i < SECTOR; i += 4) w32(region + 11 * SECTOR + i, sum);
    if (wr(&o, part_off, region, sizeof region) != 0 || wr(&o, part_off + 12 * SECTOR, region, sizeof region) != 0) goto ioerr;

    /* FAT: contiguous chains for everything allocated */
    {
        size_t fat_bytes = (size_t)fat_len * SECTOR;
        uint8_t *fat = calloc(1, fat_bytes);
        if (!fat) { fail(&c, "out of memory"); goto out; }
        w32(fat, 0xFFFFFFF8u); w32(fat + 4, 0xFFFFFFFFu);
        for (uint32_t cl = 2; cl < fs->next_cluster; cl++) w32(fat + (size_t)cl * 4, cl + 1);
        for (size_t i = 0; i < fs->nends; i++) w32(fat + (size_t)fs->ends[i] * 4, 0xFFFFFFFFu);
        int rc = wr(&o, part_off + (uint64_t)fat_offset * SECTOR, fat, fat_bytes);
        free(fat);
        if (rc != 0) goto ioerr;
    }

    /* Allocation bitmap */
    {
        uint8_t *bm = calloc(1, (size_t)round_cluster(bitmap_len));
        if (!bm) { fail(&c, "out of memory"); goto out; }
        for (uint32_t cl = 2; cl < fs->next_cluster; cl++) bm[(cl - 2) / 8] |= (uint8_t)(1u << ((cl - 2) % 8));
        int rc = wr(&o, cluster_off(&o, bitmap_cl), bm, (size_t)bitmap_len);
        free(bm);
        if (rc != 0) goto ioerr;
    }

    /* Up-case table */
    {
        uint8_t *ut = malloc((size_t)upcase_len);
        if (!ut) { fail(&c, "out of memory"); goto out; }
        for (uint32_t i = 0; i < packed_units; i++) w16(ut + 2 * i, packed[i]);
        int rc = wr(&o, cluster_off(&o, upcase_cl), ut, (size_t)upcase_len);
        free(ut);
        if (rc != 0) goto ioerr;
    }

    if (write_dir(&o, fs, root, 1, bitmap_cl, bitmap_len, upcase_cl, upcase_len, upcase_sum) != 0) goto ioerr;

    big = malloc(4u << 20);
    if (!big) { fail(&c, "out of memory"); goto out; }
    Copy cp = {.in = &c, .out = &o, .buf = big, .total = total_bytes(root), .progress = progress, .opaque = opaque};
    if (copy_files(&cp, root) != 0) goto ioerr;
    if (progress) progress(cp.total, cp.total, opaque);
    for (int i = 0; i < nreserve; i++)
        if (reserve_offsets && reserved[i] && reserved[i]->first_cluster)
            reserve_offsets[i] = cluster_off(&o, reserved[i]->first_cluster);
    if (fsync(ofd) != 0) goto ioerr;
    ret = 0;
    goto out;

ioerr:
    fail(&c, "Schreib-/Lesefehler (%s) – genug freier Speicher?", strerror(errno));
out:
    free(big);
    if (ofd >= 0) { close(ofd); if (ret != 0) unlink(out_path); }
    close(c.fd);
    node_free(root);
    if (fs) free(fs->ends);
    free(fs);
    return ret;
}
