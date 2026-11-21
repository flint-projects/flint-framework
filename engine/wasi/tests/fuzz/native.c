#define _POSIX_C_SOURCE 200809L
#include "flint_wasi.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const uint8_t sample[] = {
    0, 97, 115, 109, 1, 0, 0, 0,
    1, 5, 1, 96, 0, 1, 127,
    3, 2, 1, 0,
    7, 10, 1, 6, 97, 110, 115, 119, 101, 114, 0, 0,
    10, 6, 1, 4, 0, 65, 42, 11,
};
static const flint_wasi_limits limits = {1000000, 65536, 16, 1, 512, 100000000};
static const flint_wasi_span name = {"answer", 6};

static double seconds(void)
{
    struct timespec now;
    assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return now.tv_sec + now.tv_nsec / 1000000000.0;
}

static void scalar_lifetime(void)
{
    flint_wasi_compiled *code;
    assert(flint_wasi_compile(FLINT_WASI_CORE, sample, sizeof(sample), &code) == FLINT_WASI_OK);
    uint64_t old, current;
    assert(flint_wasi_instantiate(code, &limits, NULL, 0, NULL, 0, 0, &old) == FLINT_WASI_OK);
    assert(flint_wasi_release(old) == FLINT_WASI_OK);
    assert(flint_wasi_instantiate(code, &limits, NULL, 0, NULL, 0, 0, &current) == FLINT_WASI_OK);
    assert(current != old);
    flint_wasi_compiled_release(code);

    int32_t result = 42;
    assert(flint_wasi_call_i32(old, name, NULL, 0, &result) == FLINT_WASI_NOT_FOUND && result == 0);
    assert(flint_wasi_call_i32(current, name, NULL, SIZE_MAX, &result) == FLINT_WASI_ARGUMENT && result == 0);
    assert(flint_wasi_call_i32(current, (flint_wasi_span){"answer", SIZE_MAX}, NULL, 0, &result)
           == FLINT_WASI_ARGUMENT);
    assert(flint_wasi_call_i32(current, (flint_wasi_span){NULL, 1}, NULL, 0, &result) == FLINT_WASI_ARGUMENT);
    assert(flint_wasi_call_i32(current, name, NULL, 0, &result) == FLINT_WASI_OK && result == 42);
    uint8_t *output;
    size_t length;
    assert(flint_wasi_copy_output(current, &output, &length) == FLINT_WASI_OK && !output && length == 0);
    flint_wasi_output_free(output);
    assert(flint_wasi_release(current) == FLINT_WASI_OK);
    assert(flint_wasi_interrupt(current) == FLINT_WASI_NOT_FOUND);
}

static void try_module(const uint8_t *bytes, size_t length)
{
    flint_wasi_compiled *code = NULL;
    const int result = flint_wasi_compile(FLINT_WASI_CORE, bytes, length, &code);
    if (result == FLINT_WASI_OK) {
        assert(code);
        flint_wasi_compiled_release(code);
    } else {
        assert(result == FLINT_WASI_ARGUMENT && !code);
    }
}

int main(int argc, char **argv)
{
    const unsigned duration = argc == 2 ? (unsigned)strtoul(argv[1], NULL, 10) : 0;
    scalar_lifetime();
    uint8_t *input = calloc(1, 1048577);
    assert(input);
    memcpy(input, sample, sizeof(sample));
    for (size_t len = 0; len <= 256; ++len)
        try_module(input, len);
    const size_t boundaries[] = {1023, 1024, 1025, 1048575, 1048576, 1048577};
    for (size_t i = 0; i < sizeof(boundaries) / sizeof(*boundaries); ++i)
        try_module(input, boundaries[i]);
    try_module(NULL, SIZE_MAX);
    try_module(input, SIZE_MAX);
    free(input);

    uint32_t state = 0x198ac524;
    size_t mutations = 0;
    const double deadline = seconds() + duration;
    do {
        uint8_t bytes[sizeof(sample)];
        memcpy(bytes, sample, sizeof(bytes));
        const size_t index = state % sizeof(bytes);
        state = state * 1664525u + 1013904223u;
        bytes[index] = (uint8_t)(state >> 24);
        try_module(bytes, state % (sizeof(bytes) + 1));
        ++mutations;
    } while (seconds() < deadline);
    printf("WASI sanitizer corpus passed: 257 short spans, 6 long boundaries, %zu mutations and stale generations\n",
           mutations);
}
