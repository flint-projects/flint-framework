#ifndef FLINT_WASI_ABI_H
#define FLINT_WASI_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct flint_wasi_compiled flint_wasi_compiled;

typedef struct flint_wasi_span {
    const char *data;
    size_t length;
} flint_wasi_span;

typedef struct flint_wasi_preopen {
    flint_wasi_span host, guest;
    unsigned writable;
} flint_wasi_preopen;

typedef struct flint_wasi_environment {
    flint_wasi_span name, value;
} flint_wasi_environment;

typedef struct flint_wasi_limits {
    uint64_t fuel;
    uint64_t memory_bytes;
    uint32_t table_elements;
    uint32_t instances;
    uint32_t output_bytes;
    int64_t wall_nanos;
} flint_wasi_limits;

enum flint_wasi_status {
    FLINT_WASI_OK, FLINT_WASI_ARGUMENT, FLINT_WASI_MEMORY, FLINT_WASI_CANCELLED,
    FLINT_WASI_TIMEOUT, FLINT_WASI_NOT_FOUND, FLINT_WASI_CONFLICT, FLINT_WASI_IO,
    FLINT_WASI_UNAVAILABLE, FLINT_WASI_UNSUPPORTED, FLINT_WASI_DENIED, FLINT_WASI_EXHAUSTED
};

enum flint_wasi_abi {
    FLINT_WASI_CORE, FLINT_WASI_PREVIEW1, FLINT_WASI_02, FLINT_WASI_03
};

int flint_wasi_compile(unsigned abi, const uint8_t *bytes, size_t length, flint_wasi_compiled **out);
void flint_wasi_compiled_release(flint_wasi_compiled *compiled);
int flint_wasi_instantiate(const flint_wasi_compiled *compiled, const flint_wasi_limits *limits,
                          const flint_wasi_preopen *preopens, size_t preopen_count,
                          const flint_wasi_environment *env, size_t env_count, unsigned network, uint64_t *out);
int flint_wasi_call_i32(uint64_t id, flint_wasi_span name, const int32_t *args, size_t count, int32_t *out);
int flint_wasi_interrupt(uint64_t id);
int flint_wasi_copy_output(uint64_t id, uint8_t **out, size_t *length);
void flint_wasi_output_free(uint8_t *output);
int flint_wasi_release(uint64_t id);

#ifdef __cplusplus
}
#endif
#endif
