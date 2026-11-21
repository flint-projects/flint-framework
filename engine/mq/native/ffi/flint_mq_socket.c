#define _POSIX_C_SOURCE 200809L
#include "flint_mq_socket.h"

#ifdef __linux__
#include "flint_mq.h"
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

#ifdef FLINT_HAS_OPENSSL
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#endif

struct flint_mq_socket {
    int fd;
    struct addrinfo *addresses;
    struct addrinfo *remaining;
    bool connected;
#ifdef FLINT_HAS_OPENSSL
    SSL_CTX *identity;
    SSL *tls;
    uint8_t pending[16384];
    size_t pending_length, pending_offset;
#endif
};

static int start_next(flint_mq_socket *transport)
{
    while (transport->remaining) {
        struct addrinfo *address = transport->remaining;
        transport->remaining = address->ai_next;
        const int fd = socket(address->ai_family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        if (fd < 0)
            continue;
        const int status = connect(fd, address->ai_addr, address->ai_addrlen);
        if (status == 0 || errno == EINPROGRESS) {
            transport->fd = fd;
            transport->connected = status == 0;
            return FLINT_MQ_OK;
        }
        close(fd);
    }
    return FLINT_MQ_IO;
}

int flint_mq_socket_open(const char *host, uint16_t port, flint_mq_socket **output)
{
    if (!host || !host[0] || !port || !output)
        return FLINT_MQ_ARGUMENT;
    *output = NULL;
    struct addrinfo selection = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM, .ai_flags = AI_NUMERICSERV };
    char service[6];
    snprintf(service, sizeof(service), "%u", port);
    struct addrinfo *addresses;
    if (getaddrinfo(host, service, &selection, &addresses) != 0)
        return FLINT_MQ_UNAVAILABLE;
    flint_mq_socket *transport = calloc(1, sizeof(*transport));
    if (!transport) {
        freeaddrinfo(addresses);
        return FLINT_MQ_MEMORY;
    }
    transport->fd = -1;
    transport->addresses = transport->remaining = addresses;
    const int started = start_next(transport);
    if (started != FLINT_MQ_OK) {
        flint_mq_socket_close(transport);
        return started;
    }
    *output = transport;
    return FLINT_MQ_OK;
}

int flint_mq_socket_connected(flint_mq_socket *transport)
{
    if (!transport)
        return FLINT_MQ_ARGUMENT;
    if (transport->connected)
        return FLINT_MQ_OK;
    struct pollfd ready = { .fd = transport->fd, .events = POLLOUT };
    const int result = poll(&ready, 1, 0);
    if (!result || (result < 0 && errno == EINTR))
        return FLINT_MQ_UNAVAILABLE;
    int error;
    socklen_t bytes = sizeof(error);
    if (result > 0 && getsockopt(transport->fd, SOL_SOCKET, SO_ERROR, &error, &bytes) == 0 && !error) {
        transport->connected = true;
        return FLINT_MQ_OK;
    }
    close(transport->fd);
    transport->fd = -1;
    const int started = start_next(transport);
    return started == FLINT_MQ_OK && !transport->connected ? FLINT_MQ_UNAVAILABLE : started;
}

static int read_network(flint_mq_socket *transport, uint8_t *data, size_t capacity, size_t *received)
{
    const ssize_t result = recv(transport->fd, data, capacity, MSG_DONTWAIT);
    if (result >= 0) {
        *received = (size_t)result;
        return FLINT_MQ_OK;
    }
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? FLINT_MQ_UNAVAILABLE : FLINT_MQ_IO;
}

static int write_network(flint_mq_socket *transport, const uint8_t *data, size_t length, size_t *written)
{
    const ssize_t result = send(transport->fd, data, length, MSG_DONTWAIT | MSG_NOSIGNAL);
    if (result > 0) {
        *written = (size_t)result;
        return FLINT_MQ_OK;
    }
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? FLINT_MQ_UNAVAILABLE : FLINT_MQ_IO;
}

#ifdef FLINT_HAS_OPENSSL
static bool verify_name(SSL *session, const char *host)
{
    uint8_t address[16];
    if (inet_pton(AF_INET, host, address) == 1 || inet_pton(AF_INET6, host, address) == 1)
        return X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(session), host) == 1;
    return SSL_set_tlsext_host_name(session, host) == 1 && SSL_set1_host(session, host) == 1;
}

static int flush_encrypted(flint_mq_socket *transport)
{
    BIO *outgoing = SSL_get_wbio(transport->tls);
    if (transport->pending_offset == transport->pending_length) {
        transport->pending_offset = transport->pending_length = 0;
        if (BIO_ctrl_pending(outgoing) == 0)
            return FLINT_MQ_OK;
        const int ready = BIO_read(outgoing, transport->pending, sizeof(transport->pending));
        if (ready <= 0)
            return FLINT_MQ_IO;
        transport->pending_length = (size_t)ready;
    }
    size_t sent;
    const int status = write_network(transport, transport->pending + transport->pending_offset,
            transport->pending_length - transport->pending_offset, &sent);
    if (status != FLINT_MQ_OK)
        return status;
    transport->pending_offset += sent;
    return transport->pending_offset == transport->pending_length && BIO_ctrl_pending(outgoing) == 0
        ? FLINT_MQ_OK : FLINT_MQ_UNAVAILABLE;
}

static int fill_encrypted(flint_mq_socket *transport)
{
    uint8_t bytes[16384];
    size_t count;
    BIO *incoming = SSL_get_rbio(transport->tls);
    if (BIO_ctrl_pending(incoming) > sizeof(bytes))
        return FLINT_MQ_EXHAUSTED;
    const int status = read_network(transport, bytes, sizeof(bytes), &count);
    if (status != FLINT_MQ_OK)
        return status;
    if (!count)
        return FLINT_MQ_IO;
    return BIO_write(incoming, bytes, (int)count) == (int)count ? FLINT_MQ_OK : FLINT_MQ_IO;
}

static int tls_progress(flint_mq_socket *transport, int returned)
{
    const int error = SSL_get_error(transport->tls, returned);
    if (error == SSL_ERROR_WANT_READ) {
        const int flushed = flush_encrypted(transport);
        if (flushed != FLINT_MQ_OK)
            return flushed;
        const int received = fill_encrypted(transport);
        return received == FLINT_MQ_OK ? FLINT_MQ_UNAVAILABLE : received;
    }
    if (error == SSL_ERROR_WANT_WRITE) {
        const int flushed = flush_encrypted(transport);
        return flushed == FLINT_MQ_OK ? FLINT_MQ_UNAVAILABLE : flushed;
    }
    if (error == SSL_ERROR_ZERO_RETURN)
        return FLINT_MQ_OK;
    return SSL_get_verify_result(transport->tls) == X509_V_OK ? FLINT_MQ_IO : FLINT_MQ_DENIED;
}
#endif

int flint_mq_socket_tls(flint_mq_socket *transport, const char *host, const char *ca_bundle)
{
    if (!transport || !transport->connected || !host || !host[0])
        return FLINT_MQ_ARGUMENT;
#ifdef FLINT_HAS_OPENSSL
    if (transport->tls)
        return FLINT_MQ_CONFLICT;
    SSL_CTX *identity = SSL_CTX_new(TLS_client_method());
    if (!identity)
        return FLINT_MQ_MEMORY;
    transport->identity = identity;
    SSL_CTX_set_verify(identity, SSL_VERIFY_PEER, NULL);
    if (SSL_CTX_set_min_proto_version(identity, TLS1_2_VERSION) != 1
        || (ca_bundle ? SSL_CTX_load_verify_locations(identity, ca_bundle, NULL)
                      : SSL_CTX_set_default_verify_paths(identity)) != 1)
        return FLINT_MQ_DENIED;
    SSL *session = SSL_new(identity);
    if (!session)
        return FLINT_MQ_MEMORY;
    transport->tls = session;
    BIO *input = BIO_new(BIO_s_mem()), *output = BIO_new(BIO_s_mem());
    if (!input || !output) {
        BIO_free(input);
        BIO_free(output);
        return FLINT_MQ_MEMORY;
    }
    BIO_set_mem_eof_return(input, -1);
    BIO_set_mem_eof_return(output, -1);
    SSL_set_bio(session, input, output);
    SSL_set_mode(session, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    SSL_set_connect_state(session);
    return verify_name(session, host) ? FLINT_MQ_OK : FLINT_MQ_DENIED;
#else
    (void)ca_bundle;
    return FLINT_MQ_UNSUPPORTED;
#endif
}

int flint_mq_socket_handshake(flint_mq_socket *transport)
{
#ifdef FLINT_HAS_OPENSSL
    if (!transport || !transport->tls)
        return FLINT_MQ_ARGUMENT;
    const int flushed = flush_encrypted(transport);
    if (flushed != FLINT_MQ_OK)
        return flushed;
    ERR_clear_error();
    const int result = SSL_do_handshake(transport->tls);
    return result == 1 ? flush_encrypted(transport) : tls_progress(transport, result);
#else
    (void)transport;
    return FLINT_MQ_UNSUPPORTED;
#endif
}

int flint_mq_socket_read(flint_mq_socket *transport, uint8_t *data, size_t capacity, size_t *received)
{
    if (!transport || !data || !capacity || !received)
        return FLINT_MQ_ARGUMENT;
    *received = 0;
#ifdef FLINT_HAS_OPENSSL
    if (transport->tls) {
        const int flushed = flush_encrypted(transport);
        if (flushed != FLINT_MQ_OK)
            return flushed;
        ERR_clear_error();
        const int result = SSL_read_ex(transport->tls, data, capacity, received);
        return result == 1 ? FLINT_MQ_OK : tls_progress(transport, result);
    }
#endif
    return read_network(transport, data, capacity, received);
}

int flint_mq_socket_write(flint_mq_socket *transport, const uint8_t *data, size_t length, size_t *written)
{
    if (!transport || !data || !length || !written)
        return FLINT_MQ_ARGUMENT;
    *written = 0;
#ifdef FLINT_HAS_OPENSSL
    if (transport->tls) {
        const int flushed = flush_encrypted(transport);
        if (flushed != FLINT_MQ_OK)
            return flushed;
        ERR_clear_error();
        const size_t chunk = length < 16384 ? length : 16384;
        const int result = SSL_write_ex(transport->tls, data, chunk, written);
        if (result != 1)
            return tls_progress(transport, result);
        const int sent = flush_encrypted(transport);
        return sent == FLINT_MQ_UNAVAILABLE ? FLINT_MQ_OK : sent;
    }
#endif
    return write_network(transport, data, length, written);
}

void flint_mq_socket_close(flint_mq_socket *transport)
{
    if (!transport)
        return;
#ifdef FLINT_HAS_OPENSSL
    SSL_free(transport->tls);
    SSL_CTX_free(transport->identity);
#endif
    if (transport->fd >= 0)
        close(transport->fd);
    freeaddrinfo(transport->addresses);
    free(transport);
}

#endif
