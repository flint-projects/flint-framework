#define _POSIX_C_SOURCE 200809L
#include "flint_security.h"

#include <assert.h>
#include <sodium.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int flint_security_test_erased(uint64_t ticket);

static void signatures(const char *name, int algorithm)
{
    char der_name[40];
    assert(snprintf(der_name, sizeof(der_name), "%s_DER", name) > 0);
    const char *token = getenv(name);
    const char *encoded = getenv(der_name);
    assert(token && encoded);

    uint8_t der[513], signature[512];
    size_t der_length, signature_length;
    const char *end = strrchr(token, '.');
    assert(end);
    const size_t signed_length = (size_t)(end - token);
    const unsigned variant = sodium_base64_VARIANT_URLSAFE_NO_PADDING;
    assert(sodium_base642bin(der, sizeof(der), encoded, strlen(encoded), NULL, &der_length, NULL, variant) == 0);
    assert(sodium_base642bin(signature, sizeof(signature), end + 1, strlen(end + 1),
                             NULL, &signature_length, NULL, variant) == 0);
    const uint8_t *input = (const uint8_t *)token;
    assert(flint_jws_verify(algorithm, der, der_length, input, signed_length, signature, signature_length)
           == FLINT_SEC_OK);
    assert(flint_jws_verify((algorithm + 1) % 3, der, der_length, input, signed_length, signature, signature_length)
           != FLINT_SEC_OK);
    for (size_t i = 0; i < der_length; ++i)
        assert(flint_jws_verify(algorithm, der, i, input, signed_length, signature, signature_length) != FLINT_SEC_OK);
    der[der_length] = 0;
    assert(flint_jws_verify(algorithm, der, der_length + 1, input, signed_length, signature, signature_length)
           != FLINT_SEC_OK);
    for (size_t i = 0; i < signature_length; ++i)
        assert(flint_jws_verify(algorithm, der, der_length, input, signed_length, signature, i) != FLINT_SEC_OK);
    signature[0] ^= 1u;
    assert(flint_jws_verify(algorithm, der, der_length, input, signed_length, signature, signature_length)
           == FLINT_SEC_DENIED);
    assert(flint_jws_verify(-1, der, der_length, input, signed_length, signature, signature_length)
           == FLINT_SEC_ARGUMENT);
    assert(flint_jws_verify(algorithm, der, SIZE_MAX, input, signed_length, signature, signature_length)
           == FLINT_SEC_ARGUMENT);
}

static void digests(void)
{
    uint8_t output[32];
    memset(output, 0xff, sizeof(output));
    assert(flint_sha256(NULL, 1, output) == FLINT_SEC_ARGUMENT && sodium_is_zero(output, sizeof(output)));
    assert(flint_sha256(NULL, 0, output) == FLINT_SEC_OK);
    memset(output, 0xff, sizeof(output));
    assert(flint_hmac_sha256(NULL, 0, NULL, SIZE_MAX, output) == FLINT_SEC_ARGUMENT);
    assert(sodium_is_zero(output, sizeof(output)));
    assert(flint_hmac_sha256(NULL, 0, NULL, 0, output) == FLINT_SEC_OK);
}

static void worker_retirement(void)
{
    uint8_t password[1024];
    randombytes_buf(password, sizeof(password));
    password[7] = 0;
    char encoded[crypto_pwhash_STRBYTES];
    const uint64_t ops = crypto_pwhash_OPSLIMIT_INTERACTIVE;
    const size_t memory = crypto_pwhash_MEMLIMIT_INTERACTIVE;
    assert(flint_password_hash(password, sizeof(password), encoded, sizeof(encoded), ops, memory) == FLINT_SEC_OK);
    assert(flint_password_verify(encoded, password, sizeof(password)) == FLINT_SEC_OK);
    assert(flint_password_verify(encoded, password, 7) == FLINT_SEC_DENIED);
    assert(flint_password_verify(encoded, password, sizeof(password) + 1) == FLINT_SEC_ARGUMENT);
    assert(flint_password_hash(password, sizeof(password), encoded, 4, ops, memory) == FLINT_SEC_ARGUMENT);

    uint64_t first;
    assert(flint_password_submit(1, password, sizeof(password), encoded, strlen(encoded), &first) == FLINT_SEC_OK);
    assert(flint_password_abandon(first) == FLINT_SEC_OK);
    assert(flint_password_abandon(first) == FLINT_SEC_NOT_FOUND);
    const struct timespec delay = {.tv_nsec = 1000000};
    for (unsigned i = 0; i < 2000 && !flint_security_test_erased(first); ++i)
        nanosleep(&delay, NULL);
    assert(flint_security_test_erased(first));

    uint64_t second;
    assert(flint_password_submit(1, password, sizeof(password), encoded, strlen(encoded), &second) == FLINT_SEC_OK);
    assert(second != first);
    uint8_t output[1];
    size_t used;
    int status = FLINT_SEC_WAITING;
    for (unsigned i = 0; i < 2000 && status == FLINT_SEC_WAITING; ++i) {
        status = flint_password_take(second, output, sizeof(output), &used);
        if (status == FLINT_SEC_WAITING)
            nanosleep(&delay, NULL);
    }
    assert(status == FLINT_SEC_OK && used == 1 && output[0] == 1);
    assert(flint_password_take(first, output, sizeof(output), &used) == FLINT_SEC_NOT_FOUND);
    assert(flint_security_test_erased(second));
    assert(flint_password_hash(NULL, 1, encoded, sizeof(encoded), ops, memory) == FLINT_SEC_ARGUMENT);
    assert(sodium_is_zero((const uint8_t *)encoded, sizeof(encoded)));
    memset(encoded, 0x7a, sizeof(encoded));
    assert(flint_password_hash(password, sizeof(password), encoded, sizeof(encoded), UINT64_MAX, memory)
           == FLINT_SEC_EXHAUSTED);
    assert(sodium_is_zero((const uint8_t *)encoded, sizeof(encoded)));
    sodium_memzero(password, sizeof(password));
}

static void queue_bound(void)
{
    /* Fixed, low-cost shape. Results stay outstanding to exercise admission, even after completion. */
    static const char encoded[] = "$argon2id$v=19$m=8,t=1,p=1$AAAAAAAAAAAAAAAAAAAAAA$"
                                  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    uint64_t tickets[32];
    const long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    const unsigned bound = cpus <= 0 ? 4u : cpus >= 8 ? 32u : (unsigned)cpus * 4u;
    for (unsigned i = 0; i < bound; ++i)
        assert(flint_password_submit(1, NULL, 0, encoded, sizeof(encoded) - 1, &tickets[i]) == FLINT_SEC_OK);
    uint64_t rejected = UINT64_MAX;
    assert(flint_password_submit(1, NULL, 0, encoded, sizeof(encoded) - 1, &rejected) == FLINT_SEC_EXHAUSTED);
    assert(rejected == 0);
    assert(flint_password_submit(1, NULL, 1025, encoded, sizeof(encoded) - 1, &rejected) == FLINT_SEC_ARGUMENT);
    assert(rejected == 0);
    for (unsigned i = 0; i < bound; ++i)
        assert(flint_password_abandon(tickets[i]) == FLINT_SEC_OK);
}

int main(void)
{
    assert(flint_crypto_initialize() == FLINT_SEC_OK);
    assert(flint_sodium_initialize() == FLINT_SEC_OK);
    signatures("FLINT_SECURITY_RSA", 0);
    signatures("FLINT_SECURITY_EC", 1);
    signatures("FLINT_SECURITY_ED", 2);
    digests();
    worker_retirement();
    queue_bound();
    puts("security native corpus passed: provider signatures, boundary lengths, wiping, retirement and generation reuse");
}
