/* Direct hiredis RESP3/TLS control for the checked benchmark workload. */
#define _POSIX_C_SOURCE 200809L
#include <hiredis/adapters/poll.h>
#include <hiredis/hiredis_ssl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct redis_reference {
    redisAsyncContext *client;
    redisSSLContext *tls;
    redisReply *reply;
    int finished;
} redis_reference;

static void connected(const redisAsyncContext *client, int status)
{
    (void)client;
    (void)status;
}

static void complete(redisAsyncContext *client, void *reply, void *context)
{
    (void)client;
    redis_reference *reference = context;
    reference->reply = reply;
    reference->finished = 1;
}

static redisReply *perform(redis_reference *reference, int count, const char **values, const size_t *sizes)
{
    reference->finished = 0;
    reference->reply = NULL;
    if (redisAsyncCommandArgv(reference->client, complete, reference, count, values, sizes) != REDIS_OK)
        return NULL;
    for (unsigned i = 0; !reference->finished && i < 1000; ++i)
        if (redisPollTick(reference->client, 0.005) < 0)
            break;
    return reference->reply;
}

void redis_probe_close(redis_reference *reference)
{
    if (!reference)
        return;
    redisAsyncFree(reference->client);
    redisFreeSSLContext(reference->tls);
    free(reference);
}

redis_reference *redis_probe_open(uint16_t port, const char *ca)
{
    redis_reference *reference = calloc(1, sizeof(*reference));
    if (!reference)
        return NULL;
    redisOptions options = {0};
    options.options = REDIS_OPT_NONBLOCK | REDIS_OPT_NOAUTOFREE | REDIS_OPT_NOAUTOFREEREPLIES;
    REDIS_OPTIONS_SET_TCP(&options, "127.0.0.1", port);
    reference->client = redisAsyncConnectWithOptions(&options);
    redisSSLOptions tls = {.cacert_filename = ca, .server_name = "localhost", .verify_mode = REDIS_SSL_VERIFY_PEER,
        .verify_name = "localhost"};
    reference->tls = redisCreateSSLContextWithOptions(&tls, NULL);
    if (!reference->client || reference->client->err || !reference->tls
        || redisInitiateSSLWithContext(&reference->client->c, reference->tls) != REDIS_OK
        || redisPollAttach(reference->client) != REDIS_OK
        || redisAsyncSetConnectCallback(reference->client, connected) != REDIS_OK) {
        redis_probe_close(reference);
        return NULL;
    }
    const char *handshake[] = {"HELLO", "3", "AUTH", "default", "flint-cache-fixture"};
    const size_t lengths[] = {5, 1, 4, 7, 19};
    redisReply *reply = perform(reference, 5, handshake, lengths);
    const int ready = reply && reply->type == REDIS_REPLY_MAP;
    freeReplyObject(reply);
    if (!ready) {
        redis_probe_close(reference);
        return NULL;
    }
    return reference;
}

int redis_probe_cycle(redis_reference *reference, const uint8_t *key, size_t key_length,
                       const uint8_t *payload, size_t length, uint64_t *sum)
{
    static const char prefix[] = "flint:probe:";
    char namespaced[64];
    const size_t fixed = sizeof(prefix) - 1;
    if (key_length > sizeof(namespaced) - fixed)
        return 0;
    memcpy(namespaced, prefix, fixed);
    memcpy(namespaced + fixed, key, key_length);
    const char *args[] = {"SET", namespaced, (const char *)payload, "PX", "60000"};
    const size_t sizes[] = {3, fixed + key_length, length, 2, 5};
    redisReply *reply = perform(reference, 5, args, sizes);
    int success = reply && reply->type == REDIS_REPLY_STATUS && reply->len == 2 && memcmp(reply->str, "OK", 2) == 0;
    freeReplyObject(reply);
    if (!success)
        return 0;

    args[0] = "GET";
    reply = perform(reference, 2, args, sizes);
    success = reply && reply->type == REDIS_REPLY_STRING && reply->len == length && memcmp(reply->str, payload, length) == 0;
    *sum = 0;
    if (success)
        for (size_t index = 0; index < length; ++index)
            *sum += (unsigned char)reply->str[index];
    freeReplyObject(reply);
    if (!success)
        return 0;

    args[0] = "DEL";
    reply = perform(reference, 2, args, sizes);
    success = reply && reply->type == REDIS_REPLY_INTEGER && reply->integer == 1;
    freeReplyObject(reply);
    if (!success)
        return 0;

    args[0] = "GET";
    reply = perform(reference, 2, args, sizes);
    success = reply && reply->type == REDIS_REPLY_NIL;
    freeReplyObject(reply);
    return success;
}
