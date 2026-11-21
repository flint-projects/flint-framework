#include "flint_codec_private.h"

#if FLINT_HAS_ZLIB
#include <limits.h>
#include <string.h>
#include <zlib.h>

typedef struct gzip_stream {
    z_stream stream;
    uint8_t pending[8192];
    size_t first;
    size_t end;
    int acknowledged;
} gzip_stream;

static voidpf gzip_alloc(voidpf state, uInt count, uInt length) {
    if (count && length > SIZE_MAX / count) return NULL;
    return flint_codec_alloc(state, (size_t)count * length);
}

static void gzip_free(voidpf state, voidpf buffer) {
    flint_codec_dealloc(state, buffer);
}

static int valid_level(int level) {
    return level >= Z_DEFAULT_COMPRESSION && level <= Z_BEST_COMPRESSION;
}

static int create(flint_codec_state *state, int level) {
    gzip_stream *owned = flint_codec_alloc(state, sizeof(*owned));
    if (!owned) return flint_codec_allocation_error(state);
    z_stream *stream = &owned->stream;
    stream->zalloc = gzip_alloc;
    stream->zfree = gzip_free;
    stream->opaque = state;
    const int result = state->encode
        ? deflateInit2(stream, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY)
        : inflateInit2(stream, 15 + 16);
    if (result == Z_OK) {
        state->native = owned;
        return FLINT_CODEC_OK;
    }
    flint_codec_dealloc(state, owned);
    return result == Z_MEM_ERROR ? flint_codec_allocation_error(state) : FLINT_CODEC_INVALID;
}

static int upstream(flint_codec_state *state, flint_codec_io *io) {
    gzip_stream *owned = state->native;
    z_stream *stream = &owned->stream;
    const uInt input = io->input_length > UINT_MAX ? UINT_MAX : (uInt)io->input_length;
    const uInt output = io->capacity > UINT_MAX ? UINT_MAX : (uInt)io->capacity;
    stream->next_in = (Bytef *)io->input;
    stream->avail_in = input;
    stream->next_out = io->output;
    stream->avail_out = output;
    const int finish = input < io->input_length ? Z_NO_FLUSH :
        (io->finish == 2 ? Z_FINISH : io->finish == 1 ? Z_SYNC_FLUSH : Z_NO_FLUSH);
    const int result = state->encode ? deflate(stream, finish) : inflate(stream, Z_NO_FLUSH);
    io->consumed = input - stream->avail_in;
    io->produced = output - stream->avail_out;
    stream->next_in = NULL;
    stream->next_out = NULL;
    if (result == Z_STREAM_END) return FLINT_CODEC_FINISHED;
    if (result == Z_NEED_DICT) return FLINT_CODEC_DICTIONARY;
    if (result == Z_MEM_ERROR) return flint_codec_allocation_error(state);
    if (result != Z_OK && result != Z_BUF_ERROR) return FLINT_CODEC_INVALID;
    return !state->encode && io->consumed == io->input_length && io->produced < io->capacity
        ? FLINT_CODEC_NEED_INPUT : FLINT_CODEC_OK;
}

static void drain(gzip_stream *owned, flint_codec_io *io) {
    const size_t pending = owned->end - owned->first;
    io->produced = pending < io->capacity ? pending : io->capacity;
    memcpy(io->output, owned->pending + owned->first, io->produced);
    owned->first += io->produced;
}

static int step(flint_codec_state *state, flint_codec_io *io) {
    gzip_stream *owned = state->native;
    if (owned->first < owned->end) {
        drain(owned, io);
        if (owned->first == owned->end && io->produced < io->capacity) owned->acknowledged = 0;
        return FLINT_CODEC_OK;
    }
    if (owned->acknowledged) {
        owned->acknowledged = 0;
        if (!io->input_length && io->finish == 1) return FLINT_CODEC_OK;
    }
    if (!state->encode || io->finish != 1 || io->capacity > 6) return upstream(state, io);

    /* zlib needs spare bytes beyond a sync marker. Keep short caller buffers independent. */
    flint_codec_io staging = *io;
    staging.output = owned->pending;
    staging.capacity = sizeof(owned->pending);
    const int result = upstream(state, &staging);
    if (result != FLINT_CODEC_OK) return result;
    owned->first = 0;
    owned->end = staging.produced;
    owned->acknowledged = staging.produced < staging.capacity &&
        staging.consumed == staging.input_length;
    io->consumed = staging.consumed;
    drain(owned, io);
    if (owned->first == owned->end && io->produced < io->capacity) owned->acknowledged = 0;
    return FLINT_CODEC_OK;
}

static void destroy(flint_codec_state *state) {
    gzip_stream *owned = state->native;
    z_stream *stream = &owned->stream;
    if (state->encode) deflateEnd(stream);
    else inflateEnd(stream);
    flint_codec_dealloc(state, owned);
}

const flint_codec_provider flint_gzip_provider = {valid_level, create, step, destroy};
#endif
