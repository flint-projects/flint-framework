#include "flint_codec_private.h"

#include <stdlib.h>

typedef union allocation_header {
    max_align_t align;
    size_t length;
} allocation_header;

static const flint_codec_provider *choose(int codec) {
    switch (codec) {
#if FLINT_HAS_ZLIB
    case 0: return &flint_gzip_provider;
#endif
#if FLINT_HAS_ZSTD
    case 1: return &flint_zstd_provider;
#endif
#if FLINT_HAS_BROTLI
    case 2: return &flint_brotli_provider;
#endif
    default: return NULL;
    }
}

int flint_codec_available(int codec) {
    return choose(codec) != NULL;
}

int flint_codec_level_valid(int codec, int level) {
    const flint_codec_provider *provider = choose(codec);
    return provider && provider->valid_level(level);
}

void *flint_codec_alloc(void *context, size_t length) {
    flint_codec_state *state = context;
    if (length > state->budget - state->allocations.live_bytes ||
        length > SIZE_MAX - sizeof(allocation_header)) {
        state->allocation_limit = 1;
        return NULL;
    }
    allocation_header *allocation = calloc(1, sizeof(*allocation) + length);
    if (!allocation) return NULL;
    allocation->length = length;
    state->allocations.calls++;
    state->allocations.live_bytes += length;
    if (state->allocations.live_bytes > state->allocations.peak_bytes)
        state->allocations.peak_bytes = state->allocations.live_bytes;
    return allocation + 1;
}

void flint_codec_dealloc(void *context, void *buffer) {
    if (!buffer) return;
    flint_codec_state *state = context;
    allocation_header *allocation = (allocation_header *)buffer - 1;
    state->allocations.live_bytes -= allocation->length;
    free(allocation);
}

int flint_codec_allocation_error(const flint_codec_state *state) {
    return state->allocation_limit ? FLINT_CODEC_LIMIT : FLINT_CODEC_NOMEM;
}

flint_codec_allocations flint_codec_get_allocations(const flint_codec_state *state) {
    return state ? state->allocations : (flint_codec_allocations){0};
}

flint_codec_state *flint_codec_new(int codec, int encode, int level) {
    const flint_codec_provider *provider = choose(codec);
    if (!provider || (encode && !provider->valid_level(level))) return NULL;
    flint_codec_state *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    state->vtable = provider;
    state->encode = !!encode;
    state->budget = (encode ? 512u : 48u) * 1024u * 1024u;
    if (provider->create(state, level) == FLINT_CODEC_OK) return state;
    flint_codec_free(state);
    return NULL;
}

static int overlap(const uint8_t *first, size_t first_length,
                   const uint8_t *second, size_t second_length) {
    if (!first_length || !second_length) return 0;
    const uintptr_t a = (uintptr_t)first;
    const uintptr_t b = (uintptr_t)second;
    return a <= b ? b - a < first_length : a - b < second_length;
}

int flint_codec_step(flint_codec_state *state, const uint8_t *input,
                     size_t input_length, size_t *consumed,
                     uint8_t *output, size_t output_capacity,
                     size_t *produced, int finish) {
    if (!consumed || !produced) return FLINT_CODEC_INVALID;
    *consumed = *produced = 0;
    if (!state || (input_length && !input) || (output_capacity && !output) ||
        finish < 0 || finish > 2 || overlap(input, input_length, output, output_capacity))
        return FLINT_CODEC_INVALID;
    if (!output_capacity) return FLINT_CODEC_OK;
    flint_codec_io io = {input, input_length, 0, output, output_capacity, 0, finish};
    const int result = state->vtable->step(state, &io);
    *consumed = io.consumed;
    *produced = io.produced;
    return result;
}

void flint_codec_free(flint_codec_state *state) {
    if (!state) return;
    if (state->native) state->vtable->destroy(state);
    free(state);
}
