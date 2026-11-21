#ifndef FLINT_RPC_ABI_H
#define FLINT_RPC_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct flint_proto_descriptor flint_proto_descriptor;

typedef struct flint_proto_arena {
    uint8_t *bytes;
    size_t capacity;
    size_t used;
    int exhausted;
} flint_proto_arena;

enum flint_proto_result {
    FLINT_PROTO_OK = 0,
    FLINT_PROTO_INVALID = -1,
    FLINT_PROTO_CAPACITY = -2
};

int flint_proto_pack(const flint_proto_descriptor *descriptor, const void *message,
                    uint8_t *output, size_t capacity, size_t *written);
int flint_proto_unpack(const flint_proto_descriptor *descriptor, const uint8_t *input,
                      size_t input_length, void *arena_context, void **message);
void flint_proto_release(const flint_proto_descriptor *descriptor, void *message, void *arena_context);

/* A bounded, pointer-free scalar from a generated DTO. Parent zero denotes the root.
 * Other parent values are one plus the index of the containing message field. */
typedef struct flint_proto_field {
    uint32_t parent;
    uint32_t number;
    uint64_t bits;
    double decimal;
    size_t start;
    size_t length;
} flint_proto_field;

int flint_proto_pack_fields(const flint_proto_descriptor *descriptor, const flint_proto_field *fields,
                            size_t count, const uint8_t *bytes, size_t byte_count,
                            void *arena_context, uint8_t *output, size_t capacity, size_t *written);
int flint_proto_unpack_fields(const flint_proto_descriptor *descriptor, const uint8_t *input,
                              size_t input_length, void *arena_context, flint_proto_field *fields,
                              size_t capacity, size_t *count);

/* A canonical version 13 request key has 24 bytes. Success writes 28 accept bytes. */
int flint_rpc_websocket_accept(const char *key, size_t key_length, char *output, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif
