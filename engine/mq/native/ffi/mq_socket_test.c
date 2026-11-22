/* White-box test: the MQ client socket disables Nagle's algorithm on TCP connections. */
#include "flint_mq_socket.c"

#include <netinet/in.h>
#include <netinet/tcp.h>
#include <string.h>

int main(void)
{
    const int listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof address;
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof address) != 0 || listen(listener, 1) != 0
        || getsockname(listener, (struct sockaddr *)&address, &length) != 0) {
        perror("listener");
        return 2;
    }
    flint_mq_socket *client = NULL;
    if (flint_mq_socket_open("127.0.0.1", ntohs(address.sin_port), &client) != FLINT_MQ_OK || !client) {
        fprintf(stderr, "open failed\n");
        return 2;
    }
    int enabled = 0;
    socklen_t size = sizeof enabled;
    if (getsockopt(client->fd, IPPROTO_TCP, TCP_NODELAY, &enabled, &size) != 0) {
        perror("getsockopt");
        return 2;
    }
    flint_mq_socket_close(client);
    close(listener);
    if (!enabled) {
        fprintf(stderr, "MQ socket coalesces small writes (TCP_NODELAY unset)\n");
        return 1;
    }
    return 0;
}
