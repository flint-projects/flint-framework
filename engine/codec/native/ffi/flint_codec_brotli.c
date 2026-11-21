#include "flint_codec_private.h"

#if FLINT_HAS_BROTLI
#include <brotli/decode.h>
#include <brotli/encode.h>

static int valid_level(int level) {
    return level >= BROTLI_MIN_QUALITY && level <= BROTLI_MAX_QUALITY;
}

static int create(flint_codec_state *state, int level) {
    if (state->encode) {
        state->native = BrotliEncoderCreateInstance(flint_codec_alloc, flint_codec_dealloc, state);
        if (!state->native) return flint_codec_allocation_error(state);
        return BrotliEncoderSetParameter(state->native, BROTLI_PARAM_QUALITY, (uint32_t)level)
            ? FLINT_CODEC_OK : FLINT_CODEC_INVALID;
    }
    state->native = BrotliDecoderCreateInstance(flint_codec_alloc, flint_codec_dealloc, state);
    if (!state->native) return flint_codec_allocation_error(state);
    return BrotliDecoderSetParameter(state->native, BROTLI_DECODER_PARAM_LARGE_WINDOW, 0)
        ? FLINT_CODEC_OK : FLINT_CODEC_INVALID;
}

static int step(flint_codec_state *state, flint_codec_io *io) {
    const uint8_t *input = io->input;
    uint8_t *output = io->output;
    size_t remaining_in = io->input_length;
    size_t remaining_out = io->capacity;
    int status;
    if (state->encode) {
        const BrotliEncoderOperation operation = io->finish == 2 ? BROTLI_OPERATION_FINISH :
            io->finish == 1 ? BROTLI_OPERATION_FLUSH : BROTLI_OPERATION_PROCESS;
        const int result = BrotliEncoderCompressStream(state->native, operation, &remaining_in,
            &input, &remaining_out, &output, NULL);
        status = FLINT_CODEC_OK;
        if (!result) status = state->allocation_limit ? FLINT_CODEC_LIMIT : FLINT_CODEC_INVALID;
        else if (BrotliEncoderIsFinished(state->native)) status = FLINT_CODEC_FINISHED;
    } else {
        const BrotliDecoderResult result = BrotliDecoderDecompressStream(state->native, &remaining_in,
            &input, &remaining_out, &output, NULL);
        switch (result) {
        case BROTLI_DECODER_RESULT_SUCCESS: status = FLINT_CODEC_FINISHED; break;
        case BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT: status = FLINT_CODEC_NEED_INPUT; break;
        case BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT: status = FLINT_CODEC_OK; break;
        default:
            status = state->allocation_limit ? FLINT_CODEC_LIMIT : FLINT_CODEC_INVALID;
            break;
        }
    }
    io->consumed = io->input_length - remaining_in;
    io->produced = io->capacity - remaining_out;
    return status;
}

static void destroy(flint_codec_state *state) {
    if (state->encode) BrotliEncoderDestroyInstance(state->native);
    else BrotliDecoderDestroyInstance(state->native);
}

const flint_codec_provider flint_brotli_provider = {valid_level, create, step, destroy};
#endif
