#ifndef __RS_H_
#define __RS_H_

#include <stdint.h>
#include <stddef.h>
#include "oblas_common.h"

/*
 * Symbol confinement: Wire/ vendors its own copy of nanors (CNanorsWire,
 * W1) and both copies link into lyte-cli and the test bundle until CL-2
 * re-points the client at core's FecDecoder and this target is dropped.
 * The __asm__ labels below give THIS copy distinct linker names while the
 * C (and Swift-imported) names stay unchanged — the frozen GameStream
 * callers compile untouched. macOS-only package, hence the leading '_'.
 */
#define LYTE_CLIENT_SYM(name) __asm__("_lyte_client_" #name)

#define DATA_SHARDS_MAX 255

#ifdef __cplusplus
extern "C" {
#endif

typedef struct _reed_solomon {
    int ds;
    int ps;
    int ts;
    void (*axpy)(uint8_t *a, uint8_t *b, uint8_t u, unsigned k);
    void (*scal)(uint8_t *a, uint8_t u, unsigned k);
    void (*axiy)(uint8_t *a, uint8_t *b, uint8_t u, unsigned k);
    size_t align_size;
    uint8_t p[];
} reed_solomon;

#define reed_solomon_bufsize(ds, ps) (sizeof(reed_solomon) + (ps) * (ds) + (ds) * (ds))
#define reed_solomon_reconstruct reed_solomon_decode

void reed_solomon_init(void) LYTE_CLIENT_SYM(reed_solomon_init);
reed_solomon *reed_solomon_new_static(void *buf, size_t len, int ds, int ps) LYTE_CLIENT_SYM(reed_solomon_new_static);
reed_solomon *reed_solomon_new(int data_shards, int parity_shards) LYTE_CLIENT_SYM(reed_solomon_new);
void reed_solomon_release(reed_solomon *rs) LYTE_CLIENT_SYM(reed_solomon_release);

int reed_solomon_encode(reed_solomon *rs, uint8_t **shards, int nr_shards, int bs) LYTE_CLIENT_SYM(reed_solomon_encode);
int reed_solomon_decode(reed_solomon *rs, uint8_t **shards, uint8_t *marks, int nr_shards, int bs) LYTE_CLIENT_SYM(reed_solomon_decode);

/*
 * nanors can process data of any length, but performance is significantly better
 * when your block sizes (bs) and allocated buffers are padded and aligned to the
 * optimal simd alignment for your cpu.
 */

/* returns padded/aligned memory */
void *reed_solomon_aligned_alloc(size_t size) LYTE_CLIENT_SYM(reed_solomon_aligned_alloc);
void reed_solomon_free(void *ptr) LYTE_CLIENT_SYM(reed_solomon_free);
/* returns the padded block size */
int reed_solomon_padded_size(int bs) LYTE_CLIENT_SYM(reed_solomon_padded_size);

#ifdef __cplusplus
}
#endif

#endif
