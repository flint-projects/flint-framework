#ifndef FLINT_SECURITY_ABI_H
#define FLINT_SECURITY_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum flint_security_status {
    FLINT_SEC_OK, FLINT_SEC_ARGUMENT, FLINT_SEC_MEMORY, FLINT_SEC_CANCELLED, FLINT_SEC_TIMEOUT,
    FLINT_SEC_NOT_FOUND, FLINT_SEC_CONFLICT, FLINT_SEC_IO, FLINT_SEC_UNAVAILABLE, FLINT_SEC_UNSUPPORTED,
    FLINT_SEC_DENIED, FLINT_SEC_EXHAUSTED, FLINT_SEC_WAITING
};

typedef struct flint_jwk flint_jwk;

int flint_sha256(const uint8_t *input, size_t input_length, uint8_t output[32]);
int flint_hmac_sha256(const uint8_t *key, size_t key_length,
                      const uint8_t *input, size_t input_length, uint8_t output[32]);
int flint_jws_verify(int algorithm, const uint8_t *key_der, size_t key_length,
                     const uint8_t *input, size_t input_length,
                     const uint8_t *signature, size_t signature_length);
int flint_password_hash(const uint8_t *password, size_t password_length,
                         char *output, size_t output_capacity,
                         uint64_t opslimit, size_t memlimit);
int flint_password_verify(const char *encoded, const uint8_t *password, size_t password_length);

/* Extensions for startup-owned keys, per-issuer rate limits and bounded Argon2 workers. */
int flint_crypto_initialize(void);
void flint_crypto_wipe(void *bytes, size_t length);
int flint_jwk_create(unsigned algorithm, const uint8_t *first, size_t first_length,
                      const uint8_t *second, size_t second_length, flint_jwk **output);
int flint_jwk_retain(flint_jwk *key);
void flint_jwk_release(flint_jwk *key);
int flint_jwk_verify(const flint_jwk *key, unsigned algorithm, const uint8_t *input, size_t input_length,
                      const uint8_t *signature, size_t signature_length);
int flint_jwks_rate_register(const uint8_t *issuer, size_t length, int64_t now_ns, unsigned *index);
int flint_jwks_rate_begin(unsigned index, int64_t now_ns);
void flint_jwks_rate_end(unsigned index);
void flint_jwks_rate_release(unsigned index);
int flint_sodium_initialize(void);
void flint_sodium_wipe(void *bytes, size_t length);
int flint_password_workers(void);
int flint_password_submit(unsigned verify, const uint8_t *password, size_t password_length,
                           const char *encoded, size_t encoded_length, uint64_t *ticket);
int flint_password_take(uint64_t ticket, uint8_t *output, size_t capacity, size_t *length);
int flint_password_abandon(uint64_t ticket);

#ifdef __cplusplus
}
#endif

#endif
