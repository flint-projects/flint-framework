#include "flint_reactor_uring.h"

#include <arpa/inet.h>
#include <errno.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#define CHECK(condition)                                                             \
    do {                                                                             \
        if (!(condition)) {                                                          \
            fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition);            \
            exit(EXIT_FAILURE);                                                       \
        }                                                                            \
    } while (0)

static int probe_denial(void)
{
    struct sock_filter instructions[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_io_uring_setup, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog filter = {
        .len = sizeof(instructions) / sizeof(instructions[0]),
        .filter = instructions,
    };
    CHECK(prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0);
    CHECK(prctl(PR_SET_SECCOMP, (unsigned long)SECCOMP_MODE_FILTER, &filter) == 0);
    void *owner = &filter;
    CHECK(flint_uring_open(8, &owner) == -EPERM);
    CHECK(owner == NULL);
    return 0;
}

static int wait_for(void *owner, uint64_t expected_token)
{
    uint64_t token = 0;
    int result = 0;
    CHECK(flint_uring_wait(owner, 1000, &token, &result) == 1);
    CHECK(token == expected_token);
    return result;
}

static void round_trip(void *owner)
{
    const uint64_t read_token = UINT64_C(1) << 32;
    const uint64_t write_token = read_token + 1;
    int sockets[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) == 0);
    uint8_t input[] = {0xff, 0x00, 0x7f, 0x20};
    uint8_t output[sizeof(input)] = {0};
    CHECK(flint_uring_recv(owner, sockets[0], output, sizeof(output), 0) == -EINVAL);
    CHECK(flint_uring_send(owner, sockets[1], NULL, sizeof(input), write_token) == -EINVAL);
    CHECK(flint_uring_send(owner, sockets[1], input, sizeof(input), write_token) == 0);
    CHECK(wait_for(owner, write_token) == sizeof(input));
    CHECK(flint_uring_recv(owner, sockets[0], output, sizeof(output), read_token) == 0);
    CHECK(wait_for(owner, read_token) == sizeof(output));
    CHECK(memcmp(input, output, sizeof(input)) == 0);

    CHECK(flint_uring_recv(owner, sockets[0], output, sizeof(output), read_token) == 0);
    uint64_t token;
    int result;
    CHECK(flint_uring_wait(owner, 10, &token, &result) == 0);
    CHECK(flint_uring_cancel(owner, read_token) == 0);
    unsigned seen = 0;
    for (size_t i = 0; i < 2; ++i) {
        CHECK(flint_uring_wait(owner, 1000, &token, &result) == 1);
        if (token == read_token) {
            CHECK(result == -ECANCELED);
            seen |= 1;
        } else {
            CHECK(token == 0 && result == 0);
            seen |= 2;
        }
    }
    CHECK(seen == 3);

    CHECK(shutdown(sockets[1], SHUT_WR) == 0);
    CHECK(flint_uring_recv(owner, sockets[0], output, sizeof(output), read_token) == 0);
    CHECK(wait_for(owner, read_token) == 0);
    CHECK(close(sockets[0]) == 0);
    CHECK(close(sockets[1]) == 0);
}

static void accept_connection(void *owner)
{
    int listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    CHECK(listener >= 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    CHECK(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0);
    CHECK(listen(listener, 2) == 0);
    socklen_t size = sizeof(address);
    CHECK(getsockname(listener, (struct sockaddr *)&address, &size) == 0);
    CHECK(flint_uring_accept(owner, listener, 1) == 0);
    int client = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    CHECK(client >= 0);
    CHECK(connect(client, (struct sockaddr *)&address, size) == 0);
    int accepted = wait_for(owner, 1);
    CHECK(accepted >= 0);
    CHECK(close(accepted) == 0);
    CHECK(close(client) == 0);
    CHECK(close(listener) == 0);
}

static void borrowed_readiness(void *owner)
{
    const uint64_t token = UINT64_C(1) << 40;
    int ends[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, ends) == 0);
    CHECK(flint_uring_poll_readable(owner, -1, token) == -EINVAL);
    CHECK(flint_uring_poll_readable(owner, ends[0], 0) == -EINVAL);
    CHECK(flint_uring_poll_readable(owner, ends[0], token) == 0);
    uint64_t observed;
    int state;
    CHECK(flint_uring_wait(owner, 5, &observed, &state) == 0);
    const char input = 42;
    CHECK(write(ends[1], &input, 1) == 1);
    const int outcome = wait_for(owner, token);
    CHECK(outcome >= 0 && (outcome & POLLIN) != 0);
    char result;
    CHECK(read(ends[0], &result, 1) == 1 && result == input);
    CHECK(close(ends[0]) == 0 && close(ends[1]) == 0);
}

int main(int argc, char *argv[])
{
    if (argc == 2 && strcmp(argv[1], "--deny-setup") == 0)
        return probe_denial();
    void *owner = &argc;
    CHECK(flint_uring_open(0, &owner) == -EINVAL);
    CHECK(owner == NULL);
    int status = flint_uring_open(8, &owner);
    if (status == -ENOSYS || status == -EPERM || status == -EACCES || status == -EOPNOTSUPP) {
        fprintf(stderr, "io_uring unavailable on this host: %s\n", strerror(-status));
        return 77;
    }
    CHECK(status == 0 && owner != NULL);
    round_trip(owner);
    accept_connection(owner);
    borrowed_readiness(owner);
    flint_uring_close(owner);
    return 0;
}
