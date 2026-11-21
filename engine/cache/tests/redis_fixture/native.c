#define _POSIX_C_SOURCE 200809L
#include "flint_cache.h"

#include <assert.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const int64_t ttl = 90000000000LL;

static int count_allocations;
static unsigned long allocated;

void *__real_malloc(size_t);
void *__real_calloc(size_t, size_t);
void *__real_realloc(void *, size_t);

void *__wrap_malloc(size_t bytes)
{
    if (count_allocations)
        ++allocated;
    return __real_malloc(bytes);
}

void *__wrap_calloc(size_t count, size_t bytes)
{
    if (count_allocations)
        ++allocated;
    return __real_calloc(count, bytes);
}

void *__wrap_realloc(void *data, size_t bytes)
{
    if (count_allocations)
        ++allocated;
    return __real_realloc(data, bytes);
}

static void drive(flint_redis_connection *connection)
{
    flint_redis_watch watch;
    assert(flint_redis_watch_now(connection, &watch) == FLINT_REDIS_OK);
    struct pollfd fds[] = {
        {.fd = watch.wake_fd, .events = POLLIN},
        {.fd = watch.socket_fd, .events = (short)((watch.events & 1 ? POLLIN : 0) | (watch.events & 2 ? POLLOUT : 0))}
    };
    assert(poll(fds, 2, 5) >= 0);
    int status = FLINT_REDIS_OK;
    if (fds[0].revents & POLLIN)
        status = flint_redis_pump(connection);
    if (!status && fds[1].revents & (POLLIN | POLLERR | POLLHUP))
        status = flint_redis_readable(connection);
    if (!status && fds[1].revents & (POLLOUT | POLLERR | POLLHUP))
        status = flint_redis_writable(connection);
    if (!status)
        status = flint_redis_tick(connection);
    if (status)
        flint_redis_finish(connection, status);
}

static flint_redis_connection *connect_to(const char *route, const char *trust, size_t limit)
{
    const char *url = getenv(route);
    assert(url && *url);
    const flint_redis_options options = {url, strlen(url), "native", 6, trust, trust ? strlen(trust) : 0, limit};
    flint_redis_connection *connection = NULL;
    assert(flint_redis_create(&options, &connection) == FLINT_REDIS_OK);
    assert(flint_redis_resolve(connection) == FLINT_REDIS_OK);
    assert(flint_redis_attach(connection) == FLINT_REDIS_OK);
    for (unsigned i = 0; i < 1000 && flint_redis_ready(connection) == FLINT_REDIS_WAITING; ++i)
        drive(connection);
    assert(flint_redis_ready(connection) == FLINT_REDIS_OK);
    return connection;
}

static flint_redis_result receive(flint_redis_connection *connection, uint64_t ticket)
{
    flint_redis_result result;
    for (unsigned i = 0; i < 2000; ++i) {
        const int status = flint_redis_take(connection, ticket, &result);
        if (status == FLINT_REDIS_OK)
            return result;
        assert(status == FLINT_REDIS_WAITING);
        drive(connection);
    }
    assert(!"Redis fixture could not settle the request");
    return (flint_redis_result){0};
}

static uint64_t issue(flint_redis_connection *connection, int kind, const uint8_t *key, size_t key_size,
                       const uint8_t *value, size_t value_size)
{
    uint64_t ticket = 0;
    assert(flint_redis_issue(connection, (uint32_t)kind, key, key_size, value, value_size, ttl, &ticket) == FLINT_REDIS_OK);
    assert(ticket != 0);
    return ticket;
}

static void *foreign_loop(void *argument)
{
    assert(flint_redis_writable(argument) == FLINT_REDIS_CONFLICT);
    assert(flint_redis_readable(argument) == FLINT_REDIS_CONFLICT);
    return NULL;
}

static void options_corpus(void)
{
    const char text[] = "redis://:fixture@127.0.0.1:6379/2";
    flint_redis_options config = {text, 0, "native", 6, NULL, 0, 1024};
    for (size_t size = 0; size < sizeof(text); ++size) {
        config.url_length = size;
        flint_redis_connection *connection = NULL;
        const int status = flint_redis_create(&config, &connection);
        if (status == FLINT_REDIS_OK)
            flint_redis_free(connection);
        else
            assert(status == FLINT_REDIS_ARGUMENT || status == FLINT_REDIS_DENIED);
    }
    config.url_length = sizeof(text);
    flint_redis_connection *null = NULL;
    assert(flint_redis_create(&config, &null) == FLINT_REDIS_ARGUMENT && !null);
}

static void round_trip(void)
{
    sigset_t before, after;
    assert(pthread_sigmask(SIG_SETMASK, NULL, &before) == 0);
    flint_redis_connection *connection = connect_to("FLINT_CACHE_REDIS_REAL", NULL, 4096);
    pthread_t foreign;
    assert(pthread_create(&foreign, NULL, foreign_loop, connection) == 0);
    assert(pthread_join(foreign, NULL) == 0);

    uint8_t key[] = {'a', 0, 'b'};
    uint8_t data[] = {'x', 0, 'y', 255};
    uint64_t ticket = 0;
    assert(flint_redis_issue(connection, FLINT_REDIS_SET, key, sizeof(key), data, 4096, ttl, &ticket)
           == FLINT_REDIS_EXHAUSTED && !ticket);
    const uint64_t put = issue(connection, FLINT_REDIS_SET, key, sizeof(key), data, sizeof(data));
    const uint64_t get = issue(connection, FLINT_REDIS_GET, key, sizeof(key), NULL, 0);
    assert(receive(connection, put).status == FLINT_REDIS_OK);
    flint_redis_result value = receive(connection, get);
    assert(value.status == FLINT_REDIS_OK && value.length == sizeof(data));
    assert(flint_redis_take(connection, get, &(flint_redis_result){0}) == FLINT_REDIS_NOT_FOUND);
    const uint64_t old = issue(connection, FLINT_REDIS_GET, key, sizeof(key), NULL, 0);
    assert(flint_redis_abandon(connection, old) == FLINT_REDIS_OK);
    const uint64_t del = issue(connection, FLINT_REDIS_EVICT, key, sizeof(key), NULL, 0);
    assert(del != old && receive(connection, del).status == FLINT_REDIS_OK);
    assert(flint_redis_take(connection, old, &(flint_redis_result){0}) == FLINT_REDIS_NOT_FOUND);
    flint_redis_free(connection);

    assert(pthread_sigmask(SIG_SETMASK, NULL, &after) == 0);
    assert(sigismember(&before, SIGPIPE) == sigismember(&after, SIGPIPE));
    assert(memcmp(value.data, data, sizeof(data)) == 0);
    flint_redis_release_bytes(value.data);
    puts("Valkey RESP3 queued binary round trip, owner rejection, cancellation and detached reply lifetime");
}

static void response_limits(void)
{
    const char *routes[] = {"FLINT_CACHE_REDIS_OVERSIZE", "FLINT_CACHE_REDIS_DEPTH",
                            "FLINT_CACHE_REDIS_UNKNOWN", "FLINT_CACHE_REDIS_TRUNCATED"};
    for (unsigned index = 0; index < sizeof(routes) / sizeof(routes[0]); ++index) {
        flint_redis_connection *connection = connect_to(routes[index], NULL, 4096);
        const uint64_t get = issue(connection, FLINT_REDIS_GET, NULL, 0, NULL, 0);
        const flint_redis_result value = receive(connection, get);
        assert(value.status == (index >= 2 ? FLINT_REDIS_IO : FLINT_REDIS_EXHAUSTED));
        assert(!value.data);
        flint_redis_free(connection);
    }
    puts("16 MiB input, nested reply and unexpected RESP tag boundaries");
}

static void tls_push(void)
{
    flint_redis_connection *connection = connect_to("FLINT_CACHE_REDIS_TLS", getenv("FLINT_CACHE_REDIS_CA"), 4096);
    const uint64_t get = issue(connection, FLINT_REDIS_GET, NULL, 0, NULL, 0);
    const flint_redis_result secured = receive(connection, get);
    assert(!secured.status && secured.length == 8 && memcmp(secured.data, "verified", 8) == 0);
    flint_redis_release_bytes(secured.data);
    flint_redis_free(connection);

    connection = connect_to("FLINT_CACHE_REDIS_PUSH", NULL, 4096);
    const uint64_t first = issue(connection, FLINT_REDIS_GET, NULL, 0, NULL, 0);
    const uint64_t next = issue(connection, FLINT_REDIS_GET, (const uint8_t *)"next", 4, NULL, 0);
    const flint_redis_result a = receive(connection, first);
    const flint_redis_result b = receive(connection, next);
    assert(!a.status && !b.status && a.length == 13 && b.length == 17);
    assert(memcmp(a.data, "flint:native:", a.length) == 0);
    assert(memcmp(b.data, "flint:native:next", b.length) == 0);
    assert(flint_redis_pushes(connection) == 4);
    flint_redis_release_bytes(a.data);
    flint_redis_release_bytes(b.data);
    flint_redis_free(connection);
    puts("pinned TLS plus independent PUSH dispatch with two outstanding tickets");
}

static void sample_allocations(void)
{
    flint_redis_connection *connection = connect_to("FLINT_CACHE_REDIS_REAL_TLS", getenv("FLINT_CACHE_REDIS_CA"), 8192);
    const size_t sizes[] = {64, 4096};
    uint8_t data[4096];
    memset(data, 17, sizeof(data));
    const uint8_t key[] = {'v', 0, 'm'};
    for (unsigned profile = 0; profile < 2; ++profile) {
        const size_t length = sizes[profile];
        allocated = 0;
        for (unsigned trial = 0; trial < 17; ++trial) {
            count_allocations = trial != 0;
            const uint64_t set = issue(connection, FLINT_REDIS_SET, key, sizeof(key), data, length);
            const uint64_t get = issue(connection, FLINT_REDIS_GET, key, sizeof(key), NULL, 0);
            const uint64_t del = issue(connection, FLINT_REDIS_EVICT, key, sizeof(key), NULL, 0);
            const uint64_t miss = issue(connection, FLINT_REDIS_GET, key, sizeof(key), NULL, 0);
            assert(receive(connection, set).status == FLINT_REDIS_OK);
            flint_redis_result reply = receive(connection, get);
            assert(reply.status == FLINT_REDIS_OK && reply.length == length && !memcmp(reply.data, data, length));
            flint_redis_release_bytes(reply.data);
            assert(receive(connection, del).status == FLINT_REDIS_OK);
            assert(receive(connection, miss).status == FLINT_REDIS_NOT_FOUND);
        }
        count_allocations = 0;
        assert(allocated != 0);
        printf("native allocation calls for 16 TLS Valkey cycles at %zu bytes: %lu\n", length, allocated);
    }
    flint_redis_free(connection);
}

int main(void)
{
    options_corpus();
    round_trip();
    response_limits();
    tls_push();
    sample_allocations();
    return 0;
}
