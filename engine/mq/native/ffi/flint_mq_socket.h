#ifndef FLINT_MQ_SOCKET_H
#define FLINT_MQ_SOCKET_H

#include <stddef.h>
#include <stdint.h>

typedef struct flint_mq_socket flint_mq_socket;

int flint_mq_socket_open(const char *host, uint16_t port, flint_mq_socket **output);
int flint_mq_socket_connected(flint_mq_socket *socket);
int flint_mq_socket_tls(flint_mq_socket *socket, const char *host, const char *ca_bundle);
int flint_mq_socket_handshake(flint_mq_socket *socket);
int flint_mq_socket_read(flint_mq_socket *socket, uint8_t *data, size_t capacity, size_t *received);
int flint_mq_socket_write(flint_mq_socket *socket, const uint8_t *data, size_t length, size_t *written);
void flint_mq_socket_close(flint_mq_socket *socket);

#endif
