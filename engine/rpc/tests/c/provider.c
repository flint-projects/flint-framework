#include "flint_rpc.h"
#include "echo.pb-c.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    static const char known_key[] = "dGhlIHNhbXBsZSBub25jZQ==";
    char hash[28];
    assert(flint_rpc_websocket_accept(known_key, sizeof(known_key) - 1, hash, sizeof(hash)) == 0);
    assert(memcmp(hash, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", sizeof(hash)) == 0);
    assert(flint_rpc_websocket_accept(known_key, sizeof(known_key) - 1, hash, sizeof(hash) - 1) != 0);
    assert(flint_rpc_websocket_accept(NULL, sizeof(known_key) - 1, hash, sizeof(hash)) != 0);

    const flint_proto_descriptor *schema =
        (const flint_proto_descriptor *)&flint__rpc__fixture__detail__descriptor;
    uint8_t memory[1024];
    uint8_t bytes[] = "hello";
    uint8_t wire[32];
    flint_proto_arena scratch = {memory + 1, sizeof(memory) - 1, 0, 0};
    flint_proto_field fields[] = {
        {.number = 1, .bits = 23},
        {.number = 2, .start = 0, .length = 5},
    };
    size_t length = 0;
    assert(flint_proto_pack_fields(schema, fields, 2, bytes, sizeof(bytes) - 1, &scratch, wire, sizeof(wire),
                                   &length) == FLINT_PROTO_OK);
    assert(length == 9);
    Flint__Rpc__Fixture__Detail native = FLINT__RPC__FIXTURE__DETAIL__INIT;
    native.id = 23;
    native.note = (char *)bytes;
    uint8_t direct[32];
    assert(flint__rpc__fixture__detail__pack(&native, direct) == length);
    assert(memcmp(direct, wire, length) == 0);
    assert(scratch.used == 0);

    flint_proto_field decoded[2];
    size_t count = 0;
    assert(flint_proto_unpack_fields(schema, wire, length, &scratch, decoded, 2, &count) == FLINT_PROTO_OK);
    assert(count == 2 && decoded[0].bits == 23 && decoded[1].length == 5);
    assert(memcmp(scratch.bytes + decoded[1].start, bytes, 5) == 0);
    scratch.used = 0;
    assert(flint_proto_unpack_fields(schema, wire, length - 1, &scratch, decoded, 2, &count) == FLINT_PROTO_INVALID);
    assert(count == 0 && scratch.used == 0);
    const flint_proto_field impossible = {.parent = 3, .number = 2};
    assert(flint_proto_pack_fields(schema, &impossible, 1, bytes, 5, &scratch, wire, sizeof(wire),
                                   &length) == FLINT_PROTO_INVALID);
    scratch.capacity = 4;
    assert(flint_proto_unpack_fields(schema, direct, 9, &scratch, decoded, 2, &count) == FLINT_PROTO_CAPACITY);
    assert(count == 0 && scratch.used == 0 && scratch.exhausted);
    puts("pinned native Protobuf shape, exact provider bytes, alignment and capacity, and WebSocket digest passed");
    return 0;
}
