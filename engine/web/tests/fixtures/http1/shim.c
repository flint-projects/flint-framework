/* Pinned llhttp shim tests independent of the D transport and reactor. */
#include "flint_web.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static struct {
    size_t begun;
    size_t finished;
    size_t target_len;
    size_t body_len;
    char target[32];
    char body[32];
} events;

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "check failed at line %d: %s\n", __LINE__, #condition); return 1; } \
} while (0)

static int observe(uint64_t token, uint32_t event, const uint8_t *data, size_t length) {
    if (token != 617)
        return -1;
    if (event == FLINT_HTTP_BEGIN)
        ++events.begun;
    if (event == FLINT_HTTP_COMPLETE)
        ++events.finished;
    if (event == FLINT_HTTP_TARGET) {
        if (length > sizeof(events.target) - events.target_len)
            return -1;
        if (length != 0)
            memcpy(events.target + events.target_len, data, length);
        events.target_len += length;
    }
    if (event == FLINT_HTTP_BODY) {
        if (length > sizeof(events.body) - events.body_len)
            return -1;
        if (length != 0)
            memcpy(events.body + events.body_len, data, length);
        events.body_len += length;
    }
    return 0;
}

static int bad_request(const char *text) {
    flint_http1_parser *parser = flint_http1_new_token(617, observe);
    CHECK(parser != NULL);
    int code = flint_http1_feed(parser, (const uint8_t *)text, strlen(text));
    flint_http1_free(parser);
    CHECK(code == FLINT_HTTP1_FAILED);
    return 0;
}

int main(void) {
    CHECK(flint_http1_new_token(0, observe) == NULL);
    CHECK(flint_http1_new_token(617, NULL) == NULL);
    CHECK(flint_http1_new(NULL, NULL) == NULL);
    size_t consumed = 5;
    CHECK(flint_http1_feed_some(NULL, NULL, 0, &consumed) == FLINT_HTTP1_FAILED);
    CHECK(consumed == 0);

    const char bytes[] = "POST /joined HTTP/1.1\r\nHost: localhost\r\n"
                         "Transfer-Encoding: chunked\r\n\r\n2\r\nab\r\n3\r\ncde\r\n0\r\n\r\n"
                         "GET /next HTTP/1.0\r\n\r\n";
    flint_http1_parser *parser = flint_http1_new_token(617, observe);
    CHECK(parser != NULL);
    CHECK(flint_http1_feed_some(parser, NULL, 1, &consumed) == FLINT_HTTP1_FAILED);
    CHECK(flint_http1_feed_some(parser, NULL, 0, NULL) == FLINT_HTTP1_FAILED);

    size_t position = 0;
    size_t headers = 0;
    while (position < sizeof(bytes) - 1) {
        int code = flint_http1_feed_some(parser, (const uint8_t *)bytes + position, 1, &consumed);
        CHECK(code != FLINT_HTTP1_FAILED && consumed <= 1);
        position += consumed;
        if (code == FLINT_HTTP1_HEADERS) {
            flint_http1_info metadata;
            CHECK(flint_http1_headers(parser, &metadata) == 0);
            CHECK(metadata.major == 1);
            if (headers++ == 0) {
                CHECK(metadata.minor == 1 && metadata.method == 1 && metadata.chunked && metadata.keep_alive);
            } else {
                CHECK(metadata.minor == 0 && metadata.method == 0 && !metadata.chunked && !metadata.keep_alive);
            }
        }
    }
    CHECK(flint_http1_feed_some(parser, NULL, 0, &consumed) == FLINT_HTTP1_COMPLETE);
    CHECK(events.begun == 2 && headers == 2 && events.finished == 2);
    CHECK(events.target_len == 12 && memcmp(events.target, "/joined/next", 12) == 0);
    CHECK(events.body_len == 5 && memcmp(events.body, "abcde", 5) == 0);
    flint_http1_free(parser);

    CHECK(bad_request("POST / HTTP/1.1\r\nHost: x\r\n"
                      "Content-Length: 1\r\nContent-Length: 2\r\n\r\nx") == 0);
    CHECK(bad_request("POST / HTTP/1.1\r\nHost: x\r\n"
                      "Content-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n") == 0);
    CHECK(bad_request("GET / HTTP/1.1\r\nHost: x\r\nBad Field: x\r\n\r\n") == 0);
    puts("llhttp shim joined byte-sized fragments, paused twice per request, and rejected invalid framing");
    return 0;
}
