/* Exercise the production HTTP bridge while its owner deliberately withholds reads. */
#define _POSIX_C_SOURCE 200809L
#include "flint_http.h"

#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint64_t now_ms(void)
{
    struct timespec stamp;
    assert(clock_gettime(CLOCK_MONOTONIC, &stamp) == 0);
    return (uint64_t)stamp.tv_sec * 1000 + (uint64_t)stamp.tv_nsec / 1000000;
}

int main(int count, char **arguments)
{
    assert(count == 4);
    const uint32_t rate = (uint32_t)strtoul(arguments[2], NULL, 10);
    const size_t expected = (size_t)strtoul(arguments[3], NULL, 10);
    const flint_http_options options = {
        .connections = 1, .per_origin = 1, .body_bytes = 2 * 1024 * 1024,
        .header_bytes = 16384, .connect_ms = 4000,
    };
    flint_curl_loop *loop = NULL;
    uint64_t stream = 0;
    assert(flint_http_new(&options, &loop) == FLINT_HTTP_OK);
    assert(flint_http_stream_begin(loop, arguments[1], strlen(arguments[1]), FLINT_HTTP_DUPLEX, 1, rate,
                                   &stream) == FLINT_HTTP_OK);
    assert(flint_http_activate(loop, stream) == FLINT_HTTP_OK);
    assert(flint_http_stream_finish_send(loop, stream) == FLINT_HTTP_OK);
    const uint64_t hold_until = now_ms() + 1350;
    flint_http_stream_view view;
    while (now_ms() < hold_until) {
        assert(flint_http_poll(loop, 5) == FLINT_HTTP_OK);
        assert(flint_http_stream_view_request(loop, stream, &view) == FLINT_HTTP_OK);
        assert(view.error == FLINT_HTTP_OK);
    }
    assert(view.status == 200 && view.version == 2 && (view.flags & FLINT_HTTP_STREAM_HEAD));
    fprintf(stdout, "held\n");
    fflush(stdout);
    /* Wait for the peer to record its send offset before restoring window credit. */
    assert(getchar() == '\n');

    size_t total = 0;
    bool finished = false;
    const uint64_t deadline = now_ms() + 20000;
    while (!finished && now_ms() < deadline) {
        uint8_t bytes[2048];
        size_t received;
        const int status = flint_http_stream_read(loop, stream, bytes, sizeof(bytes), &received);
        if (status == FLINT_HTTP_UNAVAILABLE) {
            assert(flint_http_poll(loop, 5) == FLINT_HTTP_OK);
            continue;
        }
        assert(status == FLINT_HTTP_OK);
        for (size_t i = 0; i < received; ++i)
            assert(bytes[i] == 'a');
        total += received;
        finished = received == 0;
    }
    assert(finished && total == expected);
    assert(flint_http_release(loop, stream) == FLINT_HTTP_OK);
    flint_curl_free(loop);
    fprintf(stdout, "drained=%zu\n", total);
}
