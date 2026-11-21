/* Paired pinned nghttp2 client and Flint C shim; no replacement frame parser. */
#include "flint_web.h"
#include <nghttp2/nghttp2.h>
#include <stdio.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "check failed at line %d: %s\n", __LINE__, #condition); return 1; } \
} while (0)

static struct {
    uint32_t started;
    uint32_t ended;
    uint32_t cancelled;
    uint32_t paths;
    size_t produced[4];
    size_t received[4];
    char response[4][32];
    int goaway;
} evidence;

static const uint8_t payload[] = "window-limited";

static int observe(uint64_t token, uint32_t event, int32_t stream, uint32_t code,
                   const uint8_t *name, size_t n, const uint8_t *value, size_t v) {
    if (token != 998 || stream < 0 || stream > 3)
        return -1;
    const uint32_t bit = 1u << (unsigned)stream;
    if (event == FLINT_H2_BEGIN)
        evidence.started |= bit;
    if (event == FLINT_H2_END)
        evidence.ended |= bit;
    if (event == FLINT_H2_CLOSED && code == NGHTTP2_CANCEL)
        evidence.cancelled |= bit;
    if (event == FLINT_H2_FIELD && n == 5 && memcmp(name, ":path", 5) == 0 &&
        v == 5 && memcmp(value, "/echo", 5) == 0)
        evidence.paths |= bit;
    return 0;
}

static ptrdiff_t body(uint64_t token, int32_t stream, uint8_t *out, size_t cap, int *eof) {
    if (token != 998 || stream < 1 || stream > 3)
        return -1;
    const size_t remaining = sizeof(payload) - 1 - evidence.produced[stream];
    const size_t count = remaining < cap ? remaining : cap;
    memcpy(out, payload + evidence.produced[stream], count);
    evidence.produced[stream] += count;
    *eof = count == remaining;
    return (ptrdiff_t)count;
}

static int recv_data(nghttp2_session *session, uint8_t flags, int32_t id,
                     const uint8_t *data, size_t length, void *user) {
    (void)session;
    (void)flags;
    (void)user;
    if (id < 1 || id > 3 || length > sizeof(evidence.response[id]) - evidence.received[id])
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    memcpy(evidence.response[id] + evidence.received[id], data, length);
    evidence.received[id] += length;
    return 0;
}

static int recv_frame(nghttp2_session *session, const nghttp2_frame *frame, void *user) {
    (void)session;
    (void)user;
    if (frame->hd.type == NGHTTP2_GOAWAY && frame->goaway.error_code == NGHTTP2_NO_ERROR)
        evidence.goaway = 1;
    return 0;
}

static int pump(nghttp2_session *client, flint_h2_session *server) {
    for (unsigned round = 0; round < 32; ++round) {
        int progress = 0;
        const uint8_t *address;
        nghttp2_ssize count;
        while ((count = nghttp2_session_mem_send2(client, &address)) != 0) {
            CHECK(count > 0);
            for (nghttp2_ssize offset = 0; offset < count; ++offset)
                CHECK(flint_h2_feed(server, address + offset, 1) == 0);
            progress = 1;
        }
        size_t written;
        uint8_t fragment[17];
        do {
            CHECK(flint_h2_send(server, fragment, sizeof(fragment), &written) == 0);
            if (written != 0) {
                CHECK(nghttp2_session_mem_recv2(client, fragment, written) == (nghttp2_ssize)written);
                progress = 1;
            }
        } while (written != 0);
        if (!progress)
            return 0;
    }
    return 1;
}

#define NV(name, value) { (uint8_t *)(name), (uint8_t *)(value), sizeof(name)-1, sizeof(value)-1, NGHTTP2_NV_FLAG_NONE }

int main(void) {
    CHECK(flint_h2_new_token(0, 2, observe, body) == NULL);
    CHECK(flint_h2_new_token(998, 101, observe, body) == NULL);
    CHECK(flint_h2_new_token(998, 2, NULL, body) == NULL);
    flint_h2_session *server = flint_h2_new_token(998, 2, observe, body);
    CHECK(server != NULL);
    size_t written = 8;
    CHECK(flint_h2_send(server, NULL, 1, &written) != 0 && written == 0);
    CHECK(flint_h2_feed(server, NULL, 1) != 0);

    nghttp2_session_callbacks *callbacks = NULL;
    nghttp2_option *options = NULL;
    nghttp2_session *client = NULL;
    CHECK(nghttp2_session_callbacks_new(&callbacks) == 0);
    CHECK(nghttp2_option_new(&options) == 0);
    nghttp2_option_set_no_auto_window_update(options, 1);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, recv_data);
    nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, recv_frame);
    CHECK(nghttp2_session_client_new2(&client, callbacks, NULL, options) == 0);
    nghttp2_session_callbacks_del(callbacks);
    nghttp2_option_del(options);
    const nghttp2_settings_entry settings = { NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, 0 };
    CHECK(nghttp2_submit_settings(client, NGHTTP2_FLAG_NONE, &settings, 1) == 0);
    CHECK(pump(client, server) == 0);
    CHECK(nghttp2_session_get_remote_settings(client, NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS) == 2);

    const nghttp2_nv headers[] = {
        NV(":method", "GET"), NV(":scheme", "http"), NV(":authority", "localhost"), NV(":path", "/echo")
    };
    CHECK(nghttp2_submit_request2(client, NULL, headers, 4, NULL, NULL) == 1);
    CHECK(nghttp2_submit_request2(client, NULL, headers, 4, NULL, NULL) == 3);
    CHECK(pump(client, server) == 0);
    CHECK(evidence.started == 10 && evidence.ended == 10 && evidence.paths == 10);

    CHECK(flint_h2_reply(server, 1, 200, (const uint8_t *)"text/plain", 10, sizeof(payload) - 1, 0) == 0);
    CHECK(flint_h2_reply(server, 3, 200, (const uint8_t *)"text/plain", 10, sizeof(payload) - 1, 0) == 0);
    CHECK(pump(client, server) == 0);
    CHECK(evidence.produced[1] == 0 && evidence.produced[3] == 0);

    CHECK(nghttp2_submit_window_update(client, NGHTTP2_FLAG_NONE, 1, 4) == 0);
    CHECK(pump(client, server) == 0);
    CHECK(evidence.produced[1] == 4 && evidence.received[1] == 4 && evidence.produced[3] == 0);

    CHECK(nghttp2_submit_rst_stream(client, NGHTTP2_FLAG_NONE, 3, NGHTTP2_CANCEL) == 0);
    CHECK(nghttp2_submit_window_update(client, NGHTTP2_FLAG_NONE, 1, 32) == 0);
    CHECK(pump(client, server) == 0);
    CHECK(evidence.cancelled == 8 && evidence.received[3] == 0);
    CHECK(evidence.received[1] == sizeof(payload) - 1);
    CHECK(memcmp(evidence.response[1], payload, sizeof(payload) - 1) == 0);

    CHECK(flint_h2_drain(server) == 0);
    CHECK(pump(client, server) == 0 && evidence.goaway);
    nghttp2_session_del(client);
    flint_h2_free(server);
    puts("pinned HTTP/2 interleaving, zero windows, WINDOW_UPDATE credit, RST_STREAM and GOAWAY passed");
    return 0;
}
