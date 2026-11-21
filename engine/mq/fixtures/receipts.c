/* A provider rejection and a timed-out native delivery each retire exactly one token. */
#include "flint_mq.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void expect(flint_kafka_client *client, uint64_t token, int terminal)
{
    for (unsigned i = 0; i < 500; ++i) {
        flint_kafka_receipt receipt;
        const int outcome = flint_kafka_receipt_take(client, token, &receipt);
        if (outcome == FLINT_MQ_OK) {
            assert(receipt.token == token && receipt.status == terminal);
            assert(flint_kafka_receipt_take(client, token, &receipt) == FLINT_MQ_NOT_FOUND);
            return;
        }
        assert(outcome == FLINT_MQ_UNAVAILABLE);
        assert(flint_kafka_poll(client, 10) == FLINT_MQ_OK);
    }
    assert(0 && "missing correlated delivery result");
}

int main(int argc, char **argv)
{
    assert(argc == 3);
    flint_kafka_options config = {argv[1], "flint-receipts", NULL, 3000, 4 * 1024 * 1024, 2, 0};
    flint_kafka_client *client;
    assert(flint_kafka_open(&config, &client) == FLINT_MQ_OK);
    const size_t overflow = 2 * 1024 * 1024;
    uint8_t *large = malloc(overflow);
    assert(large);
    memset(large, 0xa7, overflow);
    assert(flint_kafka_produce(client, "flint-orders", NULL, 0, large, overflow, 81) == FLINT_MQ_OK);
    free(large);
    expect(client, 81, FLINT_MQ_EXHAUSTED);
    flint_kafka_free(client);

    config.brokers = argv[2];
    config.delivery_ms = 150;
    assert(flint_kafka_open(&config, &client) == FLINT_MQ_OK);
    const uint8_t body = 7;
    assert(flint_kafka_produce(client, "outage", NULL, 0, &body, 1, 982) == FLINT_MQ_OK);
    expect(client, 982, FLINT_MQ_TIMEOUT);
    flint_kafka_free(client);
    puts("Kafka provider rejection and native delivery timeout each retired one exact receipt token");
    return 0;
}
