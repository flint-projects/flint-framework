/* Pinned OpenSSL server sessions with caller-driven encrypted I/O. */
#include "flint_web.h"

#if defined(FLINT_HAS_OPENSSL)
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <stdlib.h>
#include <string.h>

enum { TLS_INPUT_LIMIT = 65536, TLS_OUTPUT_LIMIT = 262144 };

struct flint_tls_context {
    SSL_CTX *native;
    int offer_h2;
};

struct flint_tls_session {
    SSL *native;
    BIO *incoming;
    BIO *outgoing;
};

static int choose_protocol(SSL *ssl, const unsigned char **selected, unsigned char *length,
                           const unsigned char *offered, unsigned int count, void *user) {
    (void)ssl;
    const flint_tls_context *context = user;
    static const unsigned char both[] = { 2, 'h', '2', 8, 'h', 't', 't', 'p', '/', '1', '.', '1' };
    const unsigned char *preferred = context->offer_h2 ? both : both + 3;
    const unsigned length_preferred = context->offer_h2 ? sizeof(both) : sizeof(both) - 3;
    unsigned char *protocol = NULL;
    if (SSL_select_next_proto(&protocol, length, preferred, length_preferred, offered, count)
        != OPENSSL_NPN_NEGOTIATED)
        return SSL_TLSEXT_ERR_ALERT_FATAL;
    *selected = protocol;
    return SSL_TLSEXT_ERR_OK;
}

static int reject_encrypted_key(char *buffer, int length, int writing, void *user) {
    (void)buffer;
    (void)length;
    (void)writing;
    (void)user;
    return 0;
}

flint_tls_context *flint_tls_open(const char *certificate, const char *key, int enable_h2) {
    if (certificate == NULL || key == NULL || *certificate == 0 || *key == 0)
        return NULL;
    flint_tls_context *context = calloc(1, sizeof(*context));
    if (context == NULL)
        return NULL;

    ERR_clear_error();
    context->native = SSL_CTX_new(TLS_server_method());
    if (context->native == NULL)
        goto failed;
    context->offer_h2 = enable_h2 != 0;
    SSL_CTX_set_default_passwd_cb(context->native, reject_encrypted_key);
    if (SSL_CTX_set_min_proto_version(context->native, TLS1_2_VERSION) != 1 ||
        SSL_CTX_set_cipher_list(context->native, "ECDHE+AESGCM:ECDHE+CHACHA20") != 1 ||
        SSL_CTX_set_max_send_fragment(context->native, 4096) != 1 ||
        SSL_CTX_use_certificate_chain_file(context->native, certificate) != 1 ||
        SSL_CTX_use_PrivateKey_file(context->native, key, SSL_FILETYPE_PEM) != 1 ||
        SSL_CTX_check_private_key(context->native) != 1)
        goto failed;

    SSL_CTX_set_options(context->native, SSL_OP_NO_RENEGOTIATION | SSL_OP_NO_COMPRESSION);
    SSL_CTX_set_mode(context->native, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_RELEASE_BUFFERS);
    SSL_CTX_set_num_tickets(context->native, 0);
    SSL_CTX_set_session_cache_mode(context->native, SSL_SESS_CACHE_OFF);
    SSL_CTX_set_alpn_select_cb(context->native, choose_protocol, context);
    return context;

failed:
    flint_tls_close(context);
    ERR_clear_error();
    return NULL;
}

void flint_tls_close(flint_tls_context *context) {
    if (context != NULL) {
        SSL_CTX_free(context->native);
        free(context);
    }
}

flint_tls_session *flint_tls_accept(flint_tls_context *context) {
    if (context == NULL)
        return NULL;
    flint_tls_session *session = calloc(1, sizeof(*session));
    if (session == NULL)
        return NULL;

    session->native = SSL_new(context->native);
    session->incoming = BIO_new(BIO_s_mem());
    session->outgoing = BIO_new(BIO_s_mem());
    if (session->native == NULL || session->incoming == NULL || session->outgoing == NULL) {
        BIO_free(session->incoming);
        BIO_free(session->outgoing);
        SSL_free(session->native);
        free(session);
        return NULL;
    }

    BIO_set_mem_eof_return(session->incoming, -1);
    BIO_set_mem_eof_return(session->outgoing, -1);
    SSL_set_bio(session->native, session->incoming, session->outgoing);
    SSL_set_accept_state(session->native);
    return session;
}

void flint_tls_free(flint_tls_session *session) {
    if (session != NULL) {
        SSL_free(session->native);
        free(session);
    }
}

int flint_tls_receive(flint_tls_session *session, const uint8_t *data, size_t length) {
    if (session == NULL || (data == NULL && length != 0) || length > TLS_INPUT_LIMIT)
        return -1;
    if (length == 0)
        return 0;
    size_t buffered = BIO_ctrl_pending(session->incoming);
    if (buffered > TLS_INPUT_LIMIT - length)
        return -1;
    return BIO_write(session->incoming, data, (int)length) == (int)length ? 0 : -1;
}

static int progress(flint_tls_session *session, int returned, int success) {
    if (!success) {
        const int failure = SSL_get_error(session->native, returned);
        if (failure == SSL_ERROR_ZERO_RETURN)
            return FLINT_TLS_EOF;
        if (failure != SSL_ERROR_WANT_READ && failure != SSL_ERROR_WANT_WRITE)
            return FLINT_TLS_ERROR;
    }
    if (BIO_ctrl_pending(session->outgoing) > TLS_OUTPUT_LIMIT)
        return FLINT_TLS_ERROR;
    return success ? FLINT_TLS_READY : FLINT_TLS_WAIT;
}

int flint_tls_handshake(flint_tls_session *session) {
    if (session == NULL)
        return FLINT_TLS_ERROR;
    ERR_clear_error();
    const int returned = SSL_do_handshake(session->native);
    return progress(session, returned, returned == 1);
}

int flint_tls_protocol(const flint_tls_session *session) {
    if (session == NULL || !SSL_is_init_finished(session->native))
        return 0;
    const unsigned char *selected;
    unsigned int length;
    SSL_get0_alpn_selected(session->native, &selected, &length);
    return length == 2 && memcmp(selected, "h2", 2) == 0 ? 2 : 1;
}

int flint_tls_read(flint_tls_session *session, uint8_t *output, size_t capacity, size_t *written) {
    if (written == NULL)
        return FLINT_TLS_ERROR;
    *written = 0;
    if (session == NULL || output == NULL || capacity == 0 || capacity > 4096)
        return FLINT_TLS_ERROR;

    ERR_clear_error();
    const int result = SSL_read_ex(session->native, output, capacity, written);
    return progress(session, result, result == 1);
}

int flint_tls_write(flint_tls_session *session, const uint8_t *input, size_t length, size_t *consumed) {
    if (consumed == NULL)
        return FLINT_TLS_ERROR;
    *consumed = 0;
    if (session == NULL || input == NULL || length == 0 || length > 4096)
        return FLINT_TLS_ERROR;

    ERR_clear_error();
    const int result = SSL_write_ex(session->native, input, length, consumed);
    return progress(session, result, result == 1);
}

size_t flint_tls_pending(const flint_tls_session *session) {
    return session == NULL ? 0 : BIO_ctrl_pending(session->outgoing);
}

size_t flint_tls_send(flint_tls_session *session, uint8_t *output, size_t capacity) {
    if (session == NULL || output == NULL || capacity == 0 || capacity > 4096)
        return 0;
    const int count = BIO_read(session->outgoing, output, (int)capacity);
    return count > 0 ? (size_t)count : 0;
}

int flint_tls_shutdown(flint_tls_session *session) {
    if (session == NULL)
        return FLINT_TLS_ERROR;
    ERR_clear_error();
    const int result = SSL_shutdown(session->native);
    if (result >= 0)
        return FLINT_TLS_READY;
    return progress(session, result, 0);
}
#endif
