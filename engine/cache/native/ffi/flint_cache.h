#ifndef FLINT_CACHE_ABI_H
#define FLINT_CACHE_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct flint_redis_connection flint_redis_connection;

enum flint_redis_status {
    FLINT_REDIS_OK,
    FLINT_REDIS_ARGUMENT,
    FLINT_REDIS_MEMORY,
    FLINT_REDIS_CANCELLED,
    FLINT_REDIS_TIMEOUT,
    FLINT_REDIS_NOT_FOUND,
    FLINT_REDIS_CONFLICT,
    FLINT_REDIS_IO,
    FLINT_REDIS_UNAVAILABLE,
    FLINT_REDIS_UNSUPPORTED,
    FLINT_REDIS_DENIED,
    FLINT_REDIS_EXHAUSTED,
    FLINT_REDIS_WAITING
};

enum flint_redis_operation {
    FLINT_REDIS_GET = 1,
    FLINT_REDIS_SET,
    FLINT_REDIS_EVICT,
    FLINT_REDIS_CLEAR
};

typedef struct flint_redis_options {
    const char *url;
    size_t url_length;
    const char *namespace_name;
    size_t namespace_length;
    const char *ca_file;
    size_t ca_length;
    size_t payload_limit;
} flint_redis_options;

typedef struct flint_redis_watch {
    int wake_fd;
    int socket_fd;
    unsigned events;
} flint_redis_watch;

typedef struct flint_redis_result {
    unsigned status;
    uint8_t *data;
    size_t length;
} flint_redis_result;

flint_redis_connection *flint_redis_new(const char *host, uint16_t port, int tls);
int flint_redis_command(flint_redis_connection *connection, size_t argc, const char *const *argv,
                         const size_t *lengths, uint64_t *request_id);
int flint_redis_readable(flint_redis_connection *connection);
int flint_redis_writable(flint_redis_connection *connection);
void flint_redis_free(flint_redis_connection *connection);

/* Setup and resolve are separate so DNS never blocks the Reactor worker. */
int flint_redis_create(const flint_redis_options *options, flint_redis_connection **out);
int flint_redis_resolve(flint_redis_connection *connection);
int flint_redis_attach(flint_redis_connection *connection);
int flint_redis_ready(flint_redis_connection *connection);
int flint_redis_watch_now(flint_redis_connection *connection, flint_redis_watch *out);
int flint_redis_pump(flint_redis_connection *connection);
int flint_redis_tick(flint_redis_connection *connection);
void flint_redis_stop(flint_redis_connection *connection);
int flint_redis_stopped(flint_redis_connection *connection);
void flint_redis_finish(flint_redis_connection *connection, int reason);
int flint_redis_wait(flint_redis_connection *connection, uint32_t max_wait_ms);
int flint_redis_issue(flint_redis_connection *connection, uint32_t operation, const uint8_t *key,
                      size_t key_length, const uint8_t *value, size_t value_length, int64_t ttl_nanos,
                      uint64_t *ticket);
int flint_redis_take(flint_redis_connection *connection, uint64_t ticket, flint_redis_result *out);
int flint_redis_abandon(flint_redis_connection *connection, uint64_t ticket);
void flint_redis_release_bytes(uint8_t *data);
uint64_t flint_redis_pushes(flint_redis_connection *connection);

#ifdef __cplusplus
}
#endif

#endif
