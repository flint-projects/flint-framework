/* Independent pinned client exercising both sides of the memory BIO ownership boundary. */
#include "flint_web.h"
#include <openssl/ssl.h>
#include <stdio.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "check failed at line %d: %s\n", __LINE__, #condition); return 1; } \
} while (0)

static int to_server(SSL *client, flint_tls_session *server) {
    uint8_t bytes[13];
    int count;
    while ((count = BIO_read(SSL_get_wbio(client), bytes, sizeof(bytes))) > 0)
        if (flint_tls_receive(server, bytes, (size_t)count) != 0)
            return -1;
    return 0;
}

static int to_client(flint_tls_session *server, SSL *client) {
    uint8_t fragment[19];
    while (flint_tls_pending(server)) {
        const size_t count = flint_tls_send(server, fragment, sizeof(fragment));
        if (count == 0 || BIO_write(SSL_get_rbio(client), fragment, (int)count) != (int)count)
            return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    CHECK(argc == 4);
    CHECK(flint_tls_open(NULL, argv[2], 1) == NULL);
    CHECK(flint_tls_open(argv[1], argv[3], 1) == NULL);
    CHECK(flint_tls_accept(NULL) == NULL);
    flint_tls_context *server_context = flint_tls_open(argv[1], argv[2], 1);
    CHECK(server_context != NULL);
    flint_tls_session *server = flint_tls_accept(server_context);
    CHECK(server != NULL && flint_tls_protocol(server) == 0);
    CHECK(flint_tls_receive(server, NULL, 1) != 0);
    size_t bytes = 9;
    CHECK(flint_tls_read(server, NULL, 1, &bytes) == FLINT_TLS_ERROR && bytes == 0);
    CHECK(flint_tls_write(server, NULL, 1, &bytes) == FLINT_TLS_ERROR && bytes == 0);

    SSL_CTX *client_context = SSL_CTX_new(TLS_client_method());
    CHECK(client_context != NULL);
    CHECK(SSL_CTX_load_verify_locations(client_context, argv[1], NULL) == 1);
    SSL_CTX_set_verify(client_context, SSL_VERIFY_PEER, NULL);
    SSL *client = SSL_new(client_context);
    CHECK(client != NULL && SSL_set1_host(client, "localhost") == 1);
    static const unsigned char offered[] = { 8, 'h', 't', 't', 'p', '/', '1', '.', '1', 2, 'h', '2' };
    CHECK(SSL_set_alpn_protos(client, offered, sizeof(offered)) == 0);
    BIO *incoming = BIO_new(BIO_s_mem());
    BIO *outgoing = BIO_new(BIO_s_mem());
    CHECK(incoming != NULL && outgoing != NULL);
    BIO_set_mem_eof_return(incoming, -1);
    BIO_set_mem_eof_return(outgoing, -1);
    SSL_set_bio(client, incoming, outgoing);
    SSL_set_connect_state(client);
    for (unsigned round = 0; round < 16; ++round) {
        int result = SSL_do_handshake(client);
        CHECK(result == 1 || SSL_get_error(client, result) == SSL_ERROR_WANT_READ);
        CHECK(to_server(client, server) == 0 && flint_tls_handshake(server) >= 0 && to_client(server, client) == 0);
        if (SSL_is_init_finished(client) && flint_tls_protocol(server) != 0)
            break;
    }
    CHECK(SSL_is_init_finished(client) && flint_tls_protocol(server) == 2);
    CHECK(SSL_get_verify_result(client) == X509_V_OK);
    CHECK(SSL_write_ex(client, "ping", 4, &bytes) == 1 && bytes == 4);
    CHECK(to_server(client, server) == 0);
    uint8_t output[8];
    CHECK(flint_tls_read(server, output, sizeof(output), &bytes) == FLINT_TLS_READY);
    CHECK(bytes == 4 && memcmp(output, "ping", 4) == 0);
    CHECK(flint_tls_write(server, (const uint8_t *)"pong", 4, &bytes) == FLINT_TLS_READY);
    CHECK(bytes == 4 && to_client(server, client) == 0);
    CHECK(SSL_read_ex(client, output, sizeof(output), &bytes) == 1);
    CHECK(bytes == 4 && memcmp(output, "pong", 4) == 0);

    CHECK(flint_tls_shutdown(server) >= 0 && to_client(server, client) == 0);
    int closed = SSL_read_ex(client, output, sizeof(output), &bytes);
    CHECK(closed == 0 && SSL_get_error(client, closed) == SSL_ERROR_ZERO_RETURN);
    SSL_free(client);
    SSL_CTX_free(client_context);
    flint_tls_free(server);
    flint_tls_close(server_context);
    puts("pinned OpenSSL trust and ALPN, fragmented BIO transfers and close_notify passed");
    return 0;
}
