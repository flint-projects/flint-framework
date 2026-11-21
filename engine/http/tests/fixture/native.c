#define _POSIX_C_SOURCE 200809L
#include "flint_http.h"

#include <assert.h>
#include <netdb.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static atomic_bool resolver_entered, resolver_returned;
static atomic_bool count_allocations;
static atomic_ulong allocations;

int __real_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **result);
void *__real_malloc(size_t size);
void *__real_calloc(size_t count, size_t size);
void *__real_realloc(void *value, size_t size);

int __wrap_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **result)
{
    if (node && strcmp(node, "flint-http-resolving.invalid") == 0) {
        atomic_store(&resolver_entered, 1);
        const struct timespec wait = {.tv_nsec = 160 * 1000 * 1000};
        nanosleep(&wait, NULL);
        atomic_store(&resolver_returned, 1);
        return EAI_AGAIN;
    }
    return __real_getaddrinfo(node, service, hints, result);
}

static void record_allocation(void)
{
    if (atomic_load(&count_allocations))
        atomic_fetch_add(&allocations, 1);
}

void *__wrap_malloc(size_t size)
{
    record_allocation();
    return __real_malloc(size);
}

void *__wrap_calloc(size_t count, size_t size)
{
    record_allocation();
    return __real_calloc(count, size);
}

void *__wrap_realloc(void *value, size_t size)
{
    record_allocation();
    return __real_realloc(value, size);
}

static uint64_t reserve(flint_curl_loop *loop, const char *url, int stream)
{
    uint64_t id = 0;
    assert(flint_http_begin(loop, url, strlen(url), FLINT_HTTP_GET, stream, &id) == FLINT_HTTP_OK);
    assert(id);
    return id;
}

static uint64_t start(flint_curl_loop *loop, const char *url, int stream)
{
    const uint64_t id = reserve(loop, url, stream);
    assert(flint_http_activate(loop, id) == FLINT_HTTP_OK);
    return id;
}

static void transfer_url(char url[512], const char *origin, const char *path)
{
    const int length = snprintf(url, 512, "%s%s", origin, path);
    assert(length > 0 && length < 512);
}

static void *wrong_owner(void *context)
{
    flint_curl_loop *loop = context;
    uint64_t id = 0;
    assert(flint_http_begin(loop, "http://localhost/", 17, FLINT_HTTP_GET, 0, &id) == FLINT_HTTP_CONFLICT);
    assert(flint_http_due(loop) == FLINT_HTTP_CONFLICT);
    flint_curl_free(loop);
    return NULL;
}

static void corpus(flint_curl_loop *loop, const char *origin)
{
    char url[512];
    transfer_url(url, origin, "/zero");
    for (size_t i = 0; i <= strlen(url); ++i) {
        uint64_t id = 0;
        const int status = flint_http_begin(loop, url, i, FLINT_HTTP_GET, 0, &id);
        if (status == FLINT_HTTP_OK) {
            assert(flint_http_header(loop, id, "X-Empty", 7, NULL, 0) == FLINT_HTTP_OK);
            assert(flint_http_release(loop, id) == FLINT_HTTP_OK);
            assert(flint_curl_cancel(loop, id) == FLINT_HTTP_NOT_FOUND);
        } else {
            assert(status == FLINT_HTTP_ARGUMENT || status == FLINT_HTTP_UNSUPPORTED);
        }
    }

    char oversized[16385];
    memset(oversized, 'a', sizeof(oversized));
    memcpy(oversized, "https://localhost/", 18);
    uint64_t id = 0;
    assert(flint_http_begin(loop, oversized, sizeof(oversized), FLINT_HTTP_GET, 0, &id) == FLINT_HTTP_ARGUMENT);
    assert(flint_http_begin(loop, oversized, sizeof(oversized) - 1, FLINT_HTTP_GET, 0, &id) == FLINT_HTTP_OK);
    assert(flint_curl_cancel(loop, id) == FLINT_HTTP_OK);
    assert(flint_http_release(loop, id) == FLINT_HTTP_OK);

    const uint64_t first = reserve(loop, url, 0);
    for (unsigned value = 0; value <= 127; ++value) {
        const char byte = (char) value;
        const int status = flint_http_header(loop, first, "X-Fuzz", 6, &byte, 1);
        if ((value < 32 && value != '\t') || value == 127)
            assert(status == FLINT_HTTP_ARGUMENT);
        else
            assert(status == FLINT_HTTP_OK);
    }
    assert(flint_http_release(loop, first) == FLINT_HTTP_OK);
    const uint64_t next = reserve(loop, url, 0);
    assert(first != next);
    assert(flint_http_body(loop, first, (const uint8_t *) "ignored", 7) == FLINT_HTTP_CONFLICT);
    assert(flint_http_release(loop, next) == FLINT_HTTP_OK);
}

static void cancel_resolving(flint_curl_loop *loop)
{
    const uint64_t pending = start(loop, "http://flint-http-resolving.invalid/", 0);
    for (unsigned tries = 0; tries < 100 && !atomic_load(&resolver_entered); ++tries)
        assert(flint_http_poll(loop, 5) == FLINT_HTTP_OK);
    assert(atomic_load(&resolver_entered) && !atomic_load(&resolver_returned));
    assert(flint_curl_cancel(loop, pending) == FLINT_HTTP_OK);
    flint_http_view view;
    assert(flint_http_view_request(loop, pending, &view) == FLINT_HTTP_OK);
    assert(view.state == FLINT_HTTP_COMPLETE && view.error == FLINT_HTTP_CANCELLED);
    assert(flint_http_release(loop, pending) == FLINT_HTTP_OK);
    assert(flint_http_view_request(loop, pending, &view) == FLINT_HTTP_NOT_FOUND);
    for (unsigned tries = 0; tries < 100 && !atomic_load(&resolver_returned); ++tries)
        assert(flint_http_poll(loop, 5) == FLINT_HTTP_OK);
    assert(atomic_load(&resolver_returned));
    puts("resolver: cancelled after the pinned threaded resolver entered getaddrinfo");
}

static void cancel_paused(flint_curl_loop *loop, const char *origin, const char *other)
{
    char slow_url[512];
    transfer_url(slow_url, origin, "/bytes?n=8388608");
    const uint64_t slow = start(loop, slow_url, 1);
    flint_http_view view = {0};
    for (unsigned tries = 0; tries < 200 && !view.paused; ++tries) {
        assert(flint_http_poll(loop, 5) == FLINT_HTTP_OK);
        assert(flint_http_view_request(loop, slow, &view) == FLINT_HTTP_OK);
    }
    assert(view.paused && view.state == FLINT_HTTP_RUNNING && view.chunk_length);
    const size_t original = view.chunk_length;
    const uint64_t fast = start(loop, other, 0);
    flint_http_view finished = {0};
    for (unsigned tries = 0; tries < 100 && finished.state != FLINT_HTTP_COMPLETE; ++tries) {
        assert(flint_http_poll(loop, 5) == FLINT_HTTP_OK);
        assert(flint_http_view_request(loop, fast, &finished) == FLINT_HTTP_OK);
    }
    assert(finished.state == FLINT_HTTP_COMPLETE && finished.status == 200 && !finished.error);
    assert(flint_http_release(loop, fast) == FLINT_HTTP_OK);
    assert(flint_http_view_request(loop, slow, &view) == FLINT_HTTP_OK);
    assert(view.paused && view.chunk_length == original);
    for (size_t i = 0; i < original; ++i)
        assert(view.chunk[i] == (i * 17 + i / 11) % 251);
    assert(flint_curl_cancel(loop, slow) == FLINT_HTTP_OK);
    assert(flint_http_view_request(loop, slow, &view) == FLINT_HTTP_OK);
    assert(view.state == FLINT_HTTP_COMPLETE && view.error == FLINT_HTTP_CANCELLED);
    assert(flint_http_release(loop, slow) == FLINT_HTTP_OK);
    puts("pause: independent transfer completed while libcurl paused the saturated stream");
}

static void complete_stream(flint_curl_loop *loop, const char *url, size_t expected)
{
    const uint64_t handle = start(loop, url, 1);
    size_t received = 0;
    for (unsigned tries = 0; tries < 10000; ++tries) {
        flint_http_view view;
        assert(flint_http_poll(loop, 1) == FLINT_HTTP_OK);
        assert(flint_http_view_request(loop, handle, &view) == FLINT_HTTP_OK);
        assert(!view.error);
        if (view.chunk_length) {
            received += view.chunk_length;
            assert(flint_http_consume_chunk(loop, handle) == FLINT_HTTP_OK);
        }
        if (view.state == FLINT_HTTP_COMPLETE) {
            assert(view.status == 200 && view.version == 2 && received == expected);
            assert(flint_http_release(loop, handle) == FLINT_HTTP_OK);
            return;
        }
    }
    assert(!"TLS stream exhausted its wait budget");
}

static void sample_allocations(flint_curl_loop *loop, const char *origin)
{
    static const size_t sizes[] = {1024, 65536};
    for (size_t sample = 0; sample < sizeof(sizes) / sizeof(sizes[0]); ++sample) {
        char path[40];
        char url[512];
        const int length = snprintf(path, sizeof(path), "/bytes?n=%zu", sizes[sample]);
        assert(length > 0 && (size_t) length < sizeof(path));
        transfer_url(url, origin, path);
        complete_stream(loop, url, sizes[sample]);
        atomic_store(&allocations, 0);
        atomic_store(&count_allocations, 1);
        for (unsigned trial = 0; trial < 16; ++trial)
            complete_stream(loop, url, sizes[sample]);
        atomic_store(&count_allocations, 0);
        const unsigned long calls = atomic_load(&allocations);
        assert(calls != 0);
        printf("native allocation calls on 16 reused HTTPS transfers at %zu bytes: %lu\n", sizes[sample], calls);
    }
}

static void scoped_upload(flint_curl_loop *loop, const char *origin)
{
    uint8_t input[17] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 255};
    char url[512];
    uint64_t id = 0;
    transfer_url(url, origin, "/view-signed/leaf/../%E2%98%83?mode=a%2Fb");
    assert(flint_http_begin_view(loop, url, strlen(url), FLINT_HTTP_HEAD, 0, input, sizeof(input), &id)
        == FLINT_HTTP_ARGUMENT);
    assert(flint_http_begin_view(loop, url, strlen(url), FLINT_HTTP_PUT, FLINT_HTTP_VIEW_KEEP_PATH,
                                input, sizeof(input), &id) == FLINT_HTTP_OK);
    assert(flint_http_header(loop, id, "X-Probe", 7, "scoped", 6) == FLINT_HTTP_OK);
    assert(flint_http_body(loop, id, input, sizeof(input)) == FLINT_HTTP_CONFLICT);
    assert(flint_http_activate(loop, id) == FLINT_HTTP_OK);
    for (unsigned step = 0; step < 2000; ++step) {
        flint_http_view view;
        assert(flint_http_poll(loop, 1) == FLINT_HTTP_OK);
        assert(flint_http_view_request(loop, id, &view) == FLINT_HTTP_OK && !view.error);
        if (view.state == FLINT_HTTP_COMPLETE) {
            assert(view.status == 200 && view.body_length == sizeof(input));
            assert(memcmp(view.body, input, sizeof(input)) == 0);
            assert(flint_http_release(loop, id) == FLINT_HTTP_OK);
            assert(flint_http_view_request(loop, id, &view) == FLINT_HTTP_NOT_FOUND);
            break;
        }
        assert(step != 1999);
    }
    transfer_url(url, origin, "/late");
    assert(flint_http_begin_view(loop, url, strlen(url), FLINT_HTTP_POST, FLINT_HTTP_VIEW_STREAM,
                                input, sizeof(input), &id) == FLINT_HTTP_OK);
    assert(flint_http_activate(loop, id) == FLINT_HTTP_OK);
    assert(flint_curl_cancel(loop, id) == FLINT_HTTP_OK);
    assert(flint_http_release(loop, id) == FLINT_HTTP_OK);
    puts("scoped upload: exact request path and bytes, invalid HEAD, and cancellation retirement passed");
}

int main(void)
{
    const char *origin = getenv("FLINT_HTTP_HTTP");
    const char *other = getenv("FLINT_HTTP_OTHER");
    const char *secure = getenv("FLINT_HTTP_HTTPS");
    const char *ca = getenv("FLINT_HTTP_CA");
    assert(origin && other && secure && ca);
    assert(flint_http_initialize() == FLINT_HTTP_OK);
    const flint_http_options options = {
        .connections = 2,
        .per_origin = 1,
        .body_bytes = 8 * 1024 * 1024,
        .header_bytes = 65536,
        .connect_ms = 5000,
        .ca_path = ca,
        .ca_path_length = strlen(ca)
    };
    flint_curl_loop *loop = NULL;
    assert(flint_http_new(&options, &loop) == FLINT_HTTP_OK);
    assert(flint_http_owner(loop) == FLINT_HTTP_OK);
    pthread_t foreign;
    assert(pthread_create(&foreign, NULL, wrong_owner, loop) == 0);
    assert(pthread_join(foreign, NULL) == 0);
    corpus(loop, origin);
    cancel_resolving(loop);
    cancel_paused(loop, origin, other);
    scoped_upload(loop, origin);
    sample_allocations(loop, secure);
    flint_curl_free(loop);
    assert(flint_http_owner_calls() > 100);
    printf("owner: %lu checked libcurl easy and multi calls\n", flint_http_owner_calls());
    return 0;
}
