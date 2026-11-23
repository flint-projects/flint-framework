/* The pinned native parser owns HTTP grammar; this shim translates events and pause points. */
#include "flint_web.h"

#if defined(FLINT_HAS_LLHTTP)
#include <llhttp.h>
#include <stdlib.h>

struct flint_http1_parser {
    llhttp_t native;
    flint_http_event_cb callback;
    flint_http_event_token_cb token_callback;
    void *user;
    uint64_t token;
    int boundary;
    flint_http1_info headers;
};

static flint_http1_parser *owner(llhttp_t *parser) {
    return (flint_http1_parser *)parser->data;
}

static int emit_event(llhttp_t *parser, uint32_t event, const char *bytes, size_t length) {
    flint_http1_parser *handle = owner(parser);
    if (handle->token_callback != NULL)
        return handle->token_callback(handle->token, event, (const uint8_t *)bytes, length) == 0 ? 0 : -1;
    return handle->callback(handle->user, event, (const uint8_t *)bytes, length) == 0 ? 0 : -1;
}

static int on_begin(llhttp_t *parser) {
    return emit_event(parser, FLINT_HTTP_BEGIN, NULL, 0);
}

static int on_target(llhttp_t *parser, const char *bytes, size_t length) {
    return emit_event(parser, FLINT_HTTP_TARGET, bytes, length);
}

static int on_field(llhttp_t *parser, const char *bytes, size_t length) {
    return emit_event(parser, FLINT_HTTP_FIELD, bytes, length);
}

static int on_field_end(llhttp_t *parser) {
    return emit_event(parser, FLINT_HTTP_FIELD_END, NULL, 0);
}

static int on_value(llhttp_t *parser, const char *bytes, size_t length) {
    return emit_event(parser, FLINT_HTTP_VALUE, bytes, length);
}

static int on_value_end(llhttp_t *parser) {
    return emit_event(parser, FLINT_HTTP_VALUE_END, NULL, 0);
}

static int on_body(llhttp_t *parser, const char *bytes, size_t length) {
    return emit_event(parser, FLINT_HTTP_BODY, bytes, length);
}

static uint32_t method_code(llhttp_t *parser) {
    switch (llhttp_get_method(parser)) {
    case HTTP_GET: return 0;
    case HTTP_POST: return 1;
    case HTTP_PUT: return 2;
    case HTTP_PATCH: return 3;
    case HTTP_DELETE: return 4;
    case HTTP_HEAD: return 5;
    case HTTP_OPTIONS: return 6;
    default: return UINT32_MAX;
    }
}

static int on_headers(llhttp_t *parser) {
    flint_http1_parser *handle = owner(parser);
    handle->headers.content_length = parser->content_length;
    handle->headers.method = method_code(parser);
    handle->headers.major = llhttp_get_http_major(parser);
    handle->headers.minor = llhttp_get_http_minor(parser);
    handle->headers.keep_alive = llhttp_should_keep_alive(parser) != 0;
    handle->headers.chunked = (parser->flags & F_CHUNKED) != 0;
    handle->headers.upgrade = llhttp_get_upgrade(parser) != 0;
    if (emit_event(parser, FLINT_HTTP_HEADERS, NULL, 0) != 0)
        return -1;
    handle->boundary = FLINT_HTTP1_HEADERS;
    return HPE_PAUSED;
}

static int on_complete(llhttp_t *parser) {
    if (emit_event(parser, FLINT_HTTP_COMPLETE, NULL, 0) != 0)
        return -1;
    owner(parser)->boundary = FLINT_HTTP1_COMPLETE;
    return HPE_PAUSED;
}

static const llhttp_settings_t settings = {
    .on_message_begin = on_begin,
    .on_url = on_target,
    .on_header_field = on_field,
    .on_header_field_complete = on_field_end,
    .on_header_value = on_value,
    .on_header_value_complete = on_value_end,
    .on_headers_complete = on_headers,
    .on_body = on_body,
    .on_message_complete = on_complete
};

static flint_http1_parser *new_parser(void) {
    flint_http1_parser *parser = calloc(1, sizeof(*parser));
    if (parser != NULL) {
        llhttp_init(&parser->native, HTTP_REQUEST, &settings);
        parser->native.data = parser;
    }
    return parser;
}

flint_http1_parser *flint_http1_new(flint_http_event_cb callback, void *user) {
    if (callback == NULL)
        return NULL;
    flint_http1_parser *parser = new_parser();
    if (parser != NULL) {
        parser->callback = callback;
        parser->user = user;
    }
    return parser;
}

flint_http1_parser *flint_http1_new_token(uint64_t token, flint_http_event_token_cb callback) {
    if (token == 0 || callback == NULL)
        return NULL;
    flint_http1_parser *parser = new_parser();
    if (parser != NULL) {
        parser->token_callback = callback;
        parser->token = token;
    }
    return parser;
}

int flint_http1_feed_some(flint_http1_parser *parser, const uint8_t *data, size_t length,
                          size_t *consumed) {
    if (consumed == NULL)
        return FLINT_HTTP1_FAILED;
    *consumed = 0;
    if (parser == NULL || (length != 0 && data == NULL) || length > PTRDIFF_MAX)
        return FLINT_HTTP1_FAILED;

    const char *input = data != NULL ? (const char *)data : "";
    if (parser->boundary != FLINT_HTTP1_MORE) {
        llhttp_resume(&parser->native);
        parser->boundary = FLINT_HTTP1_MORE;
    }

    llhttp_errno_t result = llhttp_execute(&parser->native, input, length);
    if (result == HPE_OK) {
        *consumed = length;
        return FLINT_HTTP1_MORE;
    }
    if (result != HPE_PAUSED || parser->boundary == FLINT_HTTP1_MORE)
        return FLINT_HTTP1_FAILED;

    const char *stopped = llhttp_get_error_pos(&parser->native);
    if (stopped == NULL || stopped < input || stopped > input + length)
        return FLINT_HTTP1_FAILED;
    *consumed = (size_t)(stopped - input);
    return parser->boundary;
}

int flint_http1_headers(const flint_http1_parser *parser, flint_http1_info *info) {
    if (parser == NULL || info == NULL || parser->boundary != FLINT_HTTP1_HEADERS)
        return -1;
    *info = parser->headers;
    return 0;
}

int flint_http1_feed(flint_http1_parser *parser, const uint8_t *data, size_t length) {
    if (parser == NULL || (length != 0 && data == NULL))
        return -1;
    size_t position = 0;
    for (;;) {
        size_t consumed;
        const uint8_t *remaining = data != NULL ? data + position : NULL;
        int result = flint_http1_feed_some(parser, remaining, length - position, &consumed);
        if (result <= FLINT_HTTP1_MORE)
            return result;
        position += consumed;
        if (result == FLINT_HTTP1_COMPLETE && position == length)
            return 0;
    }
}

void flint_http1_free(flint_http1_parser *parser) {
    free(parser);
}
#endif

#if defined(FLINT_HAS_NGHTTP2)
#if defined(_MSC_VER) && !defined(__clang__)
#include <BaseTsd.h>
typedef SSIZE_T ssize_t; /* nghttp2.h's callbacks return ssize_t, which MSVC does not define (ADR-026) */
#endif
#include <nghttp2/nghttp2.h>
#include <stdlib.h>
#include <string.h>

enum {
    FLINT_H2_MAX_STREAMS = 100,
    FLINT_H2_DATA_CHUNK = 4000,
    FLINT_H2_FRAME_HEADER = 9,
    FLINT_H2_WINDOW_BYTES = 4,
    FLINT_H2_MAX_OUTPUT_FIELDS = 32,
    FLINT_H2_MAX_OUTPUT_FIELD_BYTES = 8192
};

typedef struct flint_h2_trailer {
    struct flint_h2_trailer *next;
    int32_t stream;
    size_t count;
    nghttp2_nv fields[FLINT_H2_MAX_OUTPUT_FIELDS];
    uint8_t bytes[];
} flint_h2_trailer;

struct flint_h2_session {
    nghttp2_session *native;
    flint_http_event_cb legacy;
    void *user;
    flint_h2_event_cb events;
    flint_h2_body_cb body;
    uint64_t token;
    const uint8_t *pending;
    size_t pending_length;
    size_t received_preface;
    size_t received_header;
    size_t received_window;
    size_t data_remaining;
    uint8_t header[FLINT_H2_FRAME_HEADER];
    uint8_t window[FLINT_H2_WINDOW_BYTES];
    int awaiting_continuation;
    flint_h2_trailer *trailers;
    size_t trailer_count;
};

static flint_h2_trailer *take_trailer(flint_h2_session *owner, int32_t stream) {
    flint_h2_trailer **next = &owner->trailers;
    while (*next != NULL) {
        if ((*next)->stream == stream) {
            flint_h2_trailer *taken = *next;
            *next = taken->next;
            --owner->trailer_count;
            return taken;
        }
        next = &(*next)->next;
    }
    return NULL;
}

static int h2_event(flint_h2_session *owner, uint32_t event, int32_t stream, uint32_t code,
                    const uint8_t *name, size_t namesize, const uint8_t *value, size_t valuesize) {
    if (owner->events != NULL)
        return owner->events(owner->token, event, stream, code, name, namesize, value, valuesize);
    /* Legacy ABI supplies the value bytes only. Runtime streams use the typed numeric ABI. */
    return owner->legacy(owner->user, event, value, valuesize);
}

static int h2_reject(nghttp2_session *session, int32_t stream, int code) {
    if (code < 0)
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    if (code == 0)
        return 0;
    if (nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, stream, (uint32_t)code) != 0)
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
}

static int h2_begin(nghttp2_session *session, const nghttp2_frame *frame, void *user) {
    if (frame->hd.type != NGHTTP2_HEADERS || frame->headers.cat != NGHTTP2_HCAT_REQUEST)
        return 0;
    int32_t stream = frame->hd.stream_id;
    return h2_reject(session, stream, h2_event(user, FLINT_H2_BEGIN, stream, 0, NULL, 0, NULL, 0));
}

static int h2_frame_header(nghttp2_session *session, const nghttp2_frame_hd *header, void *user) {
    (void)user;
    /* RFC 9113 still reserves stream zero even though RFC 7540 priority signaling was deprecated. */
    if (header->type == NGHTTP2_PRIORITY && header->stream_id == 0 &&
        nghttp2_session_terminate_session(session, NGHTTP2_PROTOCOL_ERROR) != 0)
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    return 0;
}

static int h2_header(nghttp2_session *session, const nghttp2_frame *frame, nghttp2_rcbuf *name,
                     nghttp2_rcbuf *value, uint8_t flags, void *user) {
    (void)flags;
    if (frame->hd.type != NGHTTP2_HEADERS)
        return 0;
    nghttp2_vec field = nghttp2_rcbuf_get_buf(name);
    nghttp2_vec contents = nghttp2_rcbuf_get_buf(value);
    int32_t stream = frame->hd.stream_id;
    uint32_t trailer = frame->headers.cat == NGHTTP2_HCAT_REQUEST ? 0u : 1u;
    int decision = h2_event(user, FLINT_H2_FIELD, stream, trailer,
                            field.base, field.len, contents.base, contents.len);
    return h2_reject(session, stream, decision);
}

static int h2_data(nghttp2_session *session, uint8_t flags, int32_t stream,
                   const uint8_t *data, size_t length, void *user) {
    (void)flags;
    int decision = h2_event(user, FLINT_H2_BODY, stream, 0, NULL, 0, data, length);
    if (decision < 0 || nghttp2_session_consume_connection(session, length) != 0)
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    if (decision == FLINT_H2_HOLD_STREAM_CREDIT)
        return 0;
    if (decision == 0)
        return nghttp2_session_consume_stream(session, stream, length) == 0 ? 0 : NGHTTP2_ERR_CALLBACK_FAILURE;
    if (nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, stream, (uint32_t)decision) != 0)
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    return 0;
}

static int h2_received(nghttp2_session *session, const nghttp2_frame *frame, void *user) {
    if (frame->hd.type == NGHTTP2_GOAWAY)
        return h2_event(user, FLINT_H2_GOAWAY, frame->goaway.last_stream_id, frame->goaway.error_code,
                        NULL, 0, NULL, 0) == 0 ? 0 : NGHTTP2_ERR_CALLBACK_FAILURE;
    if (frame->hd.type == NGHTTP2_RST_STREAM)
        return h2_event(user, FLINT_H2_RESET, frame->hd.stream_id, frame->rst_stream.error_code,
                        NULL, 0, NULL, 0) == 0 ? 0 : NGHTTP2_ERR_CALLBACK_FAILURE;
    if (frame->hd.type == NGHTTP2_HEADERS && frame->headers.cat == NGHTTP2_HCAT_REQUEST) {
        const int decision = h2_event(user, FLINT_H2_HEADERS, frame->hd.stream_id, 0, NULL, 0, NULL, 0);
        if (decision < 0)
            return NGHTTP2_ERR_CALLBACK_FAILURE;
        if (decision != 0)
            return nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, frame->hd.stream_id,
                                             (uint32_t)decision) == 0 ? 0 : NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    if ((frame->hd.type != NGHTTP2_HEADERS && frame->hd.type != NGHTTP2_DATA) ||
        !(frame->hd.flags & NGHTTP2_FLAG_END_STREAM))
        return 0;
    int32_t stream = frame->hd.stream_id;
    int decision = h2_event(user, FLINT_H2_END, stream, 0, NULL, 0, NULL, 0);
    if (decision < 0)
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    if (decision != 0 &&
        nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, stream, (uint32_t)decision) != 0)
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    return 0;
}

/* RFC 9113 section 8.1: after a complete response, ask a client whose request is still open to stop
 * sending with RST_STREAM(NO_ERROR). END_STREAM alone leaves the stream half-closed, and clients such
 * as libcurl report the end of the response and its trailers only once the stream closes. */
static int h2_sent(nghttp2_session *session, const nghttp2_frame *frame, void *user) {
    (void)user;
    if ((frame->hd.type != NGHTTP2_HEADERS && frame->hd.type != NGHTTP2_DATA) ||
        !(frame->hd.flags & NGHTTP2_FLAG_END_STREAM) ||
        nghttp2_session_get_stream_remote_close(session, frame->hd.stream_id) != 0)
        return 0;
    return nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, frame->hd.stream_id, NGHTTP2_NO_ERROR) == 0
        ? 0 : NGHTTP2_ERR_CALLBACK_FAILURE;
}

static int h2_closed(nghttp2_session *session, int32_t stream, uint32_t code, void *user) {
    (void)session;
    free(take_trailer(user, stream));
    return h2_event(user, FLINT_H2_CLOSED, stream, code, NULL, 0, NULL, 0) == 0
        ? 0 : NGHTTP2_ERR_CALLBACK_FAILURE;
}

static nghttp2_ssize h2_write_body(nghttp2_session *session, int32_t stream, uint8_t *output,
                                  size_t capacity, uint32_t *flags, nghttp2_data_source *source,
                                  void *user) {
    (void)source;
    flint_h2_session *owner = user;
    if (owner->body == NULL)
        return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
    if (capacity > FLINT_H2_DATA_CHUNK)
        capacity = FLINT_H2_DATA_CHUNK;
    int finished = 0;
    ptrdiff_t result = owner->body(owner->token, stream, output, capacity, &finished);
    if (result == FLINT_H2_DEFER_OUTPUT)
        return NGHTTP2_ERR_DEFERRED;
    if (result < 0 || (size_t)result > capacity || (result == 0 && !finished))
        return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
    if (finished) {
        *flags |= NGHTTP2_DATA_FLAG_EOF;
        flint_h2_trailer *trailer = take_trailer(owner, stream);
        if (trailer != NULL) {
            *flags |= NGHTTP2_DATA_FLAG_NO_END_STREAM;
            const int submitted = nghttp2_submit_trailer(session, stream, trailer->fields, trailer->count);
            free(trailer);
            if (submitted != 0)
                return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
        }
    }
    return result;
}

static flint_h2_session *h2_create(uint32_t max_streams) {
    if (max_streams == 0 || max_streams > FLINT_H2_MAX_STREAMS)
        return NULL;
    flint_h2_session *owner = calloc(1, sizeof(*owner));
    if (owner == NULL)
        return NULL;
    nghttp2_session_callbacks *callbacks = NULL;
    nghttp2_option *options = NULL;
    const nghttp2_settings_entry config[] = {
        { NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, max_streams },
        { NGHTTP2_SETTINGS_HEADER_TABLE_SIZE, 4096 },
        { NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, 16384 }
    };
    if (nghttp2_session_callbacks_new(&callbacks) != 0 || nghttp2_option_new(&options) != 0)
        goto failed;
    nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, h2_begin);
    nghttp2_session_callbacks_set_on_begin_frame_callback(callbacks, h2_frame_header);
    nghttp2_session_callbacks_set_on_header_callback2(callbacks, h2_header);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, h2_data);
    nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, h2_received);
    nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, h2_closed);
    nghttp2_session_callbacks_set_on_frame_send_callback(callbacks, h2_sent);
    nghttp2_option_set_max_send_header_block_length(options, FLINT_H2_MAX_OUTPUT_FIELD_BYTES);
    nghttp2_option_set_no_auto_window_update(options, 1);
    nghttp2_option_set_max_deflate_dynamic_table_size(options, 4096);
    nghttp2_option_set_max_continuations(options, 8);
    nghttp2_option_set_max_outbound_ack(options, 32);
    nghttp2_option_set_max_outbound_queue_size(options, 256);
    if (nghttp2_session_server_new2(&owner->native, callbacks, owner, options) != 0 ||
        nghttp2_submit_settings(owner->native, NGHTTP2_FLAG_NONE, config, sizeof(config) / sizeof(config[0])) != 0)
        goto failed;
    nghttp2_session_callbacks_del(callbacks);
    nghttp2_option_del(options);
    return owner;

failed:
    nghttp2_session_callbacks_del(callbacks);
    nghttp2_option_del(options);
    if (owner->native != NULL)
        nghttp2_session_del(owner->native);
    free(owner);
    return NULL;
}

flint_h2_session *flint_h2_new(uint32_t max_streams, flint_http_event_cb callback, void *user) {
    if (callback == NULL)
        return NULL;
    flint_h2_session *owner = h2_create(max_streams);
    if (owner != NULL) {
        owner->legacy = callback;
        owner->user = user;
    }
    return owner;
}

flint_h2_session *flint_h2_new_token(uint64_t token, uint32_t max_streams, flint_h2_event_cb events,
                                    flint_h2_body_cb body) {
    if (token == 0 || events == NULL || body == NULL)
        return NULL;
    flint_h2_session *owner = h2_create(max_streams);
    if (owner != NULL) {
        owner->events = events;
        owner->body = body;
        owner->token = token;
    }
    return owner;
}

static int h2_feed_native(flint_h2_session *owner, const uint8_t *data, size_t length) {
    if (length == 0)
        return 0;
    nghttp2_ssize consumed = nghttp2_session_mem_recv2(owner->native, data, length);
    return consumed < 0 || (size_t)consumed != length ? -1 : 0;
}

static size_t h2_copy_input(uint8_t *destination, size_t used, size_t capacity,
                            const uint8_t **input, size_t *remaining) {
    const size_t needed = capacity - used;
    const size_t size = *remaining < needed ? *remaining : needed;
    memcpy(destination + used, *input, size);
    *input += size;
    *remaining -= size;
    return used + size;
}

static uint32_t h2_read32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 | (uint32_t)bytes[2] << 8 | bytes[3];
}

static int h2_accept_window(flint_h2_session *owner) {
    const int32_t stream = (int32_t)(h2_read32(owner->header + 5) & INT32_MAX);
    const uint32_t increment = h2_read32(owner->window) & INT32_MAX;
    const int32_t current = nghttp2_session_get_stream_remote_window_size(owner->native, stream);
    /* This provider pin terminates the connection for a live stream overflow.
       RFC 9113 §6.9.1 makes the error stream-local. Leave all other errors to nghttp2. */
    if (current >= 0 && increment > (uint32_t)(INT32_MAX - current))
        return nghttp2_submit_rst_stream(owner->native, NGHTTP2_FLAG_NONE, stream, NGHTTP2_FLOW_CONTROL_ERROR);
    if (h2_feed_native(owner, owner->header, sizeof(owner->header)) != 0)
        return -1;
    return h2_feed_native(owner, owner->window, sizeof(owner->window));
}

int flint_h2_feed(flint_h2_session *owner, const uint8_t *data, size_t length) {
    if (owner == NULL || (data == NULL && length != 0) || length > PTRDIFF_MAX)
        return -1;
    const size_t pending_magic = NGHTTP2_CLIENT_MAGIC_LEN - owner->received_preface;
    if (pending_magic != 0 && length != 0) {
        const size_t count = length < pending_magic ? length : pending_magic;
        if (h2_feed_native(owner, data, count) != 0)
            return -1;
        owner->received_preface += count;
        data += count;
        length -= count;
    }
    while (length != 0) {
        if (owner->data_remaining != 0) {
            const size_t count = owner->data_remaining < length ? owner->data_remaining : length;
            if (h2_feed_native(owner, data, count) != 0)
                return -1;
            owner->data_remaining -= count;
            data += count;
            length -= count;
            continue;
        }
        owner->received_header = h2_copy_input(owner->header, owner->received_header,
                                               sizeof(owner->header), &data, &length);
        if (owner->received_header != sizeof(owner->header))
            break;
        const size_t payload = (size_t)owner->header[0] << 16 |
                               (size_t)owner->header[1] << 8 | owner->header[2];
        const uint8_t type = owner->header[3];
        if (type == NGHTTP2_WINDOW_UPDATE && payload == sizeof(owner->window) &&
            !owner->awaiting_continuation && (h2_read32(owner->header + 5) & INT32_MAX) != 0) {
            owner->received_window = h2_copy_input(owner->window, owner->received_window,
                                                    sizeof(owner->window), &data, &length);
            if (owner->received_window != sizeof(owner->window))
                break;
            if (h2_accept_window(owner) != 0)
                return -1;
            owner->received_window = 0;
        } else {
            if (type == NGHTTP2_HEADERS || type == NGHTTP2_CONTINUATION)
                owner->awaiting_continuation = (owner->header[4] & NGHTTP2_FLAG_END_HEADERS) == 0;
            if (h2_feed_native(owner, owner->header, sizeof(owner->header)) != 0)
                return -1;
            owner->data_remaining = payload;
        }
        owner->received_header = 0;
    }
    return 0;
}

int flint_h2_send(flint_h2_session *owner, uint8_t *output, size_t capacity, size_t *written) {
    if (written == NULL)
        return -1;
    *written = 0;
    if (owner == NULL || output == NULL || capacity == 0)
        return -1;
    if (owner->pending_length == 0) {
        nghttp2_ssize available = nghttp2_session_mem_send2(owner->native, &owner->pending);
        if (available < 0)
            return -1;
        owner->pending_length = (size_t)available;
        if (available == 0)
            return 0;
    }

    size_t count = owner->pending_length < capacity ? owner->pending_length : capacity;
    memcpy(output, owner->pending, count);
    owner->pending += count;
    owner->pending_length -= count;
    *written = count;
    return 0;
}

static nghttp2_nv h2_field(const char *name, size_t namesize, const uint8_t *value, size_t valuesize) {
    /* nghttp2_submit_response2 copies both spans unless a NO_COPY flag is set. */
    nghttp2_nv result = { (uint8_t *)name, (uint8_t *)value, namesize, valuesize, NGHTTP2_NV_FLAG_NONE };
    return result;
}

int flint_h2_reply(flint_h2_session *owner, int32_t stream, unsigned status,
                   const uint8_t *type, size_t type_length, size_t body_length, int suppress_body) {
    if (owner == NULL || stream <= 0 || status < 200 || status > 599 || type_length > 256 ||
        (type == NULL && type_length != 0))
        return -1;
    const uint8_t status_text[] = {
        (uint8_t)('0' + status / 100),
        (uint8_t)('0' + status / 10 % 10),
        (uint8_t)('0' + status % 10)
    };
    uint8_t length_text[sizeof(size_t) * 3];
    size_t first = sizeof(length_text);
    size_t remaining = body_length;
    do {
        length_text[--first] = (uint8_t)('0' + remaining % 10);
        remaining /= 10;
    } while (remaining != 0);

    nghttp2_nv fields[3];
    fields[0] = h2_field(":status", 7, status_text, sizeof(status_text));
    fields[1] = h2_field("content-length", 14, length_text + first, sizeof(length_text) - first);
    if (type_length != 0)
        fields[2] = h2_field("content-type", 12, type, type_length);
    nghttp2_data_provider2 provider = { .read_callback = h2_write_body };
    nghttp2_data_provider2 *body = body_length != 0 && !suppress_body ? &provider : NULL;
    if (body != NULL && owner->body == NULL)
        return -1;
    return nghttp2_submit_response2(owner->native, stream, fields, type_length != 0 ? 3 : 2, body);
}

static int bounded_fields(const flint_h2_field *fields, size_t count, size_t *total) {
    *total = 0;
    if (count > FLINT_H2_MAX_OUTPUT_FIELDS || (count != 0 && fields == NULL))
        return 0;
    for (size_t index = 0; index < count; ++index) {
        const flint_h2_field *field = &fields[index];
        if (field->name == NULL || field->name_length == 0 || field->name_length > 128 ||
                (field->value == NULL && field->value_length != 0) || field->value_length > 4096)
            return 0;
        *total += field->name_length + field->value_length + 32;
        if (*total > FLINT_H2_MAX_OUTPUT_FIELD_BYTES)
            return 0;
    }
    return 1;
}

static int store_trailer(flint_h2_session *owner, int32_t stream, const flint_h2_field *fields,
                         size_t count, size_t total) {
    if (count == 0)
        return 0;
    if (owner->trailer_count == FLINT_H2_MAX_STREAMS)
        return -1;
    for (flint_h2_trailer *node = owner->trailers; node != NULL; node = node->next) {
        if (node->stream == stream)
            return -1;
    }
    flint_h2_trailer *node = malloc(sizeof(*node) + total);
    if (node == NULL)
        return -1;
    size_t offset = 0;
    for (size_t index = 0; index < count; ++index) {
        const flint_h2_field *field = &fields[index];
        uint8_t *name = node->bytes + offset;
        memcpy(name, field->name, field->name_length);
        offset += field->name_length;
        uint8_t *value = node->bytes + offset;
        if (field->value_length != 0)
            memcpy(value, field->value, field->value_length);
        offset += field->value_length;
        node->fields[index] = h2_field((const char *)name, field->name_length, value, field->value_length);
    }
    node->count = count;
    node->stream = stream;
    node->next = owner->trailers;
    owner->trailers = node;
    ++owner->trailer_count;
    return 0;
}

int flint_h2_stream_headers(flint_h2_session *owner, int32_t stream, unsigned status,
                            const flint_h2_field *fields, size_t count) {
    size_t total;
    if (owner == NULL || owner->body == NULL || stream <= 0 ||
            !bounded_fields(fields, count, &total))
        return -1;
    if (status == 0)
        return store_trailer(owner, stream, fields, count, total);
    if (status < 200 || status > 599)
        return -1;
    const uint8_t status_text[] = {
        (uint8_t)('0' + status / 100),
        (uint8_t)('0' + status / 10 % 10),
        (uint8_t)('0' + status % 10)
    };
    nghttp2_nv headers[FLINT_H2_MAX_OUTPUT_FIELDS + 1];
    headers[0] = h2_field(":status", 7, status_text, sizeof(status_text));
    for (size_t index = 0; index < count; ++index)
        headers[index + 1] = h2_field(fields[index].name, fields[index].name_length,
                                     (const uint8_t *)fields[index].value, fields[index].value_length);

    nghttp2_data_provider2 provider = { .read_callback = h2_write_body };
    return nghttp2_submit_response2(owner->native, stream, headers, count + 1, &provider);
}

int flint_h2_consume_stream(flint_h2_session *owner, int32_t stream, size_t count) {
    if (owner == NULL || stream <= 0 || count == 0 || count > 65535)
        return -1;
    return nghttp2_session_consume_stream(owner->native, stream, count);
}

int flint_h2_resume_stream(flint_h2_session *owner, int32_t stream) {
    if (owner == NULL || stream <= 0)
        return -1;
    const int result = nghttp2_session_resume_data(owner->native, stream);
    /* An active provider needs no resume operation when its DATA was never deferred. */
    return result == NGHTTP2_ERR_INVALID_ARGUMENT ? 0 : result;
}

int flint_h2_reset(flint_h2_session *owner, int32_t stream, uint32_t code) {
    if (owner == NULL || stream <= 0)
        return -1;
    return nghttp2_submit_rst_stream(owner->native, NGHTTP2_FLAG_NONE, stream, code);
}

int flint_h2_drain(flint_h2_session *owner) {
    if (owner == NULL)
        return -1;
    const int32_t last = nghttp2_session_get_last_proc_stream_id(owner->native);
    return nghttp2_submit_goaway(owner->native, NGHTTP2_FLAG_NONE, last, NGHTTP2_NO_ERROR, NULL, 0);
}

int flint_h2_pending(const flint_h2_session *owner) {
    return owner != NULL && owner->pending_length != 0;
}

int flint_h2_done(const flint_h2_session *owner) {
    return owner != NULL && owner->pending_length == 0 &&
        !nghttp2_session_want_read(owner->native) && !nghttp2_session_want_write(owner->native);
}

void flint_h2_free(flint_h2_session *owner) {
    if (owner != NULL) {
        nghttp2_session_del(owner->native);
        while (owner->trailers != NULL) {
            flint_h2_trailer *node = owner->trailers;
            owner->trailers = node->next;
            free(node);
        }
        free(owner);
    }
}
#endif
