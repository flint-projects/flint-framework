#ifndef FLINT_MQ_ABI_H
#define FLINT_MQ_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct flint_kafka_client flint_kafka_client;

enum flint_mq_status {
    FLINT_MQ_OK, FLINT_MQ_ARGUMENT, FLINT_MQ_MEMORY, FLINT_MQ_CANCELLED,
    FLINT_MQ_TIMEOUT, FLINT_MQ_NOT_FOUND, FLINT_MQ_CONFLICT, FLINT_MQ_IO,
    FLINT_MQ_UNAVAILABLE, FLINT_MQ_UNSUPPORTED, FLINT_MQ_DENIED, FLINT_MQ_EXHAUSTED
};

typedef struct flint_kafka_options {
    const char *brokers;
    const char *client_id;
    const char *ca_bundle;
    uint64_t delivery_ms;
    size_t byte_limit;
    uint32_t slots;
    uint8_t tls;
} flint_kafka_options;

typedef struct flint_kafka_receipt {
    int64_t offset;
    int32_t partition;
    int32_t status;
    uint64_t token;
} flint_kafka_receipt;

typedef struct flint_kafka_delivery {
    uint8_t *storage;
    size_t capacity;
    size_t topic_bytes;
    size_t key_bytes;
    size_t payload_bytes;
    uint64_t token;
    int64_t offset;
    int32_t partition;
    uint32_t listener;
} flint_kafka_delivery;

flint_kafka_client *flint_kafka_new(const char *brokers, const char *client_id);
int flint_kafka_open(const flint_kafka_options *options, flint_kafka_client **output);
int flint_kafka_produce(flint_kafka_client *client, const char *topic, const uint8_t *key, size_t key_length,
                       const uint8_t *payload, size_t payload_length, uint64_t token);
int flint_kafka_produce_id(flint_kafka_client *client, const char *topic, const uint8_t *key, size_t key_length,
                          const uint8_t *payload, size_t payload_length, const char *dedup, uint64_t token);
int flint_kafka_receipt_take(flint_kafka_client *client, uint64_t token, flint_kafka_receipt *output);
int flint_kafka_receipt_detach(flint_kafka_client *client, uint64_t token);
int flint_kafka_subscribe(flint_kafka_client *client, const char *topic, const char *group, uint32_t listener);
int flint_kafka_take(flint_kafka_client *client, flint_kafka_delivery *output);
int flint_kafka_decide(flint_kafka_client *client, uint64_t token, uint8_t action);
int flint_kafka_drain_begin(flint_kafka_client *client);
int flint_kafka_poll(flint_kafka_client *client, int timeout_ms);
int flint_kafka_commit(flint_kafka_client *client, const char *topic, int32_t partition, int64_t next_offset);
int flint_kafka_flush(flint_kafka_client *client, int timeout_ms);
void flint_kafka_free(flint_kafka_client *client);

#ifdef __cplusplus
}
#endif

#endif
