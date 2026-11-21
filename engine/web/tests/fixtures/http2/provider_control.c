/* Linux comparison server for h2spec. It exercises the same pinned C adapter without D transport. */
#include "flint_web.h"
#include <arpa/inet.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

enum { streams = 100, reply_size = 128 * 1024 };

struct row {
    int32_t id;
    int ended;
    int head;
    size_t written;
};

static struct row requests[streams];

static struct row *find(int32_t stream) {
    for (unsigned i = 0; i < streams; ++i)
        if (requests[i].id == stream)
            return &requests[i];
    return NULL;
}

static int sink(uint64_t token, uint32_t event, int32_t stream, uint32_t code,
                const uint8_t *name, size_t names, const uint8_t *value, size_t bytes) {
    (void)code;
    if (token != 1)
        return -1;
    if (event == FLINT_H2_BEGIN) {
        struct row *record = find(0);
        if (record == NULL)
            return 7;
        record->id = stream;
        return 0;
    }
    struct row *row = stream > 0 ? find(stream) : NULL;
    if (row == NULL)
        return 0;
    if (event == FLINT_H2_END)
        row->ended = 1;
    if (event == FLINT_H2_FIELD && names == 7 && memcmp(name, ":method", 7) == 0)
        row->head = bytes == 4 && memcmp(value, "HEAD", 4) == 0;
    if (event == FLINT_H2_CLOSED)
        memset(row, 0, sizeof(*row));
    return 0;
}

static ptrdiff_t produce(uint64_t token, int32_t stream, uint8_t *output, size_t capacity, int *eof) {
    struct row *row = find(stream);
    if (token != 1 || row == NULL || row->written > reply_size)
        return -1;
    const size_t remaining = reply_size - row->written;
    const size_t count = remaining < capacity ? remaining : capacity;
    for (size_t index = 0; index < count; ++index)
        output[index] = (uint8_t)('a' + (row->written + index) % 23);
    row->written += count;
    *eof = row->written == reply_size;
    return (ptrdiff_t)count;
}

static int send_all(int fd, const uint8_t *data, size_t length) {
    while (length != 0) {
        const ssize_t count = send(fd, data, length, MSG_NOSIGNAL);
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
            return -1;
        data += count;
        length -= (size_t)count;
    }
    return 0;
}

static void serve(int fd) {
    memset(requests, 0, sizeof(requests));
    flint_h2_session *session = flint_h2_new_token(1, 4, sink, produce);
    if (session == NULL)
        return;

    struct timeval timeout = { .tv_sec = 3 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    uint8_t data[4096];
    for (;;) {
        size_t written;
        do {
            if (flint_h2_send(session, data, sizeof(data), &written) != 0 ||
                (written != 0 && send_all(fd, data, written) != 0))
                goto done;
        } while (written != 0);
        if (flint_h2_done(session))
            break;
        const ssize_t count = recv(fd, data, sizeof(data), 0);
        if (count <= 0 || flint_h2_feed(session, data, (size_t)count) != 0)
            break;
        for (unsigned slot = 0; slot < streams; ++slot) {
            struct row *request = &requests[slot];
            if (request->ended) {
                request->ended = 0;
                const uint8_t *type = (const uint8_t *)"application/octet-stream";
                if (flint_h2_reply(session, request->id, 200, type, 24, reply_size, request->head) != 0)
                    goto done;
            }
        }
    }
done:
    flint_h2_free(session);
}

int main(int argc, char **argv) {
    if (argc != 2)
        return 2;
    const unsigned long port = strtoul(argv[1], NULL, 10);
    if (port == 0 || port > 65535)
        return 2;
    const int listener = socket(AF_INET, SOCK_STREAM, 0);
    const struct sockaddr_in address = {
        .sin_family = AF_INET, .sin_port = htons((uint16_t)port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)
    };
    if (listener < 0 || bind(listener, (const struct sockaddr *)&address, sizeof(address)) != 0
        || listen(listener, 64) != 0)
        return 1;
    for (;;) {
        const int connection = accept(listener, NULL, NULL);
        if (connection < 0) {
            if (errno == EINTR)
                continue;
            return 1;
        }
        serve(connection);
        close(connection);
    }
}
