#define _POSIX_C_SOURCE 200809L
#include "flint_mq.h"

#if defined(__linux__) && defined(FLINT_HAS_LIBRDKAFKA)
#include <librdkafka/rdkafka.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* The producer delivery callback and consumer rebalance/commit callbacks run only on the worker. */
enum { MAX_TOPIC = 249, MAX_ID = 128, MAX_LISTENERS = 32, MAX_ASSIGNMENTS = 256 };
enum job_stage { EMPTY, SCHEDULED, SUBMITTED, RECEIPT };

typedef struct publish_job {
    enum job_stage state;
    bool detached;
    char topic[MAX_TOPIC + 1], dedup[MAX_ID + 1];
    uint8_t *storage;
    size_t payload, key;
    flint_kafka_receipt receipt;
} publish_job;

typedef struct subscription subscription;
typedef struct assignment assignment;
typedef struct delivery delivery;

struct flint_kafka_client {
    pthread_t thread;
    pthread_mutex_t lock;
    rd_kafka_t *producer;
    publish_job *jobs;
    subscription *subscriptions;
    delivery *deliveries;
    assignment *partitions;
    size_t byte_limit, used_bytes;
    uint32_t slots, active;
    uint64_t delivery_ms, consumer_token, generation;
    bool tls, stopping, draining;
    char *brokers, *client_id, *ca_bundle;
};

static void consumer_step(flint_kafka_client *client);
static int consumer_storage(flint_kafka_client *client);
static void consumer_dispose(flint_kafka_client *client);
static bool consumer_drained(flint_kafka_client *client);

static int provider_status(rd_kafka_resp_err_t error)
{
    switch (error) {
    case RD_KAFKA_RESP_ERR_NO_ERROR: return FLINT_MQ_OK;
    case RD_KAFKA_RESP_ERR__QUEUE_FULL: return FLINT_MQ_EXHAUSTED;
    case RD_KAFKA_RESP_ERR__MSG_TIMED_OUT:
    case RD_KAFKA_RESP_ERR__TIMED_OUT: return FLINT_MQ_TIMEOUT;
    case RD_KAFKA_RESP_ERR_TOPIC_AUTHORIZATION_FAILED:
    case RD_KAFKA_RESP_ERR_GROUP_AUTHORIZATION_FAILED: return FLINT_MQ_DENIED;
    case RD_KAFKA_RESP_ERR_MSG_SIZE_TOO_LARGE: return FLINT_MQ_EXHAUSTED;
    case RD_KAFKA_RESP_ERR__INVALID_ARG: return FLINT_MQ_ARGUMENT;
    case RD_KAFKA_RESP_ERR__PURGE_QUEUE:
    case RD_KAFKA_RESP_ERR__PURGE_INFLIGHT: return FLINT_MQ_CANCELLED;
    default: return FLINT_MQ_IO;
    }
}

static void pause_ms(unsigned milliseconds)
{
    const struct timespec pause = { milliseconds / 1000, (long)(milliseconds % 1000) * 1000000L };
    nanosleep(&pause, NULL);
}

static bool valid_topic(const char *topic)
{
    if (!topic)
        return false;
    const size_t length = strnlen(topic, MAX_TOPIC + 1);
    if (!length || length > MAX_TOPIC || strcmp(topic, ".") == 0 || strcmp(topic, "..") == 0)
        return false;
    for (size_t i = 0; i < length; ++i) {
        const char c = topic[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
                || c == '.' || c == '_' || c == '-'))
            return false;
    }
    return true;
}

static bool configure(rd_kafka_conf_t *config, const char *name, const char *value)
{
    return rd_kafka_conf_set(config, name, value, NULL, 0) == RD_KAFKA_CONF_OK;
}

static bool configure_count(rd_kafka_conf_t *config, const char *name, uint64_t count)
{
    char digits[32];
    snprintf(digits, sizeof(digits), "%llu", (unsigned long long)count);
    return configure(config, name, digits);
}

static bool common_options(flint_kafka_client *client, rd_kafka_conf_t *config)
{
    return configure(config, "bootstrap.servers", client->brokers)
        && configure(config, "client.id", client->client_id)
        && configure(config, "log_level", "0")
        && configure(config, "security.protocol", client->tls ? "ssl" : "plaintext")
        && (!client->tls || (configure(config, "enable.ssl.certificate.verification", "true")
            && configure(config, "ssl.endpoint.identification.algorithm", "https")
            && (!client->ca_bundle || configure(config, "ssl.ca.location", client->ca_bundle))));
}

static void retire_job(flint_kafka_client *client, publish_job *job)
{
    free(job->storage);
    *job = (publish_job){0};
    --client->active;
}

static void finish_job(flint_kafka_client *client, publish_job *job, int status, int32_t partition, int64_t offset)
{
    client->used_bytes -= job->payload + job->key;
    job->receipt.status = status;
    job->receipt.partition = partition;
    job->receipt.offset = offset;
    if (job->detached)
        retire_job(client, job);
    else
        job->state = RECEIPT;
}

static void report(rd_kafka_t *producer, const rd_kafka_message_t *message, void *opaque)
{
    (void)producer;
    flint_kafka_client *client = opaque;
    publish_job *job = message->_private;
    pthread_mutex_lock(&client->lock);
    if (job && job->state == SUBMITTED)
        finish_job(client, job, provider_status(message->err), message->partition, message->offset);
    pthread_mutex_unlock(&client->lock);
}

static int producer_setup(flint_kafka_client *client)
{
    rd_kafka_conf_t *config = rd_kafka_conf_new();
    const bool configured = common_options(client, config)
        && configure(config, "enable.idempotence", "true")
        && configure(config, "acks", "all")
        && configure(config, "message.copy.max.bytes", "0")
        && configure_count(config, "queue.buffering.max.messages", client->slots)
        && configure_count(config, "queue.buffering.max.kbytes", (client->byte_limit + 1023) / 1024)
        && configure_count(config, "delivery.timeout.ms", client->delivery_ms);
    if (!configured) {
        rd_kafka_conf_destroy(config);
        return FLINT_MQ_ARGUMENT;
    }
    rd_kafka_conf_set_opaque(config, client);
    rd_kafka_conf_set_dr_msg_cb(config, report);
    client->producer = rd_kafka_new(RD_KAFKA_PRODUCER, config, NULL, 0);
    if (!client->producer)
        rd_kafka_conf_destroy(config);
    return client->producer ? FLINT_MQ_OK : FLINT_MQ_UNAVAILABLE;
}

static rd_kafka_resp_err_t submit(flint_kafka_client *client, publish_job *job)
{
    rd_kafka_vu_t request[] = {
        { .vtype = RD_KAFKA_VTYPE_TOPIC, .u.cstr = job->topic },
        { .vtype = RD_KAFKA_VTYPE_MSGFLAGS, .u.i = RD_KAFKA_MSG_F_FREE },
        { .vtype = RD_KAFKA_VTYPE_VALUE, .u.mem = { job->storage, job->payload } },
        { .vtype = RD_KAFKA_VTYPE_KEY, .u.mem = { job->storage + job->payload, job->key } },
        { .vtype = RD_KAFKA_VTYPE_OPAQUE, .u.ptr = job },
        { .vtype = RD_KAFKA_VTYPE_HEADER, .u.header = { "flint.idempotency-key", job->dedup, -1 } },
    };
    size_t count = sizeof(request) / sizeof(request[0]);
    rd_kafka_error_t *error = rd_kafka_produceva(client->producer, request, count - !job->dedup[0]);
    if (!error) {
        job->storage = NULL;
        job->state = SUBMITTED;
        return RD_KAFKA_RESP_ERR_NO_ERROR;
    }
    const rd_kafka_resp_err_t status = rd_kafka_error_code(error);
    rd_kafka_error_destroy(error);
    return status;
}

static void progress_jobs(flint_kafka_client *client)
{
    pthread_mutex_lock(&client->lock);
    for (uint32_t i = 0; i < client->slots; ++i) {
        publish_job *job = &client->jobs[i];
        if (job->state != SCHEDULED)
            continue;
        const rd_kafka_resp_err_t status = submit(client, job);
        if (status == RD_KAFKA_RESP_ERR__QUEUE_FULL)
            break;
        if (status != RD_KAFKA_RESP_ERR_NO_ERROR) {
            free(job->storage);
            job->storage = NULL;
            finish_job(client, job, provider_status(status), -1, -1);
        }
    }
    pthread_mutex_unlock(&client->lock);
}

static void *worker(void *opaque)
{
    flint_kafka_client *client = opaque;
    for (;;) {
        pthread_mutex_lock(&client->lock);
        const bool stop = client->stopping;
        pthread_mutex_unlock(&client->lock);
        if (stop)
            break;
        progress_jobs(client);
        consumer_step(client);
        rd_kafka_poll(client->producer, 5);
    }
    consumer_dispose(client);
    rd_kafka_purge(client->producer, RD_KAFKA_PURGE_F_QUEUE | RD_KAFKA_PURGE_F_INFLIGHT);
    rd_kafka_poll(client->producer, 0);
    rd_kafka_destroy(client->producer);
    return NULL;
}

static void release_client(flint_kafka_client *client)
{
    for (uint32_t i = 0; i < client->slots; ++i)
        free(client->jobs[i].storage);
    free(client->jobs);
    free(client->brokers);
    free(client->client_id);
    free(client->ca_bundle);
    pthread_mutex_destroy(&client->lock);
    free(client);
}

int flint_kafka_open(const flint_kafka_options *options, flint_kafka_client **output)
{
    if (!options || !output || !options->brokers || !options->brokers[0] || !options->client_id
        || !options->client_id[0] || !options->slots || options->slots > 1024 || !options->byte_limit
        || options->byte_limit > 16 * 1024 * 1024 || !options->delivery_ms || options->delivery_ms > 900000)
        return FLINT_MQ_ARGUMENT;
    *output = NULL;
    flint_kafka_client *client = calloc(1, sizeof(*client));
    if (!client)
        return FLINT_MQ_MEMORY;
    if (pthread_mutex_init(&client->lock, NULL) != 0) {
        free(client);
        return FLINT_MQ_UNAVAILABLE;
    }
    client->jobs = calloc(options->slots, sizeof(*client->jobs));
    client->brokers = strdup(options->brokers);
    client->client_id = strdup(options->client_id);
    client->ca_bundle = options->ca_bundle ? strdup(options->ca_bundle) : NULL;
    client->slots = client->jobs ? options->slots : 0;
    client->byte_limit = options->byte_limit;
    client->delivery_ms = options->delivery_ms;
    client->tls = options->tls != 0;
    int status = FLINT_MQ_MEMORY;
    if (client->jobs && client->brokers && client->client_id && (!options->ca_bundle || client->ca_bundle)) {
        status = consumer_storage(client);
        if (!status)
            status = producer_setup(client);
        if (!status && pthread_create(&client->thread, NULL, worker, client) != 0)
            status = FLINT_MQ_UNAVAILABLE;
    }
    if (status) {
        if (client->producer)
            rd_kafka_destroy(client->producer);
        consumer_dispose(client);
        release_client(client);
        return status;
    }
    *output = client;
    return FLINT_MQ_OK;
}

flint_kafka_client *flint_kafka_new(const char *brokers, const char *client_id)
{
    const flint_kafka_options settings = { brokers, client_id, NULL, 30000, 16 * 1024 * 1024, 1024, 0 };
    flint_kafka_client *client = NULL;
    flint_kafka_open(&settings, &client);
    return client;
}

static publish_job *find_job(flint_kafka_client *client, uint64_t token)
{
    for (uint32_t i = 0; i < client->slots; ++i)
        if (client->jobs[i].state != EMPTY && client->jobs[i].receipt.token == token)
            return &client->jobs[i];
    return NULL;
}

/* Locked by the caller; no callback is run from this admission path. */
static int reserve_job(flint_kafka_client *client, const char *topic, const uint8_t *key, size_t key_length,
                       const uint8_t *payload, size_t payload_length, const char *dedup, uint64_t token)
{
    if (client->draining || client->stopping || find_job(client, token))
        return FLINT_MQ_CONFLICT;
    const size_t total = key_length + payload_length;
    if (client->active == client->slots || total > client->byte_limit - client->used_bytes)
        return FLINT_MQ_EXHAUSTED;
    uint32_t index = 0;
    while (client->jobs[index].state != EMPTY)
        ++index;
    publish_job *job = &client->jobs[index];
    uint8_t *storage = malloc(total ? total : 1);
    if (!storage)
        return FLINT_MQ_MEMORY;
    if (payload_length)
        memcpy(storage, payload, payload_length);
    if (key_length)
        memcpy(storage + payload_length, key, key_length);
    snprintf(job->topic, sizeof(job->topic), "%s", topic);
    if (dedup)
        snprintf(job->dedup, sizeof(job->dedup), "%s", dedup);
    job->storage = storage;
    job->payload = payload_length;
    job->key = key_length;
    job->receipt.token = token;
    job->state = SCHEDULED;
    ++client->active;
    client->used_bytes += total;
    return FLINT_MQ_OK;
}

int flint_kafka_produce_id(flint_kafka_client *client, const char *topic, const uint8_t *key, size_t key_length,
                          const uint8_t *payload, size_t payload_length, const char *dedup, uint64_t token)
{
    if (!client || !token || !valid_topic(topic) || (key_length && !key) || (payload_length && !payload)
        || key_length > 4096 || payload_length > client->byte_limit
        || (dedup && strnlen(dedup, MAX_ID + 1) > MAX_ID))
        return FLINT_MQ_ARGUMENT;
    pthread_mutex_lock(&client->lock);
    const int status = reserve_job(client, topic, key, key_length, payload, payload_length, dedup, token);
    pthread_mutex_unlock(&client->lock);
    return status;
}

int flint_kafka_produce(flint_kafka_client *client, const char *topic, const uint8_t *key, size_t key_length,
                       const uint8_t *payload, size_t payload_length, uint64_t token)
{
    return flint_kafka_produce_id(client, topic, key, key_length, payload, payload_length, NULL, token);
}

int flint_kafka_receipt_take(flint_kafka_client *client, uint64_t token, flint_kafka_receipt *output)
{
    if (!client || !output || !token)
        return FLINT_MQ_ARGUMENT;
    pthread_mutex_lock(&client->lock);
    publish_job *job = find_job(client, token);
    int status = job ? FLINT_MQ_UNAVAILABLE : FLINT_MQ_NOT_FOUND;
    if (job && job->state == RECEIPT) {
        *output = job->receipt;
        retire_job(client, job);
        status = FLINT_MQ_OK;
    }
    pthread_mutex_unlock(&client->lock);
    return status;
}

int flint_kafka_receipt_detach(flint_kafka_client *client, uint64_t token)
{
    if (!client || !token)
        return FLINT_MQ_ARGUMENT;
    pthread_mutex_lock(&client->lock);
    publish_job *job = find_job(client, token);
    if (job && job->state == RECEIPT)
        retire_job(client, job);
    else if (job)
        job->detached = true;
    pthread_mutex_unlock(&client->lock);
    return job ? FLINT_MQ_OK : FLINT_MQ_NOT_FOUND;
}

int flint_kafka_drain_begin(flint_kafka_client *client)
{
    if (!client)
        return FLINT_MQ_ARGUMENT;
    pthread_mutex_lock(&client->lock);
    client->draining = true;
    pthread_mutex_unlock(&client->lock);
    return FLINT_MQ_OK;
}

int flint_kafka_poll(flint_kafka_client *client, int timeout_ms)
{
    if (!client || timeout_ms < 0 || timeout_ms > 10)
        return FLINT_MQ_ARGUMENT;
    if (timeout_ms)
        pause_ms((unsigned)timeout_ms);
    return FLINT_MQ_OK;
}

int flint_kafka_flush(flint_kafka_client *client, int timeout_ms)
{
    const int polled = flint_kafka_poll(client, timeout_ms);
    if (polled)
        return polled;
    pthread_mutex_lock(&client->lock);
    bool drained = consumer_drained(client);
    for (uint32_t i = 0; drained && i < client->slots; ++i)
        drained = client->jobs[i].state == EMPTY || client->jobs[i].state == RECEIPT;
    pthread_mutex_unlock(&client->lock);
    return drained ? FLINT_MQ_OK : FLINT_MQ_UNAVAILABLE;
}

void flint_kafka_free(flint_kafka_client *client)
{
    if (!client)
        return;
    pthread_mutex_lock(&client->lock);
    client->stopping = true;
    pthread_mutex_unlock(&client->lock);
    pthread_join(client->thread, NULL);
    release_client(client);
}

#include "flint_mq_consumer.inc"
#endif
