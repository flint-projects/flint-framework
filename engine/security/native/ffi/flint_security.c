#define _POSIX_C_SOURCE 200809L
#include "flint_security.h"

#if (defined(__linux__) || defined(__APPLE__) || defined(_WIN32)) \
    && (defined(FLINT_HAS_OPENSSL) || defined(FLINT_HAS_LIBSODIUM))
#include <limits.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#if defined(_WIN32)
#include "flint_port.h" /* pthread and sysconf on Win32 (ADR-026) */
#else
#include <pthread.h>
#include <unistd.h>
#endif
#endif

#if (defined(__linux__) || defined(__APPLE__) || defined(_WIN32)) && defined(FLINT_HAS_OPENSSL)

#include <openssl/bn.h>
#include <openssl/core_names.h>
#include <openssl/crypto.h>
#include <openssl/ec.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/param_build.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>

enum { RS256, ES256, EDDSA, MAX_RSA_BITS = 4096, MAX_DER = 4096 };

struct flint_jwk {
    EVP_PKEY *key;
    unsigned algorithm;
    _Atomic unsigned references;
};

static const uint8_t empty = 0;

int flint_crypto_initialize(void)
{
    const int ready = OPENSSL_init_crypto(OPENSSL_INIT_LOAD_CRYPTO_STRINGS, NULL);
    ERR_clear_error();
    return ready == 1 ? FLINT_SEC_OK : FLINT_SEC_UNAVAILABLE;
}

void flint_crypto_wipe(void *bytes, size_t length)
{
    if (bytes && length)
        OPENSSL_cleanse(bytes, length);
}

int flint_sha256(const uint8_t *input, size_t length, uint8_t output[32])
{
    ERR_clear_error();
    if (!output || (!input && length)) {
        flint_crypto_wipe(output, 32);
        return FLINT_SEC_ARGUMENT;
    }
    unsigned written = 0;
    const bool done = EVP_Digest(input ? input : &empty, length, output, &written, EVP_sha256(), NULL) == 1
                      && written == 32;
    ERR_clear_error();
    if (!done)
        flint_crypto_wipe(output, 32);
    return done ? FLINT_SEC_OK : FLINT_SEC_IO;
}

int flint_hmac_sha256(const uint8_t *key, size_t key_length,
                      const uint8_t *input, size_t length, uint8_t output[32])
{
    ERR_clear_error();
    if (!output || (!input && length) || (!key && key_length)) {
        flint_crypto_wipe(output, 32);
        return FLINT_SEC_ARGUMENT;
    }
    size_t written = 0;
    const bool done = EVP_Q_mac(NULL, "HMAC", NULL, "SHA256", NULL, key ? key : &empty, key_length,
                                input ? input : &empty, length, output, 32, &written) && written == 32;
    ERR_clear_error();
    if (!done)
        flint_crypto_wipe(output, 32);
    return done ? FLINT_SEC_OK : FLINT_SEC_IO;
}

static bool rsa_bounds(EVP_PKEY *key)
{
    if (!EVP_PKEY_is_a(key, "RSA"))
        return false;
    const int bits = EVP_PKEY_get_bits(key);
    BIGNUM *exponent = NULL;
    const bool result = bits >= 2048 && bits <= MAX_RSA_BITS
        && EVP_PKEY_get_bn_param(key, OSSL_PKEY_PARAM_RSA_E, &exponent) == 1
        && BN_is_odd(exponent) && !BN_is_one(exponent) && BN_num_bits(exponent) <= 32;
    BN_free(exponent);
    return result;
}

static bool matching_key(EVP_PKEY *key, unsigned algorithm)
{
    if (!key)
        return false;
    if (algorithm == RS256)
        return rsa_bounds(key);
    if (algorithm == EDDSA)
        return EVP_PKEY_is_a(key, "ED25519");

    char name[32];
    return algorithm == ES256 && EVP_PKEY_is_a(key, "EC")
        && EVP_PKEY_get_group_name(key, name, sizeof(name), NULL) == 1
        && (strcmp(name, "prime256v1") == 0 || strcmp(name, "P-256") == 0 || strcmp(name, "secp256r1") == 0);
}

static int encode_ecdsa(const uint8_t *raw, uint8_t der[80])
{
    int length = -1;
    ECDSA_SIG *signature = ECDSA_SIG_new();
    BIGNUM *r = BN_bin2bn(raw, 32, NULL);
    BIGNUM *s = BN_bin2bn(raw + 32, 32, NULL);
    if (signature && r && s && ECDSA_SIG_set0(signature, r, s) == 1) {
        r = NULL;
        s = NULL;
        const int needed = i2d_ECDSA_SIG(signature, NULL);
        if (needed > 0 && needed <= 80) {
            uint8_t *output = der;
            length = i2d_ECDSA_SIG(signature, &output);
        }
    }
    BN_clear_free(r);
    BN_clear_free(s);
    ECDSA_SIG_free(signature);
    return length;
}

static int verify_signature(EVP_PKEY *key, unsigned algorithm, const uint8_t *input, size_t input_length,
                            const uint8_t *signature, size_t signature_length)
{
    if ((!input && input_length) || !signature || !signature_length)
        return FLINT_SEC_ARGUMENT;
    if (signature_length != (algorithm == RS256 ? (size_t)EVP_PKEY_get_size(key) : 64u))
        return FLINT_SEC_DENIED;

    uint8_t der[80];
    int status = FLINT_SEC_DENIED;
    if (algorithm == ES256) {
        const int length = encode_ecdsa(signature, der);
        if (length <= 0) {
            OPENSSL_cleanse(der, sizeof(der));
            return FLINT_SEC_DENIED;
        }
        signature = der;
        signature_length = (size_t)length;
    }

    EVP_MD_CTX *digest = EVP_MD_CTX_new();
    EVP_PKEY_CTX *keys = NULL;
    if (!digest) {
        status = FLINT_SEC_MEMORY;
    } else if (EVP_DigestVerifyInit(digest, &keys, algorithm == EDDSA ? NULL : EVP_sha256(), NULL, key) == 1
               && (algorithm != RS256 || EVP_PKEY_CTX_set_rsa_padding(keys, RSA_PKCS1_PADDING) > 0)) {
        const int verified = EVP_DigestVerify(digest, signature, signature_length,
                                              input ? input : &empty, input_length);
        status = verified == 1 ? FLINT_SEC_OK : FLINT_SEC_DENIED;
    }
    EVP_MD_CTX_free(digest);
    OPENSSL_cleanse(der, sizeof(der));
    return status;
}

int flint_jws_verify(int algorithm, const uint8_t *der, size_t der_length,
                     const uint8_t *input, size_t input_length, const uint8_t *signature, size_t signature_length)
{
    ERR_clear_error();
    if (algorithm < RS256 || algorithm > EDDSA || !der || !der_length || der_length > MAX_DER)
        return FLINT_SEC_ARGUMENT;
    const uint8_t *cursor = der;
    EVP_PKEY *key = d2i_PUBKEY(NULL, &cursor, (long)der_length);
    const int status = cursor == der + der_length && matching_key(key, (unsigned)algorithm)
        ? verify_signature(key, (unsigned)algorithm, input, input_length, signature, signature_length) : FLINT_SEC_DENIED;
    EVP_PKEY_free(key);
    ERR_clear_error();
    return status;
}

static EVP_PKEY *load_public(const char *kind, OSSL_PARAM *params)
{
    EVP_PKEY *key = NULL;
    EVP_PKEY_CTX *context = EVP_PKEY_CTX_new_from_name(NULL, kind, NULL);
    if (context && EVP_PKEY_fromdata_init(context) > 0)
        if (EVP_PKEY_fromdata(context, &key, EVP_PKEY_PUBLIC_KEY, params) <= 0) {
            EVP_PKEY_free(key);
            key = NULL;
        }
    EVP_PKEY_CTX_free(context);
    return key;
}

static EVP_PKEY *load_rsa(const uint8_t *first, size_t first_length, const uint8_t *second, size_t second_length)
{
    if (first_length < 256 || first_length > MAX_RSA_BITS / 8 || second_length == 0 || second_length > 4
        || first[0] == 0 || second[0] == 0)
        return NULL;
    BIGNUM *modulus = BN_bin2bn(first, (int)first_length, NULL);
    BIGNUM *exponent = BN_bin2bn(second, (int)second_length, NULL);
    OSSL_PARAM_BLD *builder = OSSL_PARAM_BLD_new();
    OSSL_PARAM *parameters = NULL;
    EVP_PKEY *key = NULL;
    if (modulus && exponent && builder && OSSL_PARAM_BLD_push_BN(builder, OSSL_PKEY_PARAM_RSA_N, modulus)
           && OSSL_PARAM_BLD_push_BN(builder, OSSL_PKEY_PARAM_RSA_E, exponent)) {
        parameters = OSSL_PARAM_BLD_to_param(builder);
        if (parameters)
            key = load_public("RSA", parameters);
    }
    OSSL_PARAM_free(parameters);
    OSSL_PARAM_BLD_free(builder);
    BN_free(modulus);
    BN_free(exponent);
    return key;
}

static EVP_PKEY *load_ec(const uint8_t *x, const uint8_t *y)
{
    uint8_t point[65] = {4};
    memcpy(point + 1, x, 32);
    memcpy(point + 33, y, 32);
    char group[] = "prime256v1";
    OSSL_PARAM parameters[] = {
        OSSL_PARAM_construct_utf8_string(OSSL_PKEY_PARAM_GROUP_NAME, group, 0),
        OSSL_PARAM_construct_octet_string(OSSL_PKEY_PARAM_PUB_KEY, point, sizeof(point)),
        OSSL_PARAM_construct_end()
    };
    return load_public("EC", parameters);
}

static bool valid_public(EVP_PKEY *key, unsigned algorithm)
{
    if (!matching_key(key, algorithm))
        return false;
    EVP_PKEY_CTX *context = EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL);
    const bool valid = context && EVP_PKEY_public_check(context) == 1;
    EVP_PKEY_CTX_free(context);
    return valid;
}

int flint_jwk_create(unsigned algorithm, const uint8_t *first, size_t first_length,
                      const uint8_t *second, size_t second_length, flint_jwk **output)
{
    ERR_clear_error();
    if (!output)
        return FLINT_SEC_ARGUMENT;
    *output = NULL;
    if (algorithm > EDDSA || !first || !first_length || (second_length && !second))
        return FLINT_SEC_ARGUMENT;
    EVP_PKEY *key = NULL;
    if (algorithm == RS256)
        key = load_rsa(first, first_length, second, second_length);
    else if (algorithm == ES256 && first_length == 32 && second_length == 32)
        key = load_ec(first, second);
    else if (algorithm == EDDSA && first_length == 32 && !second_length)
        key = EVP_PKEY_new_raw_public_key_ex(NULL, "ED25519", NULL, first, first_length);
    const bool valid = valid_public(key, algorithm);
    ERR_clear_error();
    if (!valid) {
        EVP_PKEY_free(key);
        return FLINT_SEC_DENIED;
    }
    flint_jwk *owned = malloc(sizeof(*owned));
    if (!owned) {
        EVP_PKEY_free(key);
        return FLINT_SEC_MEMORY;
    }
    owned->key = key;
    owned->algorithm = algorithm;
    atomic_init(&owned->references, 1);
    *output = owned;
    return FLINT_SEC_OK;
}

int flint_jwk_retain(flint_jwk *key)
{
    if (!key)
        return FLINT_SEC_ARGUMENT;
    unsigned previous = atomic_load_explicit(&key->references, memory_order_relaxed);
    do {
        if (!previous || previous == UINT_MAX)
            return FLINT_SEC_EXHAUSTED;
    } while (!atomic_compare_exchange_weak_explicit(&key->references, &previous, previous + 1,
                                                    memory_order_relaxed, memory_order_relaxed));
    return FLINT_SEC_OK;
}

void flint_jwk_release(flint_jwk *key)
{
    if (key && atomic_fetch_sub_explicit(&key->references, 1, memory_order_acq_rel) == 1) {
        EVP_PKEY_free(key->key);
        free(key);
    }
}

int flint_jwk_verify(const flint_jwk *key, unsigned algorithm, const uint8_t *input, size_t input_length,
                      const uint8_t *signature, size_t signature_length)
{
    ERR_clear_error();
    if (!key || key->algorithm != algorithm)
        return FLINT_SEC_DENIED;
    const int status = verify_signature(key->key, algorithm, input, input_length, signature, signature_length);
    ERR_clear_error();
    return status;
}

enum { MAX_ISSUERS = 128, MAX_ISSUER_LENGTH = 1024 };
static const int64_t refresh_interval = INT64_C(30000000000);

typedef struct issuer_rate {
    uint8_t issuer[MAX_ISSUER_LENGTH];
    size_t length;
    unsigned references;
    bool busy;
    int64_t next;
} issuer_rate;

static pthread_mutex_t issuer_lock = PTHREAD_MUTEX_INITIALIZER;
static issuer_rate issuers[MAX_ISSUERS];

int flint_jwks_rate_register(const uint8_t *issuer, size_t length, int64_t now_ns, unsigned *index)
{
    if (!index)
        return FLINT_SEC_ARGUMENT;
    *index = 0;
    if (!issuer || !length || length > MAX_ISSUER_LENGTH || now_ns < 0)
        return FLINT_SEC_ARGUMENT;
    pthread_mutex_lock(&issuer_lock);
    unsigned vacant = MAX_ISSUERS;
    int status = FLINT_SEC_EXHAUSTED;
    for (unsigned i = 0; i < MAX_ISSUERS; ++i) {
        issuer_rate *entry = &issuers[i];
        if (entry->length == length && memcmp(entry->issuer, issuer, length) == 0) {
            if (entry->references != UINT_MAX) {
                ++entry->references;
                *index = i + 1;
                status = FLINT_SEC_OK;
            }
            vacant = MAX_ISSUERS;
            break;
        }
        if (vacant == MAX_ISSUERS && !entry->references && !entry->busy && entry->next <= now_ns)
            vacant = i;
    }
    if (vacant < MAX_ISSUERS) {
        issuer_rate *entry = &issuers[vacant];
        memcpy(entry->issuer, issuer, length);
        entry->length = length;
        entry->references = 1;
        entry->next = 0;
        *index = vacant + 1;
        status = FLINT_SEC_OK;
    }
    pthread_mutex_unlock(&issuer_lock);
    return status;
}

int flint_jwks_rate_begin(unsigned index, int64_t now_ns)
{
    if (!index || index > MAX_ISSUERS || now_ns < 0)
        return FLINT_SEC_ARGUMENT;
    pthread_mutex_lock(&issuer_lock);
    issuer_rate *entry = &issuers[index - 1];
    int status = FLINT_SEC_UNAVAILABLE;
    if (entry->references && !entry->busy && now_ns >= entry->next) {
        entry->busy = true;
        entry->next = now_ns < INT64_MAX - refresh_interval ? now_ns + refresh_interval : INT64_MAX;
        status = FLINT_SEC_OK;
    }
    pthread_mutex_unlock(&issuer_lock);
    return status;
}

void flint_jwks_rate_end(unsigned index)
{
    if (index && index <= MAX_ISSUERS) {
        pthread_mutex_lock(&issuer_lock);
        issuers[index - 1].busy = false;
        pthread_mutex_unlock(&issuer_lock);
    }
}

void flint_jwks_rate_release(unsigned index)
{
    if (index && index <= MAX_ISSUERS) {
        pthread_mutex_lock(&issuer_lock);
        if (issuers[index - 1].references)
            --issuers[index - 1].references;
        pthread_mutex_unlock(&issuer_lock);
    }
}

#endif

#if (defined(__linux__) || defined(__APPLE__) || defined(_WIN32)) && defined(FLINT_HAS_LIBSODIUM)

#include <sodium.h>

enum { PASSWORD_LIMIT = 1024, MAX_PASSWORD_THREADS = 16, MAX_PASSWORD_TICKETS = 32,
       PASSWORD_TICKET_BITS = 5 };

static pthread_once_t sodium_once = PTHREAD_ONCE_INIT;
static int sodium_ready = FLINT_SEC_UNAVAILABLE;
static const uint8_t sodium_empty = 0;

static void ready_sodium(void)
{
    sodium_ready = sodium_init() >= 0 ? FLINT_SEC_OK : FLINT_SEC_UNAVAILABLE;
}

int flint_sodium_initialize(void)
{
    return pthread_once(&sodium_once, ready_sodium) == 0 ? sodium_ready : FLINT_SEC_UNAVAILABLE;
}

void flint_sodium_wipe(void *bytes, size_t length)
{
    if (bytes && length)
        sodium_memzero(bytes, length);
}

int flint_password_hash(const uint8_t *password, size_t length, char *output, size_t capacity,
                         uint64_t opslimit, size_t memlimit)
{
    if (!output || capacity < crypto_pwhash_STRBYTES)
        return FLINT_SEC_ARGUMENT;
    if ((length && !password) || length > PASSWORD_LIMIT) {
        flint_sodium_wipe(output, crypto_pwhash_STRBYTES);
        return FLINT_SEC_ARGUMENT;
    }
    if (opslimit != crypto_pwhash_OPSLIMIT_INTERACTIVE || memlimit != crypto_pwhash_MEMLIMIT_INTERACTIVE) {
        flint_sodium_wipe(output, crypto_pwhash_STRBYTES);
        return FLINT_SEC_EXHAUSTED;
    }
    const int initialized = flint_sodium_initialize();
    if (initialized) {
        flint_sodium_wipe(output, crypto_pwhash_STRBYTES);
        return initialized;
    }
    if (crypto_pwhash_str_alg(output, (const char *)(password ? password : &sodium_empty), length,
                              opslimit, memlimit, crypto_pwhash_ALG_ARGON2ID13) != 0) {
        flint_sodium_wipe(output, crypto_pwhash_STRBYTES);
        return FLINT_SEC_MEMORY;
    }
    return FLINT_SEC_OK;
}

static bool consume(const char **cursor, const char *end, const char *literal)
{
    const size_t length = strlen(literal);
    if ((size_t)(end - *cursor) < length || memcmp(*cursor, literal, length) != 0)
        return false;
    *cursor += length;
    return true;
}

static bool decimal(const char **cursor, const char *end, uint64_t *result)
{
    const char *start = *cursor;
    uint64_t number = 0;
    while (*cursor < end && **cursor >= '0' && **cursor <= '9') {
        const unsigned next = (unsigned)(**cursor - '0');
        if (number > (UINT64_MAX - next) / 10)
            return false;
        number = number * 10 + next;
        ++*cursor;
    }
    if (*cursor == start || (*cursor - start > 1 && *start == '0'))
        return false;
    *result = number;
    return true;
}

static int base64_digit(char item)
{
    if (item >= 'A' && item <= 'Z')
        return item - 'A';
    if (item >= 'a' && item <= 'z')
        return item - 'a' + 26;
    if (item >= '0' && item <= '9')
        return item - '0' + 52;
    return item == '+' ? 62 : item == '/' ? 63 : -1;
}

static bool encoded_part(const char **cursor, const char *end, size_t length, unsigned tail_mask)
{
    if (length > (size_t)(end - *cursor))
        return false;
    for (size_t i = 0; i < length; ++i)
        if (base64_digit((*cursor)[i]) < 0)
            return false;
    const unsigned tail = (unsigned)base64_digit((*cursor)[length - 1]);
    *cursor += length;
    return !(tail & tail_mask);
}

static int verifier_shape(const char *encoded, size_t length)
{
    if (!encoded || length >= crypto_pwhash_STRBYTES || memchr(encoded, 0, length))
        return FLINT_SEC_ARGUMENT;
    const char *cursor = encoded;
    const char *end = encoded + length;
    uint64_t memory, iterations;
    if (!consume(&cursor, end, "$argon2id$v=19$m=") || !decimal(&cursor, end, &memory)
        || !consume(&cursor, end, ",t=") || !decimal(&cursor, end, &iterations)
        || !consume(&cursor, end, ",p=1$") || !encoded_part(&cursor, end, 22, 15)
        || !consume(&cursor, end, "$") || !encoded_part(&cursor, end, 43, 3) || cursor != end
        || memory < 8 || iterations == 0)
        return FLINT_SEC_ARGUMENT;
    if (memory > crypto_pwhash_MEMLIMIT_INTERACTIVE / 1024 || iterations > crypto_pwhash_OPSLIMIT_INTERACTIVE)
        return FLINT_SEC_EXHAUSTED;
    return FLINT_SEC_OK;
}

int flint_password_verify(const char *encoded, const uint8_t *password, size_t length)
{
    if (!encoded || (length && !password) || length > PASSWORD_LIMIT)
        return FLINT_SEC_ARGUMENT;
    const int checked = verifier_shape(encoded, strnlen(encoded, crypto_pwhash_STRBYTES));
    if (checked)
        return checked;
    const int initialized = flint_sodium_initialize();
    if (initialized)
        return initialized;
    if (crypto_pwhash_str_needs_rehash(encoded, crypto_pwhash_OPSLIMIT_INTERACTIVE,
                                       crypto_pwhash_MEMLIMIT_INTERACTIVE) < 0)
        return FLINT_SEC_ARGUMENT;
    return crypto_pwhash_str_verify(encoded, (const char *)(password ? password : &sodium_empty), length) == 0
        ? FLINT_SEC_OK : FLINT_SEC_DENIED;
}

enum password_phase { PASSWORD_FREE, PASSWORD_QUEUED, PASSWORD_RUNNING, PASSWORD_READY };

typedef struct password_task {
    uint64_t ticket;
    enum password_phase phase;
    bool checking, abandoned;
    size_t input_length, output_length;
    int status;
    uint8_t input[PASSWORD_LIMIT];
    char verifier[crypto_pwhash_STRBYTES];
    char output[crypto_pwhash_STRBYTES];
} password_task;

static struct {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    pthread_t workers[MAX_PASSWORD_THREADS];
    unsigned count, capacity, queued, head, live;
    unsigned fifo[MAX_PASSWORD_TICKETS];
    uint64_t generation;
    bool stopping;
    int initialized;
    password_task tasks[MAX_PASSWORD_TICKETS];
} pool = {.lock = PTHREAD_MUTEX_INITIALIZER, .changed = PTHREAD_COND_INITIALIZER,
          .initialized = FLINT_SEC_UNAVAILABLE};

static pthread_once_t workers_once = PTHREAD_ONCE_INIT;

static void wipe_input(password_task *task)
{
    sodium_memzero(task->input, sizeof(task->input));
    sodium_memzero(task->verifier, sizeof(task->verifier));
}

static void free_password_task(password_task *task)
{
    sodium_memzero(task, sizeof(*task));
    --pool.live;
}

static void compute_password(password_task *task)
{
    if (!task->checking) {
        task->status = flint_password_hash(task->input, task->input_length, task->output, sizeof(task->output),
                                           crypto_pwhash_OPSLIMIT_INTERACTIVE, crypto_pwhash_MEMLIMIT_INTERACTIVE);
        if (!task->status)
            task->output_length = strlen(task->output);
        return;
    }
    const int status = flint_password_verify(task->verifier, task->input, task->input_length);
    if (status == FLINT_SEC_OK || status == FLINT_SEC_DENIED) {
        task->output[0] = status == FLINT_SEC_OK;
        task->output_length = 1;
        task->status = FLINT_SEC_OK;
    } else {
        task->status = status;
    }
}

static password_task *dequeue_password(void)
{
    while (pool.queued) {
        password_task *task = &pool.tasks[pool.fifo[pool.head]];
        pool.head = (pool.head + 1) % pool.capacity;
        --pool.queued;
        if (task->abandoned) {
            free_password_task(task);
        } else {
            task->phase = PASSWORD_RUNNING;
            return task;
        }
    }
    return NULL;
}

static void *password_worker(void *unused)
{
    (void)unused;
    pthread_mutex_lock(&pool.lock);
    while (!pool.stopping) {
        password_task *task = dequeue_password();
        if (!task) {
            pthread_cond_wait(&pool.changed, &pool.lock);
            continue;
        }

        pthread_mutex_unlock(&pool.lock);
        compute_password(task);
        wipe_input(task);
        pthread_mutex_lock(&pool.lock);
        if (task->abandoned || pool.stopping)
            free_password_task(task);
        else
            task->phase = PASSWORD_READY;
    }
    pthread_mutex_unlock(&pool.lock);
    return NULL;
}

static void stop_workers(void)
{
    pthread_mutex_lock(&pool.lock);
    pool.stopping = true;
    pthread_cond_broadcast(&pool.changed);
    pthread_mutex_unlock(&pool.lock);
    for (unsigned i = 0; i < pool.count; ++i)
        pthread_join(pool.workers[i], NULL);
    pthread_mutex_lock(&pool.lock);
    for (unsigned i = 0; i < pool.capacity; ++i)
        if (pool.tasks[i].phase != PASSWORD_FREE)
            free_password_task(&pool.tasks[i]);
    pthread_mutex_unlock(&pool.lock);
}

static void launch_workers(void)
{
    const int initialized = flint_sodium_initialize();
    if (initialized) {
        pool.initialized = initialized;
        return;
    }

    const long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    const unsigned requested = cpus <= 0 ? 2 : cpus >= 8 ? MAX_PASSWORD_THREADS : (unsigned)cpus * 2;
    pool.capacity = requested * 2;
    pthread_attr_t attributes;
    if (pthread_attr_init(&attributes) != 0)
        return;
    if (pthread_attr_setstacksize(&attributes, 512 * 1024) == 0) {
        for (unsigned i = 0; i < requested; ++i) {
            if (pthread_create(&pool.workers[pool.count], &attributes, password_worker, NULL) != 0)
                break;
            ++pool.count;
        }
    }
    pthread_attr_destroy(&attributes);
    if (pool.count == requested && atexit(stop_workers) == 0)
        pool.initialized = FLINT_SEC_OK;
    else
        stop_workers();
}

int flint_password_workers(void)
{
    return pthread_once(&workers_once, launch_workers) == 0 ? pool.initialized : FLINT_SEC_UNAVAILABLE;
}

int flint_password_submit(unsigned verify, const uint8_t *password, size_t length,
                           const char *encoded, size_t encoded_length, uint64_t *ticket)
{
    if (!ticket)
        return FLINT_SEC_ARGUMENT;
    *ticket = 0;
    if (verify > 1 || (length && !password) || length > PASSWORD_LIMIT)
        return FLINT_SEC_ARGUMENT;
    if (verify) {
        const int shape = verifier_shape(encoded, encoded_length);
        if (shape)
            return shape;
    }
    const int initialized = flint_password_workers();
    if (initialized)
        return initialized;

    pthread_mutex_lock(&pool.lock);
    int status = FLINT_SEC_EXHAUSTED;
    if (!pool.stopping && pool.live < pool.capacity && pool.generation < (UINT64_MAX >> PASSWORD_TICKET_BITS)) {
        unsigned index = 0;
        while (pool.tasks[index].phase != PASSWORD_FREE)
            ++index;
        password_task *task = &pool.tasks[index];
        task->ticket = (++pool.generation << PASSWORD_TICKET_BITS) | index;
        task->phase = PASSWORD_QUEUED;
        task->checking = verify != 0;
        task->input_length = length;
        if (length)
            memcpy(task->input, password, length);
        if (verify) {
            memcpy(task->verifier, encoded, encoded_length);
            task->verifier[encoded_length] = 0;
        }
        pool.fifo[(pool.head + pool.queued) % pool.capacity] = index;
        ++pool.queued;
        ++pool.live;
        *ticket = task->ticket;
        status = FLINT_SEC_OK;
        pthread_cond_signal(&pool.changed);
    }
    pthread_mutex_unlock(&pool.lock);
    return status;
}

static password_task *password_lookup(uint64_t ticket)
{
    const unsigned index = ticket & (MAX_PASSWORD_TICKETS - 1);
    password_task *task = &pool.tasks[index];
    return ticket && index < pool.capacity && task->ticket == ticket && !task->abandoned ? task : NULL;
}

int flint_password_take(uint64_t ticket, uint8_t *output, size_t capacity, size_t *length)
{
    if (!length || (!output && capacity))
        return FLINT_SEC_ARGUMENT;
    *length = 0;
    pthread_mutex_lock(&pool.lock);
    password_task *task = password_lookup(ticket);
    int status = FLINT_SEC_NOT_FOUND;
    if (task) {
        if (task->phase != PASSWORD_READY) {
            status = FLINT_SEC_WAITING;
        } else if (!task->status && task->output_length > capacity) {
            status = FLINT_SEC_EXHAUSTED;
        } else {
            status = task->status;
            if (!status) {
                if (task->output_length)
                    memcpy(output, task->output, task->output_length);
                *length = task->output_length;
            }
            free_password_task(task);
        }
    }
    pthread_mutex_unlock(&pool.lock);
    return status;
}

int flint_password_abandon(uint64_t ticket)
{
    pthread_mutex_lock(&pool.lock);
    password_task *task = password_lookup(ticket);
    const int status = task ? FLINT_SEC_OK : FLINT_SEC_NOT_FOUND;
    if (task) {
        if (task->phase == PASSWORD_READY) {
            free_password_task(task);
        } else {
            task->abandoned = true;
            if (task->phase == PASSWORD_QUEUED)
                wipe_input(task);
        }
    }
    pthread_mutex_unlock(&pool.lock);
    return status;
}

#ifdef FLINT_SECURITY_TEST
/* Test-only observation of erasure. No native secret or verifier crosses the boundary. */
int flint_security_test_erased(uint64_t ticket)
{
    const unsigned index = ticket & (MAX_PASSWORD_TICKETS - 1);
    pthread_mutex_lock(&pool.lock);
    const password_task *task = &pool.tasks[index];
    const int erased = task->phase == PASSWORD_FREE
        && sodium_is_zero((const unsigned char *)task, sizeof(*task));
    pthread_mutex_unlock(&pool.lock);
    return erased;
}
#endif

#endif
