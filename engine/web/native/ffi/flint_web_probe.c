/* Native-only direct llhttp reference for the fixed web package measurement. */
#if defined(FLINT_HAS_LLHTTP)
#include <llhttp.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct web_probe {
    llhttp_t parser;
    uint8_t *target;
    size_t capacity;
    size_t used;
    size_t body;
    int complete;
} web_probe;

static int collect_target(llhttp_t *parser, const char *bytes, size_t length) {
    web_probe *fixture = parser->data;
    if (length > fixture->capacity - fixture->used)
        return HPE_USER;
    memcpy(fixture->target + fixture->used, bytes, length);
    fixture->used += length;
    return 0;
}

static int count_body(llhttp_t *parser, const char *bytes, size_t length) {
    (void)bytes;
    web_probe *fixture = parser->data;
    if (length > SIZE_MAX - fixture->body)
        return HPE_USER;
    fixture->body += length;
    return 0;
}

static int finish(llhttp_t *parser) {
    web_probe *fixture = parser->data;
    fixture->complete = 1;
    return 0;
}

static const llhttp_settings_t attributes = {
    .on_url = collect_target,
    .on_body = count_body,
    .on_message_complete = finish
};

web_probe *flint_web_probe_open(void) {
    web_probe *fixture = calloc(1, sizeof(*fixture));
    if (fixture != NULL) {
        llhttp_init(&fixture->parser, HTTP_REQUEST, &attributes);
        fixture->parser.data = fixture;
    }
    return fixture;
}

int flint_web_probe_read(web_probe *fixture, const uint8_t *input, size_t length,
                         uint8_t *target, size_t capacity, size_t *written, size_t *body) {
    if (fixture == NULL || input == NULL || target == NULL || capacity == 0 ||
        written == NULL || body == NULL || length > PTRDIFF_MAX)
        return -1;

    fixture->target = target;
    fixture->capacity = capacity;
    fixture->used = 0;
    fixture->body = 0;
    fixture->complete = 0;
    const llhttp_errno_t result = llhttp_execute(&fixture->parser, (const char *)input, length);
    fixture->target = NULL;
    *written = fixture->used;
    *body = fixture->body;
    return result == HPE_OK && fixture->complete && llhttp_get_method(&fixture->parser) == HTTP_GET ? 0 : -1;
}

void flint_web_probe_close(web_probe *fixture) {
    free(fixture);
}
#endif
