#include "flint_codec_private.h"

#if FLINT_HAS_ZSTD
#define ZSTD_STATIC_LINKING_ONLY
#include <zstd.h>
#include <zstd_errors.h>

enum { MAX_WINDOW_LOG = 24 };

typedef struct zstd_decoder {
    ZSTD_DCtx *stream;
    uint8_t header[ZSTD_FRAMEHEADERSIZE_MAX];
    size_t header_length;
    int header_checked;
} zstd_decoder;

static int valid_level(int level) {
    return level >= ZSTD_minCLevel() && level <= ZSTD_maxCLevel();
}

static int convert(const flint_codec_state *state, size_t result) {
    switch (ZSTD_getErrorCode(result)) {
    case ZSTD_error_no_error: return FLINT_CODEC_OK;
    case ZSTD_error_memory_allocation: return flint_codec_allocation_error(state);
    case ZSTD_error_frameParameter_windowTooLarge: return FLINT_CODEC_LIMIT;
    case ZSTD_error_dictionary_corrupted:
    case ZSTD_error_dictionary_wrong:
    case ZSTD_error_dictionaryCreation_failed: return FLINT_CODEC_DICTIONARY;
    default: return FLINT_CODEC_INVALID;
    }
}

static int create_encoder(flint_codec_state *state, int level, ZSTD_customMem memory) {
    ZSTD_CCtx *stream = ZSTD_createCCtx_advanced(memory);
    if (!stream) return flint_codec_allocation_error(state);
    state->native = stream;
    size_t result = ZSTD_CCtx_setParameter(stream, ZSTD_c_compressionLevel, level);
    if (ZSTD_isError(result)) return convert(state, result);
    result = ZSTD_CCtx_setParameter(stream, ZSTD_c_windowLog, MAX_WINDOW_LOG);
    if (ZSTD_isError(result)) return convert(state, result);
    return convert(state, ZSTD_CCtx_setParameter(stream, ZSTD_c_checksumFlag, 1));
}

static int create_decoder(flint_codec_state *state, ZSTD_customMem memory) {
    zstd_decoder *decoder = flint_codec_alloc(state, sizeof(*decoder));
    if (!decoder) return flint_codec_allocation_error(state);
    state->native = decoder;
    decoder->stream = ZSTD_createDCtx_advanced(memory);
    if (!decoder->stream) return flint_codec_allocation_error(state);
    return convert(state, ZSTD_DCtx_setParameter(decoder->stream, ZSTD_d_windowLogMax, MAX_WINDOW_LOG));
}

static int create(flint_codec_state *state, int level) {
    const ZSTD_customMem memory = {flint_codec_alloc, flint_codec_dealloc, state};
    return state->encode ? create_encoder(state, level, memory) : create_decoder(state, memory);
}

static int encode(flint_codec_state *state, flint_codec_io *io) {
    ZSTD_inBuffer input = {io->input, io->input_length, 0};
    ZSTD_outBuffer output = {io->output, io->capacity, 0};
    const ZSTD_EndDirective directive =
        io->finish == 2 ? ZSTD_e_end : io->finish == 1 ? ZSTD_e_flush : ZSTD_e_continue;
    const size_t result = ZSTD_compressStream2(state->native, &output, &input, directive);
    io->consumed = input.pos;
    io->produced = output.pos;
    if (ZSTD_isError(result)) return convert(state, result);
    return result == 0 && io->finish == 2 ? FLINT_CODEC_FINISHED : FLINT_CODEC_OK;
}

static int read_header(flint_codec_state *state, zstd_decoder *decoder, flint_codec_io *io) {
    ZSTD_frameHeader frame;
    for (;;) {
        const size_t needed = ZSTD_getFrameHeader(&frame, decoder->header, decoder->header_length);
        if (ZSTD_isError(needed)) return convert(state, needed);
        if (!needed) break;
        if (needed > sizeof(decoder->header) || needed <= decoder->header_length) return FLINT_CODEC_INVALID;
        while (decoder->header_length < needed && io->consumed < io->input_length)
            decoder->header[decoder->header_length++] = io->input[io->consumed++];
        if (decoder->header_length < needed) return FLINT_CODEC_NEED_INPUT;
    }
    if (frame.frameType != ZSTD_frame) return FLINT_CODEC_INVALID;
    if (frame.windowSize > (1ULL << MAX_WINDOW_LOG)) return FLINT_CODEC_LIMIT;
    if (frame.dictID != 0) return FLINT_CODEC_DICTIONARY;

    ZSTD_inBuffer header = {decoder->header, decoder->header_length, 0};
    ZSTD_outBuffer output = {io->output, io->capacity, 0};
    const size_t result = ZSTD_decompressStream(decoder->stream, &output, &header);
    if (ZSTD_isError(result)) return convert(state, result);
    if (!result || header.pos != header.size || output.pos != 0) return FLINT_CODEC_INVALID;
    decoder->header_checked = 1;
    return FLINT_CODEC_OK;
}

static int decode(flint_codec_state *state, flint_codec_io *io) {
    zstd_decoder *decoder = state->native;
    if (!decoder->header_checked) {
        const int status = read_header(state, decoder, io);
        if (status != FLINT_CODEC_OK) return status;
    }
    ZSTD_inBuffer input = {io->input, io->input_length, io->consumed};
    ZSTD_outBuffer output = {io->output, io->capacity, 0};
    const size_t result = ZSTD_decompressStream(decoder->stream, &output, &input);
    io->consumed = input.pos;
    io->produced = output.pos;
    if (ZSTD_isError(result)) return convert(state, result);
    if (result == 0) return FLINT_CODEC_FINISHED;
    return input.pos == input.size && output.pos < output.size ? FLINT_CODEC_NEED_INPUT : FLINT_CODEC_OK;
}

static int step(flint_codec_state *state, flint_codec_io *io) {
    return state->encode ? encode(state, io) : decode(state, io);
}

static void destroy(flint_codec_state *state) {
    if (state->encode) ZSTD_freeCCtx(state->native);
    else {
        zstd_decoder *decoder = state->native;
        ZSTD_freeDCtx(decoder->stream);
        flint_codec_dealloc(state, decoder);
    }
}

const flint_codec_provider flint_zstd_provider = {valid_level, create, step, destroy};
#endif
