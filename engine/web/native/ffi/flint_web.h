/* Flint's versioned, opaque web-provider boundary. */
#ifndef FLINT_WEB_ABI_H
#define FLINT_WEB_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct flint_http1_parser flint_http1_parser;
typedef struct flint_h2_session flint_h2_session;

typedef int (*flint_http_event_cb)(void *user, uint32_t event,
                                   const uint8_t *bytes, size_t length);
typedef int (*flint_http_event_token_cb)(uint64_t token, uint32_t event,
                                         const uint8_t *bytes, size_t length);

enum flint_http_event {
    FLINT_HTTP_BEGIN = 1,
    FLINT_HTTP_TARGET,
    FLINT_HTTP_FIELD,
    FLINT_HTTP_FIELD_END,
    FLINT_HTTP_VALUE,
    FLINT_HTTP_VALUE_END,
    FLINT_HTTP_HEADERS,
    FLINT_HTTP_BODY,
    FLINT_HTTP_COMPLETE,
    FLINT_H2_BEGIN = 16,
    FLINT_H2_FIELD,
    FLINT_H2_BODY,
    FLINT_H2_END,
    FLINT_H2_CLOSED,
    FLINT_H2_GOAWAY,
    FLINT_H2_RESET,
    FLINT_H2_HEADERS
};

enum flint_http1_progress {
    FLINT_HTTP1_FAILED = -1,
    FLINT_HTTP1_MORE = 0,
    FLINT_HTTP1_HEADERS = 1,
    FLINT_HTTP1_COMPLETE = 2
};

typedef struct flint_http1_info {
    uint64_t content_length;
    uint32_t method;
    uint8_t major;
    uint8_t minor;
    uint8_t keep_alive;
    uint8_t chunked;
    uint8_t upgrade;
} flint_http1_info;

flint_http1_parser *flint_http1_new(flint_http_event_cb callback, void *user);
int flint_http1_feed(flint_http1_parser *parser, const uint8_t *data, size_t length);
void flint_http1_free(flint_http1_parser *parser);

/* Retains a numeric identity and a callback function. Byte spans expire on return. */
flint_http1_parser *flint_http1_new_token(uint64_t token, flint_http_event_token_cb callback);
/* Pause exactly at headers or message completion, returning the consumed prefix. */
int flint_http1_feed_some(flint_http1_parser *parser, const uint8_t *data, size_t length,
                          size_t *consumed);
int flint_http1_headers(const flint_http1_parser *parser, flint_http1_info *info);

flint_h2_session *flint_h2_new(uint32_t max_streams, flint_http_event_cb callback, void *user);
int flint_h2_feed(flint_h2_session *session, const uint8_t *data, size_t length);
int flint_h2_send(flint_h2_session *session, uint8_t *output, size_t capacity, size_t *written);
void flint_h2_free(flint_h2_session *session);

typedef int (*flint_h2_event_cb)(uint64_t token, uint32_t event, int32_t stream, uint32_t code,
                                  const uint8_t *name, size_t namesize, const uint8_t *value, size_t valuesize);
typedef ptrdiff_t (*flint_h2_body_cb)(uint64_t token, int32_t stream, uint8_t *output, size_t capacity, int *eof);

/* Numeric callbacks run synchronously. Returning a positive H2 error rejects only the indicated stream. */
flint_h2_session *flint_h2_new_token(uint64_t token, uint32_t max_streams, flint_h2_event_cb events,
                                    flint_h2_body_cb body);
/* The provider copies exposed header data. Bodies are streamed through the callback under peer credit. */
int flint_h2_reply(flint_h2_session *session, int32_t stream, unsigned status,
                   const uint8_t *content_type, size_t type_length, size_t body_length, int suppress_body);
typedef struct flint_h2_field {
    const char *name;
    size_t name_length;
    const char *value;
    size_t value_length;
} flint_h2_field;

/* A DATA callback can hold stream credit or temporarily defer its outbound bytes. */
#define FLINT_H2_HOLD_STREAM_CREDIT 2147483647
#define FLINT_H2_DEFER_OUTPUT (-2)

/* Status zero copies exact terminal fields. Other statuses start an incremental response. */
int flint_h2_stream_headers(flint_h2_session *session, int32_t stream, unsigned status,
                            const flint_h2_field *fields, size_t count);
int flint_h2_consume_stream(flint_h2_session *session, int32_t stream, size_t count);
int flint_h2_resume_stream(flint_h2_session *session, int32_t stream);

int flint_h2_reset(flint_h2_session *session, int32_t stream, uint32_t code);
int flint_h2_drain(flint_h2_session *session);
int flint_h2_pending(const flint_h2_session *session);
int flint_h2_done(const flint_h2_session *session);

typedef struct flint_tls_context flint_tls_context;
typedef struct flint_tls_session flint_tls_session;

enum flint_tls_progress {
    FLINT_TLS_ERROR = -1,
    FLINT_TLS_WAIT = 0,
    FLINT_TLS_READY = 1,
    FLINT_TLS_EOF = 2
};

flint_tls_context *flint_tls_open(const char *certificate_file, const char *key_file, int enable_h2);
void flint_tls_close(flint_tls_context *context);
flint_tls_session *flint_tls_accept(flint_tls_context *context);
void flint_tls_free(flint_tls_session *session);
int flint_tls_receive(flint_tls_session *session, const uint8_t *data, size_t length);
int flint_tls_handshake(flint_tls_session *session);
int flint_tls_protocol(const flint_tls_session *session);
int flint_tls_read(flint_tls_session *session, uint8_t *output, size_t capacity, size_t *written);
int flint_tls_write(flint_tls_session *session, const uint8_t *input, size_t length, size_t *consumed);
size_t flint_tls_pending(const flint_tls_session *session);
size_t flint_tls_send(flint_tls_session *session, uint8_t *output, size_t capacity);
int flint_tls_shutdown(flint_tls_session *session);

#ifdef __cplusplus
}
#endif
#endif
