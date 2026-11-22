/* Included by flint_mq.c. These data tables are shared only under the client's lock. */
enum delivery_stage { DELIVERY_FREE, DELIVERY_READY, DELIVERY_HELD, DELIVERY_ACKED, DELIVERY_RETRY };

struct subscription {
    flint_kafka_client *client;
    rd_kafka_t *consumer;
    rd_kafka_queue_t *queue;
    char topic[MAX_TOPIC + 1];
    uint64_t generation, commit_generation, retry_commit_at;
    uint32_t listener;
    bool commit_active;
    int error;
};

struct assignment {
    subscription *subscription;
    int32_t partition;
    int64_t next_offset, committed;
    size_t blocked_bytes;
    uint64_t generation;
    unsigned head, tail;
    bool paused, oversize;
};

struct delivery {
    enum delivery_stage state;
    flint_kafka_delivery view;
    assignment *assignment;
    uint64_t generation, retry_at;
    unsigned next;
};

#define NO_SLOT UINT32_MAX
#define NO_OFFSET INT64_MIN

static uint64_t monotonic_ms(void)
{
    struct timespec time;
    clock_gettime(FLINT_DEADLINE_CLOCK, &time);
    return (uint64_t)time.tv_sec * 1000 + (uint64_t)time.tv_nsec / 1000000;
}

static int consumer_storage(flint_kafka_client *client)
{
    client->subscriptions = calloc(MAX_LISTENERS, sizeof(*client->subscriptions));
    client->partitions = calloc(MAX_ASSIGNMENTS, sizeof(*client->partitions));
    client->deliveries = calloc(client->slots, sizeof(*client->deliveries));
    return client->subscriptions && client->partitions && client->deliveries ? FLINT_MQ_OK : FLINT_MQ_MEMORY;
}

static void consumer_dispose(flint_kafka_client *client)
{
    if (client->subscriptions) {
        for (unsigned i = 0; i < MAX_LISTENERS; ++i) {
            subscription *sub = &client->subscriptions[i];
            if (sub->queue)
                rd_kafka_queue_destroy(sub->queue);
            if (sub->consumer)
                rd_kafka_destroy_flags(sub->consumer, RD_KAFKA_DESTROY_F_NO_CONSUMER_CLOSE);
        }
    }
    if (client->deliveries) {
        for (unsigned i = 0; i < client->slots; ++i)
            free(client->deliveries[i].view.storage);
    }
    free(client->subscriptions);
    free(client->partitions);
    free(client->deliveries);
}

static void free_delivery_bytes(flint_kafka_client *client, delivery *record)
{
    client->used_bytes -= record->view.capacity;
    free(record->view.storage);
    record->view.storage = NULL;
    record->view.capacity = 0;
}

static void forget_delivery(flint_kafka_client *client, delivery *record)
{
    free_delivery_bytes(client, record);
    *record = (delivery){0};
}

static void release_assignment(flint_kafka_client *client, assignment *part)
{
    unsigned item = part->head;
    while (item != NO_SLOT) {
        delivery *record = &client->deliveries[item];
        item = record->next;
        if (record->state == DELIVERY_HELD)
            record->assignment = NULL; /* The owner may still be inside its arena visitor. */
        else
            forget_delivery(client, record);
    }
    *part = (assignment){0};
}

static void revoke(subscription *sub)
{
    flint_kafka_client *client = sub->client;
    for (unsigned i = 0; i < MAX_ASSIGNMENTS; ++i) {
        assignment *part = &client->partitions[i];
        if (part->subscription == sub)
            release_assignment(client, part);
    }
}

static bool reserve_assignments(subscription *sub, const rd_kafka_topic_partition_list_t *parts)
{
    flint_kafka_client *client = sub->client;
    if (!parts || client->generation == UINT64_MAX || parts->cnt > MAX_ASSIGNMENTS)
        return false;
    sub->generation = ++client->generation;
    unsigned index = 0;
    for (int p = 0; p < parts->cnt; ++p) {
        while (index < MAX_ASSIGNMENTS && client->partitions[index].subscription)
            ++index;
        if (index == MAX_ASSIGNMENTS) {
            revoke(sub);
            return false;
        }
        client->partitions[index++] = (assignment){ .subscription = sub, .partition = parts->elems[p].partition,
            .next_offset = NO_OFFSET, .committed = NO_OFFSET,
            .generation = sub->generation, .head = NO_SLOT, .tail = NO_SLOT };
    }
    return true;
}

static void rebalance(rd_kafka_t *consumer, rd_kafka_resp_err_t event, rd_kafka_topic_partition_list_t *parts,
                      void *opaque)
{
    subscription *sub = opaque;
    flint_kafka_client *client = sub->client;
    pthread_mutex_lock(&client->lock);
    revoke(sub);
    const bool assigned = event == RD_KAFKA_RESP_ERR__ASSIGN_PARTITIONS;
    const bool accepted = assigned && !client->draining && reserve_assignments(sub, parts);
    if (assigned && !client->draining && !accepted)
        sub->error = FLINT_MQ_EXHAUSTED;
    pthread_mutex_unlock(&client->lock);
    const rd_kafka_resp_err_t configured = rd_kafka_assign(consumer, accepted ? parts : NULL);
    if (configured != RD_KAFKA_RESP_ERR_NO_ERROR) {
        pthread_mutex_lock(&client->lock);
        revoke(sub);
        sub->error = provider_status(configured);
        pthread_mutex_unlock(&client->lock);
    }
}

static int consumer_setup(flint_kafka_client *client, subscription *sub, const char *group)
{
    rd_kafka_conf_t *config = rd_kafka_conf_new();
    const uint64_t fetch_window = client->byte_limit < 1024 * 1024 ? client->byte_limit : 1024 * 1024;
    const bool configured = common_options(client, config)
        && configure(config, "group.id", group)
        && configure(config, "enable.auto.commit", "false")
        && configure(config, "enable.auto.offset.store", "false")
        && configure(config, "auto.offset.reset", "earliest")
        && configure(config, "partition.assignment.strategy", "range")
        && configure(config, "queued.min.messages", "1")
        && configure_count(config, "fetch.message.max.bytes", fetch_window)
        && configure_count(config, "queued.max.messages.kbytes", (client->byte_limit + 1023) / 1024);
    if (!configured) {
        rd_kafka_conf_destroy(config);
        return FLINT_MQ_ARGUMENT;
    }
    rd_kafka_conf_set_opaque(config, sub);
    rd_kafka_conf_set_rebalance_cb(config, rebalance);
    sub->consumer = rd_kafka_new(RD_KAFKA_CONSUMER, config, NULL, 0);
    if (!sub->consumer) {
        rd_kafka_conf_destroy(config);
        return FLINT_MQ_UNAVAILABLE;
    }
    rd_kafka_poll_set_consumer(sub->consumer);
    sub->queue = rd_kafka_queue_get_consumer(sub->consumer);
    rd_kafka_topic_partition_list_t *topics = rd_kafka_topic_partition_list_new(1);
    rd_kafka_topic_partition_list_add(topics, sub->topic, RD_KAFKA_PARTITION_UA);
    const int status = provider_status(rd_kafka_subscribe(sub->consumer, topics));
    rd_kafka_topic_partition_list_destroy(topics);
    return status;
}

int flint_kafka_subscribe(flint_kafka_client *client, const char *topic, const char *group, uint32_t listener)
{
    if (!client || !valid_topic(topic) || !group || !group[0] || strnlen(group, MAX_ID + 1) > MAX_ID
        || listener >= MAX_LISTENERS)
        return FLINT_MQ_ARGUMENT;
    pthread_mutex_lock(&client->lock);
    subscription *sub = &client->subscriptions[listener];
    if (client->draining || client->stopping || sub->consumer) {
        pthread_mutex_unlock(&client->lock);
        return FLINT_MQ_CONFLICT;
    }
    snprintf(sub->topic, sizeof(sub->topic), "%s", topic);
    sub->listener = listener;
    sub->client = client;
    const int status = consumer_setup(client, sub, group);
    if (status != FLINT_MQ_OK) {
        if (sub->queue)
            rd_kafka_queue_destroy(sub->queue);
        if (sub->consumer)
            rd_kafka_destroy_flags(sub->consumer, RD_KAFKA_DESTROY_F_NO_CONSUMER_CLOSE);
        *sub = (subscription){0};
    }
    pthread_mutex_unlock(&client->lock);
    return status;
}

static assignment *find_partition(flint_kafka_client *client, subscription *sub, int32_t partition)
{
    for (unsigned i = 0; i < MAX_ASSIGNMENTS; ++i) {
        assignment *part = &client->partitions[i];
        if (part->subscription == sub && part->partition == partition)
            return part;
    }
    return NULL;
}

static size_t aligned(size_t bytes)
{
    return (bytes + 7) & ~(size_t)7;
}

static unsigned free_slot(flint_kafka_client *client)
{
    for (unsigned i = 0; i < client->slots; ++i)
        if (client->deliveries[i].state == DELIVERY_FREE)
            return i;
    return NO_SLOT;
}

static bool copy_delivery(flint_kafka_client *client, assignment *part, unsigned i, const rd_kafka_message_t *message)
{
    const size_t topic_size = strlen(part->subscription->topic);
    const size_t key_pos = aligned(topic_size), data_pos = key_pos + aligned(message->key_len);
    const size_t record_bytes = data_pos + message->len;
    if (record_bytes > client->byte_limit - client->used_bytes)
        return false;
    const size_t remaining = client->byte_limit - client->used_bytes - record_bytes;
    const size_t scratch = message->len + 4096;
    const size_t capacity = record_bytes + (scratch < remaining ? scratch : remaining);
    uint8_t *bytes = malloc(capacity);
    if (!bytes) {
        part->subscription->error = FLINT_MQ_MEMORY;
        return false;
    }
    memcpy(bytes, part->subscription->topic, topic_size);
    if (message->key_len)
        memcpy(bytes + key_pos, message->key, message->key_len);
    if (message->len)
        memcpy(bytes + data_pos, message->payload, message->len);
    client->used_bytes += capacity;
    delivery *record = &client->deliveries[i];
    *record = (delivery){ .state = DELIVERY_READY, .assignment = part, .generation = part->generation,
        .next = NO_SLOT, .view = { bytes, capacity, topic_size, message->key_len, message->len, 0,
                                  message->offset, message->partition, part->subscription->listener } };
    if (part->head == NO_SLOT)
        part->head = i;
    else
        client->deliveries[part->tail].next = i;
    part->tail = i;
    return true;
}

static void pause_for_capacity(subscription *sub, int32_t partition, int64_t offset)
{
    rd_kafka_topic_partition_list_t *selection = rd_kafka_topic_partition_list_new(1);
    rd_kafka_topic_partition_t *target = rd_kafka_topic_partition_list_add(selection, sub->topic, partition);
    target->offset = offset;
    rd_kafka_error_t *seek = rd_kafka_seek_partitions(sub->consumer, selection, 0);
    if (seek)
        rd_kafka_error_destroy(seek);
    rd_kafka_pause_partitions(sub->consumer, selection);
    rd_kafka_topic_partition_list_destroy(selection);
}

static void receive_record(subscription *sub, const rd_kafka_message_t *message)
{
    flint_kafka_client *client = sub->client;
    pthread_mutex_lock(&client->lock);
    assignment *part = find_partition(client, sub, message->partition);
    if (!part || client->draining) {
        pthread_mutex_unlock(&client->lock);
        return;
    }
    if (message->offset < 0 || message->offset == INT64_MAX || (message->key_len && !message->key)
            || (message->len && !message->payload)) {
        sub->error = FLINT_MQ_IO;
        pthread_mutex_unlock(&client->lock);
        return;
    }
    const bool valid_lengths = message->key_len <= client->byte_limit && message->len <= client->byte_limit;
    const size_t required = valid_lengths ? aligned(strlen(sub->topic)) + aligned(message->key_len) + message->len : 0;
    const bool oversized = !valid_lengths || required > client->byte_limit;
    const unsigned slot = free_slot(client);
    const bool admitted = !oversized && !part->paused && slot != NO_SLOT && copy_delivery(client, part, slot, message);
    const bool pause = !admitted && !part->paused;
    if (pause) {
        part->blocked_bytes = required;
        part->paused = true;
        part->oversize = oversized;
        if (oversized)
            sub->error = FLINT_MQ_EXHAUSTED;
    }
    pthread_mutex_unlock(&client->lock);
    if (pause)
        pause_for_capacity(sub, message->partition, message->offset);
}

static void resume_ready_partitions(subscription *sub)
{
    flint_kafka_client *client = sub->client;
    pthread_mutex_lock(&client->lock);
    if (client->draining || free_slot(client) == NO_SLOT || client->used_bytes == client->byte_limit) {
        pthread_mutex_unlock(&client->lock);
        return;
    }
    rd_kafka_topic_partition_list_t *list = NULL;
    for (unsigned i = 0; i < MAX_ASSIGNMENTS; ++i) {
        assignment *part = &client->partitions[i];
        if (part->subscription == sub && part->paused && !part->oversize
                && part->blocked_bytes <= client->byte_limit - client->used_bytes) {
            if (!list)
                list = rd_kafka_topic_partition_list_new(1);
            rd_kafka_topic_partition_list_add(list, sub->topic, part->partition);
            part->paused = false;
        }
    }
    pthread_mutex_unlock(&client->lock);
    if (list) {
        rd_kafka_resume_partitions(sub->consumer, list);
        rd_kafka_topic_partition_list_destroy(list);
    }
}

static void acknowledge_prefix(flint_kafka_client *client, assignment *part)
{
    while (part->head != NO_SLOT) {
        delivery *record = &client->deliveries[part->head];
        if (record->state != DELIVERY_ACKED)
            break;
        part->next_offset = record->view.offset + 1;
        part->head = record->next;
        forget_delivery(client, record);
    }
    if (part->head == NO_SLOT)
        part->tail = NO_SLOT;
}

static void commit_report(rd_kafka_t *consumer, rd_kafka_resp_err_t error,
                          rd_kafka_topic_partition_list_t *offsets, void *opaque)
{
    (void)consumer;
    subscription *sub = opaque;
    flint_kafka_client *client = sub->client;
    pthread_mutex_lock(&client->lock);
    sub->commit_active = false;
    if (error != RD_KAFKA_RESP_ERR_NO_ERROR)
        sub->retry_commit_at = monotonic_ms() + 100;
    if (error == RD_KAFKA_RESP_ERR_NO_ERROR && offsets) {
        for (int i = 0; i < offsets->cnt; ++i) {
            const rd_kafka_topic_partition_t *confirmed = &offsets->elems[i];
            assignment *part = find_partition(client, sub, confirmed->partition);
            if (part && part->generation == sub->commit_generation && !confirmed->err)
                part->committed = confirmed->offset;
        }
    }
    pthread_mutex_unlock(&client->lock);
}

static void commit_pending(subscription *sub)
{
    flint_kafka_client *client = sub->client;
    pthread_mutex_lock(&client->lock);
    if (sub->commit_active || sub->retry_commit_at > monotonic_ms()) {
        pthread_mutex_unlock(&client->lock);
        return;
    }
    rd_kafka_topic_partition_list_t *changes = NULL;
    for (unsigned i = 0; i < MAX_ASSIGNMENTS; ++i) {
        const assignment *part = &client->partitions[i];
        if (part->subscription == sub && part->next_offset > part->committed) {
            if (!changes)
                changes = rd_kafka_topic_partition_list_new(1);
            rd_kafka_topic_partition_list_add(changes, sub->topic, part->partition)->offset = part->next_offset;
        }
    }
    if (changes) {
        sub->commit_active = true;
        sub->commit_generation = sub->generation;
    }
    pthread_mutex_unlock(&client->lock);
    if (changes) {
        const rd_kafka_resp_err_t status = rd_kafka_commit_queue(sub->consumer, changes, sub->queue, commit_report, sub);
        if (status != RD_KAFKA_RESP_ERR_NO_ERROR)
            commit_report(sub->consumer, status, NULL, sub);
        rd_kafka_topic_partition_list_destroy(changes);
    }
}

static void consumer_step(flint_kafka_client *client)
{
    for (unsigned i = 0; i < MAX_LISTENERS; ++i) {
        subscription *sub = &client->subscriptions[i];
        pthread_mutex_lock(&client->lock);
        const bool live = sub->consumer != NULL;
        pthread_mutex_unlock(&client->lock);
        if (!live)
            continue;
        resume_ready_partitions(sub);
        rd_kafka_message_t *message = rd_kafka_consumer_poll(sub->consumer, 0);
        if (message && !message->err)
            receive_record(sub, message);
        if (message)
            rd_kafka_message_destroy(message);
        commit_pending(sub);
    }
}

static bool consumer_drained(flint_kafka_client *client)
{
    for (unsigned i = 0; i < client->slots; ++i)
        if (client->deliveries[i].state != DELIVERY_FREE)
            return false;
    for (unsigned i = 0; i < MAX_ASSIGNMENTS; ++i) {
        const assignment *part = &client->partitions[i];
        if (part->subscription && part->next_offset > part->committed)
            return false;
    }
    return true;
}

static delivery *next_delivery(flint_kafka_client *client)
{
    for (unsigned i = 0; i < client->slots; ++i) {
        delivery *record = &client->deliveries[i];
        if (record->state == DELIVERY_READY || (record->state == DELIVERY_RETRY && record->retry_at <= monotonic_ms()))
            return record;
    }
    return NULL;
}

int flint_kafka_take(flint_kafka_client *client, flint_kafka_delivery *output)
{
    if (!client || !output)
        return FLINT_MQ_ARGUMENT;
    pthread_mutex_lock(&client->lock);
    int status = FLINT_MQ_UNAVAILABLE;
    delivery *record = next_delivery(client);
    if (record && client->consumer_token != UINT64_MAX) {
        record->state = DELIVERY_HELD;
        record->view.token = ++client->consumer_token;
        *output = record->view;
        status = FLINT_MQ_OK;
    } else {
        for (unsigned i = 0; i < MAX_LISTENERS; ++i) {
            subscription *sub = &client->subscriptions[i];
            if (sub->error) {
                status = sub->error;
                sub->error = FLINT_MQ_OK;
                break;
            }
        }
    }
    pthread_mutex_unlock(&client->lock);
    return status;
}

static int decide_delivery(flint_kafka_client *client, delivery *record, uint8_t action)
{
    assignment *part = record->assignment;
    if (!part || part->generation != record->generation) {
        forget_delivery(client, record);
        return FLINT_MQ_CONFLICT;
    }
    if (action == 0) {
        free_delivery_bytes(client, record);
        record->state = DELIVERY_ACKED;
        acknowledge_prefix(client, part);
    } else {
        record->view.token = 0;
        record->retry_at = monotonic_ms() + 100;
        record->state = DELIVERY_RETRY;
    }
    return FLINT_MQ_OK;
}

int flint_kafka_decide(flint_kafka_client *client, uint64_t token, uint8_t action)
{
    if (!client || !token || action > 1)
        return FLINT_MQ_ARGUMENT;
    pthread_mutex_lock(&client->lock);
    int status = FLINT_MQ_NOT_FOUND;
    for (unsigned i = 0; i < client->slots; ++i) {
        delivery *record = &client->deliveries[i];
        if (record->state == DELIVERY_HELD && record->view.token == token) {
            status = decide_delivery(client, record, action);
            break;
        }
    }
    pthread_mutex_unlock(&client->lock);
    return status;
}

int flint_kafka_commit(flint_kafka_client *client, const char *topic, int32_t partition, int64_t next_offset)
{
    if (!client || !valid_topic(topic) || partition < 0 || next_offset < 0)
        return FLINT_MQ_ARGUMENT;
    pthread_mutex_lock(&client->lock);
    int status = FLINT_MQ_NOT_FOUND;
    for (unsigned i = 0; i < MAX_ASSIGNMENTS; ++i) {
        const assignment *part = &client->partitions[i];
        if (part->subscription && part->partition == partition && !strcmp(part->subscription->topic, topic)) {
            status = next_offset == part->next_offset ? FLINT_MQ_OK : FLINT_MQ_CONFLICT;
            break;
        }
    }
    pthread_mutex_unlock(&client->lock);
    return status;
}
