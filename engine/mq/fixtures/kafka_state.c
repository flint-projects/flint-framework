/* Verify delivery-order and rebalance behavior through the same native state machine. */
#include "flint_mq.c"

#include <assert.h>

static flint_kafka_delivery take(flint_kafka_client *client)
{
    flint_kafka_delivery received;
    const uint64_t deadline = monotonic_ms() + 20000;
    while (monotonic_ms() < deadline) {
        const int outcome = flint_kafka_take(client, &received);
        if (outcome == FLINT_MQ_OK)
            return received;
        assert(outcome == FLINT_MQ_UNAVAILABLE);
        pause_ms(2);
    }
    assert(0 && "broker did not assign a delivery");
    return (flint_kafka_delivery){0};
}

static void prefix_check(void)
{
    flint_kafka_client client = {.slots = 4, .byte_limit = 16384};
    assert(pthread_mutex_init(&client.lock, NULL) == 0);
    assert(consumer_storage(&client) == FLINT_MQ_OK);
    subscription *sub = &client.subscriptions[0];
    sub->client = &client;
    strcpy(sub->topic, "orders");
    rd_kafka_topic_partition_list_t *parts = rd_kafka_topic_partition_list_new(1);
    rd_kafka_topic_partition_list_add(parts, "orders", 0);
    assert(reserve_assignments(sub, parts));
    assignment *part = find_partition(&client, sub, 0);
    char payload[] = "record";
    for (unsigned i = 0; i < 3; ++i) {
        const rd_kafka_message_t wire = {.partition = 0, .offset = 10 + i, .payload = payload, .len = 6};
        assert(copy_delivery(&client, part, i, &wire));
    }
    const flint_kafka_delivery first = take(&client), second = take(&client), third = take(&client);
    assert(first.offset == 10 && second.offset == 11 && third.offset == 12);
    assert(flint_kafka_decide(&client, first.token, 0) == FLINT_MQ_OK && part->next_offset == 11);
    assert(flint_kafka_decide(&client, third.token, 0) == FLINT_MQ_OK && part->next_offset == 11);
    assert(flint_kafka_decide(&client, second.token, 0) == FLINT_MQ_OK && part->next_offset == 13);
    const rd_kafka_message_t held = {.partition = 0, .offset = 13, .payload = payload, .len = 6};
    assert(copy_delivery(&client, part, 0, &held));
    const flint_kafka_delivery during = take(&client);
    const uint64_t original_generation = part->generation;
    revoke(sub);
    assert(reserve_assignments(sub, parts));
    assert(client.partitions[0].generation > original_generation);
    assert(memcmp(during.storage + aligned(during.topic_bytes), payload, 6) == 0);
    assert(flint_kafka_decide(&client, during.token, 0) == FLINT_MQ_CONFLICT);
    assert(client.partitions[0].next_offset == NO_OFFSET && client.used_bytes == 0);
    rd_kafka_topic_partition_list_destroy(parts);
    consumer_dispose(&client);
    assert(pthread_mutex_destroy(&client.lock) == 0);
    puts("offsets 10,12,11 confirmed advancement 11,11,13; held generation invalidated on revoke");
}

static void publish_test(flint_kafka_client *connection, const char *topic)
{
    const char payload[] = "active handler";
    assert(flint_kafka_produce(connection, topic, NULL, 0, (const uint8_t *)payload, strlen(payload), 1) == FLINT_MQ_OK);
    const uint64_t deadline = monotonic_ms() + 10000;
    while (monotonic_ms() < deadline) {
        flint_kafka_receipt receipt;
        const int outcome = flint_kafka_receipt_take(connection, 1, &receipt);
        if (outcome == FLINT_MQ_OK) {
            assert(receipt.status == FLINT_MQ_OK && receipt.offset >= 0);
            return;
        }
        assert(outcome == FLINT_MQ_UNAVAILABLE);
        pause_ms(2);
    }
    assert(0 && "test broker did not acknowledge its message");
}

static void live_rebalance(const char *address, const char *topic, const char *group)
{
    const flint_kafka_options aconfig = {address, "flint-active", NULL, 6000, 65536, 8, 0};
    const flint_kafka_options bconfig = {address, "flint-new", NULL, 6000, 65536, 8, 0};
    flint_kafka_client *active = NULL, *joined = NULL;
    assert(flint_kafka_open(&aconfig, &active) == FLINT_MQ_OK);
    assert(flint_kafka_open(&bconfig, &joined) == FLINT_MQ_OK);
    assert(flint_kafka_subscribe(active, topic, group, 0) == FLINT_MQ_OK);
    publish_test(active, topic);
    const flint_kafka_delivery first = take(active);
    assert(first.offset >= 0);
    assert(flint_kafka_subscribe(joined, topic, group, 0) == FLINT_MQ_OK);
    const uint64_t deadline = monotonic_ms() + 20000;
    bool revoked = false;
    while (monotonic_ms() < deadline) {
        pthread_mutex_lock(&active->lock);
        for (unsigned i = 0; i < active->slots; ++i) {
            const delivery *value = &active->deliveries[i];
            if (value->state == DELIVERY_HELD && value->view.token == first.token && !value->assignment)
                revoked = true;
        }
        pthread_mutex_unlock(&active->lock);
        if (revoked)
            break;
        pause_ms(2);
    }
    assert(revoked);
    assert(memcmp(first.storage + aligned(first.topic_bytes), "active handler", first.payload_bytes) == 0);
    assert(flint_kafka_decide(active, first.token, 0) == FLINT_MQ_CONFLICT);
    assert(flint_kafka_decide(active, first.token, 0) == FLINT_MQ_NOT_FOUND);
    puts("real broker revoked a held generation while its bytes remained live; stale ack rejected");
    flint_kafka_free(joined);
    flint_kafka_free(active);
}

int main(int argc, char **argv)
{
    prefix_check();
    if (argc == 4)
        live_rebalance(argv[1], argv[2], argv[3]);
    return 0;
}
