#ifndef FLINT_HTTP_ABI_H
#define FLINT_HTTP_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct flint_curl_loop flint_curl_loop;
typedef int (*flint_curl_data_cb)(void *user, const uint8_t *data, size_t length);

enum flint_http_status {
    FLINT_HTTP_OK = 0,
    FLINT_HTTP_ARGUMENT,
    FLINT_HTTP_MEMORY,
    FLINT_HTTP_CANCELLED,
    FLINT_HTTP_TIMEOUT,
    FLINT_HTTP_NOT_FOUND,
    FLINT_HTTP_CONFLICT,
    FLINT_HTTP_IO,
    FLINT_HTTP_UNAVAILABLE,
    FLINT_HTTP_UNSUPPORTED,
    FLINT_HTTP_DENIED,
    FLINT_HTTP_EXHAUSTED
};

enum flint_http_method {
    FLINT_HTTP_GET,
    FLINT_HTTP_POST,
    FLINT_HTTP_PUT,
    FLINT_HTTP_PATCH,
    FLINT_HTTP_DELETE,
    FLINT_HTTP_HEAD,
    FLINT_HTTP_OPTIONS
};

enum flint_http_state {
    FLINT_HTTP_PREPARED = 1,
    FLINT_HTTP_RUNNING,
    FLINT_HTTP_COMPLETE
};

enum flint_http_events {
    FLINT_HTTP_READ = 1,
    FLINT_HTTP_WRITE = 2,
    FLINT_HTTP_ERROR = 4
};

typedef struct flint_http_options {
    uint32_t connections;
    uint32_t per_origin;
    size_t body_bytes;
    size_t header_bytes;
    uint64_t connect_ms;
    uint8_t redirects;
    const char *ca_path;
    size_t ca_path_length;
} flint_http_options;

typedef struct flint_http_watch {
    intptr_t fd;
    uint32_t events;
    uint64_t generation;
} flint_http_watch;

typedef struct flint_http_view {
    uint32_t state;
    uint32_t status;
    uint32_t version;
    uint32_t error;
    const uint8_t *headers;
    size_t header_length;
    const uint8_t *body;
    size_t body_length;
    const uint8_t *chunk;
    size_t chunk_length;
    const char *redirect;
    size_t redirect_length;
    const char *url;
    size_t url_length;
    uint32_t paused;
} flint_http_view;

/* Base socket-driven ABI. The loop binds to its first operating thread. */
flint_curl_loop *flint_curl_new(void);
int flint_curl_start(flint_curl_loop *loop, const char *url, const char *method,
                    flint_curl_data_cb callback, void *user, uint64_t *request_id);
int flint_curl_socket(flint_curl_loop *loop, intptr_t socket, int events);
int flint_curl_timeout(flint_curl_loop *loop);
int flint_curl_cancel(flint_curl_loop *loop, uint64_t request_id);
void flint_curl_free(flint_curl_loop *loop);

/* Length-delimited extensions for scoped D inputs. No invocation retains those pointers. */
int flint_http_initialize(void);
#ifdef FLINT_HTTP_TEST_OWNER
unsigned long flint_http_owner_calls(void);
#endif
int flint_http_new(const flint_http_options *options, flint_curl_loop **result);
int flint_http_owner(flint_curl_loop *loop);
int flint_http_begin(flint_curl_loop *loop, const char *url, size_t length,
                     uint32_t method, uint32_t streaming, uint64_t *request_id);
int flint_http_header(flint_curl_loop *loop, uint64_t request_id, const char *key, size_t key_length,
                      const char *value, size_t value_length);
int flint_http_body(flint_curl_loop *loop, uint64_t request_id, const uint8_t *bytes, size_t length);
int flint_http_activate(flint_curl_loop *loop, uint64_t request_id);
int flint_http_view_request(flint_curl_loop *loop, uint64_t request_id, flint_http_view *view);
int flint_http_consume_chunk(flint_curl_loop *loop, uint64_t request_id);
int flint_http_follow(flint_curl_loop *loop, uint64_t request_id);
int flint_http_release(flint_curl_loop *loop, uint64_t request_id);
int flint_http_watch_snapshot(flint_curl_loop *loop, flint_http_watch *output, size_t capacity,
                               uint64_t *revision, size_t *count);
int flint_http_due(flint_curl_loop *loop);
int flint_http_poll(flint_curl_loop *loop, uint32_t max_wait_ms);

#ifdef __cplusplus
}
#endif

#endif
