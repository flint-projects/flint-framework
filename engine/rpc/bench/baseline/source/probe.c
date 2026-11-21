#include "echo.pb-c.h"

#include <stdint.h>
#include <stdlib.h>

uint64_t flint_rpc_probe(unsigned size) {
    if (size != 128 && size != 65536)
        return 0;
    uint8_t payload[65536];
    uint8_t wire[65536 + 16];
    for (unsigned i = 0; i < size; ++i)
        payload[i] = (uint8_t)(i * 17 + 3);
    Flint__Rpc__Fixture__Envelope message = FLINT__RPC__FIXTURE__ENVELOPE__INIT;
    message.floor = -7;
    message.ceiling = 43;
    message.payload = (ProtobufCBinaryData){size, payload};

    if (!protobuf_c_message_check(&message.base))
        return 0;
    const size_t length = flint__rpc__fixture__envelope__get_packed_size(&message);
    if (length > sizeof(wire) || flint__rpc__fixture__envelope__pack(&message, wire) != length)
        return 0;
    Flint__Rpc__Fixture__Envelope *decoded = flint__rpc__fixture__envelope__unpack(NULL, length, wire);
    if (decoded == NULL)
        return 0;
    uint64_t checksum = 0;
    if (protobuf_c_message_check(&decoded->base) && decoded->floor == -7 && decoded->ceiling == 43 &&
            decoded->payload.len == size)
        checksum = length + 17 * decoded->payload.data[0] + 31 * decoded->payload.data[size - 1] + decoded->ceiling;
    flint__rpc__fixture__envelope__free_unpacked(decoded, NULL);
    return checksum;
}
