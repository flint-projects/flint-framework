#ifndef FLINT_CODEC_PRIVATE_H
#define FLINT_CODEC_PRIVATE_H

#include "flint_codec.h"

typedef struct flint_codec_io {
    const uint8_t *input;
    size_t input_length;
    size_t consumed;
    uint8_t *output;
    size_t capacity;
    size_t produced;
    int finish;
} flint_codec_io;

typedef struct flint_codec_provider {
    int (*valid_level)(int);
    int (*create)(flint_codec_state *, int);
    int (*step)(flint_codec_state *, flint_codec_io *);
    void (*destroy)(flint_codec_state *);
} flint_codec_provider;

struct flint_codec_state {
    const flint_codec_provider *vtable;
    void *native;
    flint_codec_allocations allocations;
    size_t budget;
    int encode;
    int allocation_limit;
};

void *flint_codec_alloc(void *state, size_t size);
void flint_codec_dealloc(void *state, void *buffer);
int flint_codec_allocation_error(const flint_codec_state *state);

#if FLINT_HAS_ZLIB
extern const flint_codec_provider flint_gzip_provider;
#endif
#if FLINT_HAS_ZSTD
extern const flint_codec_provider flint_zstd_provider;
#endif
#if FLINT_HAS_BROTLI
extern const flint_codec_provider flint_brotli_provider;
#endif
#endif
