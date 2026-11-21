#define _POSIX_C_SOURCE 200809L
#include "flint_http.h"

#if defined(FLINT_HAS_CURL) && defined(__linux__)

#include <curl/curl.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

enum {
    MAX_URL = 16384,
    MAX_CONNECTIONS = 128,
    MAX_HEADERS = 256,
    MAX_REQUEST_HEADER_BYTES = 65536,
    MAX_REDIRECTS = 5
};

typedef struct bytes {
    uint8_t *data;
    size_t length;
    size_t capacity;
} bytes;

typedef struct request {
    CURL *easy;
    uint32_t generation, state, method, status, version;
    int error;
    bool streaming, paused, redirected_origin, dropped_upload, location;
    unsigned redirects;
    size_t decoded;
    size_t received_header_bytes;
    char *url;
    char *redirect;
    struct curl_slist *headers;
    struct curl_slist *sent_headers;
    size_t request_headers_bytes;
    unsigned header_count;
    uint8_t *upload;
    size_t upload_length;
    bytes response_headers;
    bytes body;
    uint8_t chunk[CURL_MAX_WRITE_SIZE];
    size_t chunk_length;
    flint_curl_data_cb legacy;
    void *legacy_user;
    struct flint_curl_loop *loop;
} request;

struct flint_curl_loop {
    CURLM *multi;
    request *requests;
    size_t request_count;
    flint_http_watch *watches;
    struct pollfd *poll_fds;
    uint64_t *poll_generations;
    size_t watch_capacity;
    uint64_t watch_generation;
    uint64_t watch_revision;
    uint64_t timer;
    atomic_uint_fast64_t owner;
    int fault;
    int prepared_status;
    uint32_t connections;
    uint32_t per_origin;
    bool prepared;
    bool in_action, timer_pending, redirects;
    size_t max_response, max_headers;
    long connect_ms;
    char *ca_path;
};

static pthread_once_t initializes = PTHREAD_ONCE_INIT;
static int initialization = FLINT_HTTP_IO;
static atomic_uint_fast64_t next_thread;
static _Thread_local uint64_t thread_identity;

#ifdef FLINT_HTTP_TEST_OWNER
#include <assert.h>
static atomic_ulong calls_on_owner;

static void observe_owner(const flint_curl_loop *loop)
{
    assert(thread_identity && atomic_load_explicit(&loop->owner, memory_order_relaxed) == thread_identity);
    atomic_fetch_add_explicit(&calls_on_owner, 1, memory_order_relaxed);
}

unsigned long flint_http_owner_calls(void)
{
    return atomic_load_explicit(&calls_on_owner, memory_order_relaxed);
}

#define CURL_ON_OWNER(loop, call) (observe_owner(loop), (call))
#else
#define CURL_ON_OWNER(loop, call) (call)
#endif

static void initialize_once(void)
{
    if (curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK) {
        const curl_version_info_data *features = curl_version_info(CURLVERSION_NOW);
        if (features && (features->features & CURL_VERSION_ASYNCHDNS)
            && (features->features & CURL_VERSION_HTTP2) && (features->features & CURL_VERSION_SSL)) {
            initialization = FLINT_HTTP_OK;
            if (atexit(curl_global_cleanup) == 0)
                return;
            initialization = FLINT_HTTP_IO;
        } else {
            initialization = FLINT_HTTP_UNSUPPORTED;
        }
        curl_global_cleanup();
    }
}

int flint_http_initialize(void)
{
    return pthread_once(&initializes, initialize_once) == 0 ? initialization : FLINT_HTTP_IO;
}

static int owner_identity_status(flint_curl_loop *loop)
{
    if (!loop)
        return FLINT_HTTP_ARGUMENT;
    if (!thread_identity)
        thread_identity = atomic_fetch_add_explicit(&next_thread, 1, memory_order_relaxed) + 1;
    uint_fast64_t prior = 0;
    if (!atomic_compare_exchange_strong(&loop->owner, &prior, thread_identity)
        && prior != thread_identity)
        return FLINT_HTTP_CONFLICT;
    return loop->in_action ? FLINT_HTTP_CONFLICT : FLINT_HTTP_OK;
}

static int prepare_handles(flint_curl_loop *loop);

static int owner_status(flint_curl_loop *loop)
{
    const int owner = owner_identity_status(loop);
    if (owner)
        return owner;
    if (!loop->prepared) {
        loop->prepared = true;
        loop->prepared_status = prepare_handles(loop);
    }
    return loop->prepared_status;
}

int flint_http_owner(flint_curl_loop *loop)
{
    return owner_status(loop);
}

static int map_curl(CURLcode code)
{
    switch (code) {
    case CURLE_OK: return FLINT_HTTP_OK;
    case CURLE_OPERATION_TIMEDOUT: return FLINT_HTTP_TIMEOUT;
    case CURLE_OUT_OF_MEMORY: return FLINT_HTTP_MEMORY;
    case CURLE_COULDNT_RESOLVE_HOST:
    case CURLE_COULDNT_CONNECT: return FLINT_HTTP_UNAVAILABLE;
    case CURLE_PEER_FAILED_VERIFICATION:
    case CURLE_SSL_CACERT_BADFILE:
    case CURLE_SSL_CERTPROBLEM:
    case CURLE_SSL_PINNEDPUBKEYNOTMATCH:
    case CURLE_LOGIN_DENIED: return FLINT_HTTP_DENIED;
    case CURLE_UNSUPPORTED_PROTOCOL: return FLINT_HTTP_UNSUPPORTED;
    case CURLE_URL_MALFORMAT: return FLINT_HTTP_ARGUMENT;
    default: return FLINT_HTTP_IO;
    }
}

static uint64_t clock_ms(void)
{
    struct timespec now;
    return clock_gettime(CLOCK_MONOTONIC, &now) == 0
        ? (uint64_t) now.tv_sec * 1000 + (uint64_t) now.tv_nsec / 1000000 : 0;
}

static int on_timer(CURLM *multi, long delay, void *user)
{
    (void)multi;
    flint_curl_loop *loop = user;
    loop->timer_pending = delay >= 0;
    if (loop->timer_pending) {
        const uint64_t now = clock_ms();
        loop->timer = (uint64_t) delay > UINT64_MAX - now ? UINT64_MAX : now + (uint64_t) delay;
    }
    return 0;
}

static flint_http_watch *lookup_watch(flint_curl_loop *loop, intptr_t fd)
{
    for (size_t i = 0; i < loop->watch_capacity; ++i)
        if (loop->watches[i].fd == fd && loop->watches[i].generation)
            return &loop->watches[i];
    return NULL;
}

static int on_socket(CURL *easy, curl_socket_t fd, int action, void *user, void *socket_data)
{
    (void)easy;
    (void)socket_data;
    flint_curl_loop *loop = user;
    flint_http_watch *watch = lookup_watch(loop, fd);
    if (action == CURL_POLL_REMOVE || action == CURL_POLL_NONE) {
        if (watch) {
            memset(watch, 0, sizeof(*watch));
            ++loop->watch_revision;
        }
        return 0;
    }

    if (!watch) {
        for (size_t i = 0; i < loop->watch_capacity; ++i) {
            if (!loop->watches[i].generation) {
                watch = &loop->watches[i];
                break;
            }
        }
        if (!watch || loop->watch_generation == UINT64_MAX) {
            loop->fault = FLINT_HTTP_EXHAUSTED;
            return -1;
        }
        watch->fd = fd;
        watch->generation = ++loop->watch_generation;
    }
    if (watch->events != (uint32_t) action) {
        watch->events = (uint32_t) action;
        ++loop->watch_revision;
    }
    return 0;
}

static int append_bytes(bytes *destination, const void *source, size_t length, size_t cap)
{
    if (length > cap - destination->length)
        return FLINT_HTTP_EXHAUSTED;
    const size_t wanted = destination->length + length;
    if (wanted > destination->capacity) {
        size_t size = destination->capacity ? destination->capacity : (cap < 4096 ? cap : 4096);
        while (size < wanted)
            size = size > cap / 2 ? cap : size * 2;
        void *grown = realloc(destination->data, size);
        if (!grown)
            return FLINT_HTTP_MEMORY;
        destination->data = grown;
        destination->capacity = size;
    }
    if (length)
        memcpy(destination->data + destination->length, source, length);
    destination->length = wanted;
    return FLINT_HTTP_OK;
}

static bool redirect_code(uint32_t code)
{
    return code == 301 || code == 302 || code == 303 || code == 307 || code == 308;
}

static uint32_t status_line(const char *data, size_t length)
{
    if (length < 10 || memcmp(data, "HTTP/", 5) != 0)
        return 0;
    const char *space = memchr(data, ' ', length);
    if (!space || (size_t)(space - data) + 4 > length)
        return 0;
    uint32_t status = 0;
    for (unsigned i = 1; i <= 3; ++i) {
        if (space[i] < '0' || space[i] > '9')
            return 0;
        status = status * 10 + (uint32_t)(space[i] - '0');
    }
    return status;
}

static size_t receive_header(char *source, size_t size, size_t count, void *user)
{
    request *record = user;
    if (size && count > SIZE_MAX / size) {
        record->error = FLINT_HTTP_EXHAUSTED;
        return 0;
    }
    const size_t length = size * count;
    if (length > record->loop->max_headers - record->received_header_bytes) {
        record->error = FLINT_HTTP_EXHAUSTED;
        return 0;
    }
    record->received_header_bytes += length;
    const uint32_t status = status_line(source, length);
    if (status) {
        record->status = status;
        record->location = false;
        record->response_headers.length = 0;
    } else if (length > 9 && strncasecmp(source, "Location:", 9) == 0) {
        record->location = true;
    }
    const int result = append_bytes(&record->response_headers, source, length, record->loop->max_headers);
    if (result) {
        record->error = result;
        return 0;
    }
    return length;
}

static size_t receive_body(char *source, size_t size, size_t count, void *user)
{
    request *record = user;
    if (size && count > SIZE_MAX / size) {
        record->error = FLINT_HTTP_EXHAUSTED;
        return 0;
    }
    const size_t length = size * count;
    if (length > record->loop->max_response - record->decoded) {
        record->error = FLINT_HTTP_EXHAUSTED;
        return 0;
    }
    if (!length)
        return 0;
    if (record->loop->redirects && redirect_code(record->status) && record->location) {
        record->decoded += length;
        return length;
    }
    if (record->legacy) {
        if (record->legacy(record->legacy_user, (const uint8_t *) source, length) != 0) {
            record->error = FLINT_HTTP_CANCELLED;
            return 0;
        }
    } else if (record->streaming) {
        if (record->chunk_length) {
            record->paused = true;
            return CURL_WRITEFUNC_PAUSE;
        }
        if (length > sizeof(record->chunk)) {
            record->error = FLINT_HTTP_EXHAUSTED;
            return 0;
        }
        memcpy(record->chunk, source, length);
        record->chunk_length = length;
    } else {
        const int result = append_bytes(&record->body, source, length, record->loop->max_response);
        if (result) {
            record->error = result;
            return 0;
        }
    }
    record->decoded += length;
    return length;
}

static request *lookup(flint_curl_loop *loop, uint64_t ticket)
{
    const uint32_t slot = (uint32_t) ticket;
    const uint32_t generation = (uint32_t) (ticket >> 32);
    if (slot >= loop->request_count || !generation)
        return NULL;
    request *record = &loop->requests[slot];
    return record->state && record->generation == generation ? record : NULL;
}

static void free_request(request *record)
{
    CURL *easy = record->easy;
    const uint32_t generation = record->generation;
    flint_curl_loop *loop = record->loop;
    CURL_ON_OWNER(loop, curl_easy_reset(easy));
    curl_slist_free_all(record->headers);
    curl_slist_free_all(record->sent_headers);
    free(record->url);
    free(record->redirect);
    free(record->upload);
    free(record->response_headers.data);
    free(record->body.data);
    memset(record, 0, sizeof(*record));
    record->easy = easy;
    record->generation = generation;
    record->loop = loop;
}

static void free_loop(flint_curl_loop *loop)
{
    if (!loop)
        return;
    for (size_t i = 0; loop->requests && i < loop->request_count; ++i) {
        request *record = &loop->requests[i];
        if (!record->easy)
            break;
        if (record->state == FLINT_HTTP_RUNNING)
            CURL_ON_OWNER(loop, curl_multi_remove_handle(loop->multi, record->easy));
        free_request(record);
        CURL_ON_OWNER(record->loop, curl_easy_cleanup(record->easy));
    }
    if (loop->multi)
        CURL_ON_OWNER(loop, curl_multi_cleanup(loop->multi));
    free(loop->requests);
    free(loop->watches);
    free(loop->poll_fds);
    free(loop->poll_generations);
    free(loop->ca_path);
    free(loop);
}

static int configure_multi(flint_curl_loop *loop)
{
    loop->multi = CURL_ON_OWNER(loop, curl_multi_init());
    if (!loop->multi)
        return FLINT_HTTP_MEMORY;
    return CURL_ON_OWNER(loop, curl_multi_setopt(loop->multi, CURLMOPT_SOCKETFUNCTION, on_socket)) == CURLM_OK
        && CURL_ON_OWNER(loop, curl_multi_setopt(loop->multi, CURLMOPT_SOCKETDATA, loop)) == CURLM_OK
        && CURL_ON_OWNER(loop, curl_multi_setopt(loop->multi, CURLMOPT_TIMERFUNCTION, on_timer)) == CURLM_OK
        && CURL_ON_OWNER(loop, curl_multi_setopt(loop->multi, CURLMOPT_TIMERDATA, loop)) == CURLM_OK
        && CURL_ON_OWNER(loop, curl_multi_setopt(loop->multi, CURLMOPT_MAX_TOTAL_CONNECTIONS, (long) loop->connections)) == CURLM_OK
        && CURL_ON_OWNER(loop, curl_multi_setopt(loop->multi, CURLMOPT_MAX_HOST_CONNECTIONS, (long) loop->per_origin)) == CURLM_OK
        && CURL_ON_OWNER(loop, curl_multi_setopt(loop->multi, CURLMOPT_MAXCONNECTS, (long) loop->connections)) == CURLM_OK
        && CURL_ON_OWNER(loop, curl_multi_setopt(loop->multi, CURLMOPT_MAX_CONCURRENT_STREAMS, 64L)) == CURLM_OK
        ? FLINT_HTTP_OK : FLINT_HTTP_IO;
}

static int make_storage(flint_curl_loop *loop, uint32_t connections)
{
    loop->request_count = 2U * connections;
    loop->watch_capacity = 6U * connections + 16;
    loop->requests = calloc(loop->request_count, sizeof(*loop->requests));
    loop->watches = calloc(loop->watch_capacity, sizeof(*loop->watches));
    loop->poll_fds = calloc(loop->watch_capacity, sizeof(*loop->poll_fds));
    loop->poll_generations = calloc(loop->watch_capacity, sizeof(*loop->poll_generations));
    if (!loop->requests || !loop->watches || !loop->poll_fds || !loop->poll_generations)
        return FLINT_HTTP_MEMORY;
    return FLINT_HTTP_OK;
}

static int prepare_handles(flint_curl_loop *loop)
{
    const int configured = configure_multi(loop);
    if (configured)
        return configured;
    for (size_t i = 0; i < loop->request_count; ++i) {
        loop->requests[i].loop = loop;
        loop->requests[i].easy = CURL_ON_OWNER(loop, curl_easy_init());
        if (!loop->requests[i].easy)
            return FLINT_HTTP_MEMORY;
    }
    return FLINT_HTTP_OK;
}

static char *copy_string(const char *source, size_t length)
{
    if (length > MAX_URL || (length && (!source || memchr(source, 0, length))))
        return NULL;
    char *copy = malloc(length + 1);
    if (!copy)
        return NULL;
    if (length)
        memcpy(copy, source, length);
    copy[length] = 0;
    return copy;
}

int flint_http_new(const flint_http_options *options, flint_curl_loop **result)
{
    if (!result)
        return FLINT_HTTP_ARGUMENT;
    *result = NULL;
    if (!options || !options->connections || options->connections > MAX_CONNECTIONS
        || !options->per_origin || options->per_origin > options->connections
        || !options->body_bytes || !options->header_bytes || !options->connect_ms
        || options->connect_ms > LONG_MAX)
        return FLINT_HTTP_ARGUMENT;
    int code = flint_http_initialize();
    if (code)
        return code;

    flint_curl_loop *loop = calloc(1, sizeof(*loop));
    if (!loop)
        return FLINT_HTTP_MEMORY;
    atomic_init(&loop->owner, 0);
    loop->connections = options->connections;
    loop->per_origin = options->per_origin;
    loop->watch_revision = 1;
    loop->connect_ms = (long) options->connect_ms;
    loop->max_response = options->body_bytes;
    loop->max_headers = options->header_bytes;
    loop->redirects = options->redirects != 0;
    const char *ca_path = options->ca_path;
    size_t ca_length = options->ca_path_length;
    if (!ca_length) {
        static const char *const system_bundles[] = {
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/pki/tls/certs/ca-bundle.crt",
            "/etc/ssl/cert.pem"
        };
        for (size_t i = 0; i < sizeof(system_bundles) / sizeof(system_bundles[0]); ++i) {
            if (access(system_bundles[i], R_OK) == 0) {
                ca_path = system_bundles[i];
                ca_length = strlen(ca_path);
                break;
            }
        }
    }
    if (ca_length) {
        if (ca_length > MAX_URL || !ca_path || memchr(ca_path, 0, ca_length)) {
            free_loop(loop);
            return FLINT_HTTP_ARGUMENT;
        }
        loop->ca_path = copy_string(ca_path, ca_length);
        if (!loop->ca_path) {
            free_loop(loop);
            return FLINT_HTTP_MEMORY;
        }
    }
    code = make_storage(loop, options->connections);
    if (code) {
        free_loop(loop);
        return code;
    }
    *result = loop;
    return FLINT_HTTP_OK;
}

static int parse_url(CURLU *parsed, const char *url)
{
    if (curl_url_set(parsed, CURLUPART_URL, url, CURLU_DISALLOW_USER) != CURLUE_OK)
        return FLINT_HTTP_ARGUMENT;
    char *scheme = NULL;
    char *host = NULL;
    int status = FLINT_HTTP_ARGUMENT;
    if (curl_url_get(parsed, CURLUPART_SCHEME, &scheme, 0) == CURLUE_OK
        && curl_url_get(parsed, CURLUPART_HOST, &host, 0) == CURLUE_OK && *host) {
        if (strcasecmp(scheme, "http") == 0 || strcasecmp(scheme, "https") == 0)
            status = FLINT_HTTP_OK;
        else
            status = FLINT_HTTP_UNSUPPORTED;
    }
    curl_free(scheme);
    curl_free(host);
    return status;
}

static int normalize_url(const char *raw, size_t length, char **result)
{
    if (!raw || !length || length > MAX_URL || memchr(raw, 0, length))
        return FLINT_HTTP_ARGUMENT;
    char *input = copy_string(raw, length);
    CURLU *parsed = curl_url();
    if (!input || !parsed) {
        free(input);
        curl_url_cleanup(parsed);
        return FLINT_HTTP_MEMORY;
    }
    int status = parse_url(parsed, input);
    if (!status) {
        char *canonical = NULL;
        if (curl_url_get(parsed, CURLUPART_URL, &canonical, 0) != CURLUE_OK)
            status = FLINT_HTTP_ARGUMENT;
        else if (strlen(canonical) > MAX_URL)
            status = FLINT_HTTP_EXHAUSTED;
        else {
            *result = strdup(canonical);
            if (!*result)
                status = FLINT_HTTP_MEMORY;
        }
        curl_free(canonical);
    }
    free(input);
    curl_url_cleanup(parsed);
    return status;
}

flint_curl_loop *flint_curl_new(void)
{
    const flint_http_options options = {
        .connections = 64,
        .per_origin = 16,
        .body_bytes = 8 * 1024 * 1024,
        .header_bytes = 65536,
        .connect_ms = 5000
    };
    flint_curl_loop *loop = NULL;
    return flint_http_new(&options, &loop) == FLINT_HTTP_OK ? loop : NULL;
}

static const char *const method_names[] = {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"};

int flint_http_begin(flint_curl_loop *loop, const char *url, size_t length,
                     uint32_t method, uint32_t streaming, uint64_t *request_id)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    if (loop->fault)
        return loop->fault;
    if (!request_id || method > FLINT_HTTP_OPTIONS)
        return FLINT_HTTP_ARGUMENT;
    for (size_t slot = 0; slot < loop->request_count; ++slot) {
        request *record = &loop->requests[slot];
        if (record->state || record->generation == UINT32_MAX)
            continue;
        const int parsed = normalize_url(url, length, &record->url);
        if (parsed)
            return parsed;

        record->state = FLINT_HTTP_PREPARED;
        record->method = method;
        record->streaming = streaming != 0;
        *request_id = ((uint64_t) ++record->generation << 32) | (uint32_t) slot;
        return FLINT_HTTP_OK;
    }
    return FLINT_HTTP_EXHAUSTED;
}

static bool token_char(unsigned char value)
{
    return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z')
        || (value >= '0' && value <= '9') || strchr("!#$%&'*+-.^`_|~", value) != NULL;
}

static bool key_is(const char *key, size_t length, const char *name)
{
    return length == strlen(name) && strncasecmp(key, name, length) == 0;
}

static bool valid_header(const char *key, size_t length, const char *value, size_t value_length)
{
    if (!key || !length || length > 128 || (value_length && !value))
        return false;
    for (size_t i = 0; i < length; ++i)
        if (!key[i] || !token_char((unsigned char) key[i]))
            return false;
    for (size_t i = 0; i < value_length; ++i) {
        const unsigned char element = (unsigned char) value[i];
        if ((element < 32 && element != '\t') || element == 127)
            return false;
    }
    return !key_is(key, length, "Host") && !key_is(key, length, "Content-Length")
        && !key_is(key, length, "Transfer-Encoding") && !key_is(key, length, "Connection")
        && !key_is(key, length, "Upgrade") && !key_is(key, length, "Proxy-Connection");
}

int flint_http_header(flint_curl_loop *loop, uint64_t request_id, const char *key, size_t key_length,
                      const char *value, size_t value_length)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    request *record = lookup(loop, request_id);
    if (!record || record->state != FLINT_HTTP_PREPARED)
        return FLINT_HTTP_CONFLICT;
    if (record->header_count == MAX_HEADERS || key_length >= MAX_REQUEST_HEADER_BYTES
        || value_length >= MAX_REQUEST_HEADER_BYTES
        || key_length + value_length + 2 > MAX_REQUEST_HEADER_BYTES - record->request_headers_bytes)
        return FLINT_HTTP_EXHAUSTED;
    if (!valid_header(key, key_length, value, value_length))
        return FLINT_HTTP_ARGUMENT;

    const size_t total = key_length + value_length + 1;
    char *line = malloc(total + 1);
    if (!line)
        return FLINT_HTTP_MEMORY;
    memcpy(line, key, key_length);
    line[key_length] = value_length ? ':' : ';';
    if (value_length)
        memcpy(line + key_length + 1, value, value_length);
    line[total] = 0;
    struct curl_slist *headers = curl_slist_append(record->headers, line);
    free(line);
    if (!headers)
        return FLINT_HTTP_MEMORY;
    record->headers = headers;
    record->request_headers_bytes += total + 1;
    ++record->header_count;
    return FLINT_HTTP_OK;
}

int flint_http_body(flint_curl_loop *loop, uint64_t request_id, const uint8_t *data, size_t length)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    request *record = lookup(loop, request_id);
    if (!record || record->state != FLINT_HTTP_PREPARED || record->upload)
        return FLINT_HTTP_CONFLICT;
    if (length > INT64_MAX || (length && !data) || record->method == FLINT_HTTP_HEAD)
        return FLINT_HTTP_ARGUMENT;
    if (!length)
        return FLINT_HTTP_OK;
    record->upload = malloc(length);
    if (!record->upload)
        return FLINT_HTTP_MEMORY;
    memcpy(record->upload, data, length);
    record->upload_length = length;
    return FLINT_HTTP_OK;
}

static bool suppress_header(const request *record, const char *line)
{
    const size_t length = strcspn(line, ":;");
    return (record->redirected_origin && (key_is(line, length, "Authorization")
            || key_is(line, length, "Proxy-Authorization") || key_is(line, length, "Cookie")
            || key_is(line, length, "Cookie2")))
        || (record->dropped_upload && length >= 8 && strncasecmp(line, "Content-", 8) == 0);
}

static int configure_headers(request *record)
{
    if (!record->redirected_origin && !record->dropped_upload)
        return map_curl(CURL_ON_OWNER(record->loop, curl_easy_setopt(record->easy, CURLOPT_HTTPHEADER, record->headers)));
    for (const struct curl_slist *item = record->headers; item; item = item->next) {
        if (suppress_header(record, item->data))
            continue;
        struct curl_slist *next = curl_slist_append(record->sent_headers, item->data);
        if (!next)
            return FLINT_HTTP_MEMORY;
        record->sent_headers = next;
    }
    return map_curl(CURL_ON_OWNER(record->loop, curl_easy_setopt(record->easy, CURLOPT_HTTPHEADER, record->sent_headers)));
}

#define EASY(option, value) do { \
    CURLcode result = CURL_ON_OWNER(record->loop, curl_easy_setopt(record->easy, (option), (value))); \
    if (result != CURLE_OK) \
        return map_curl(result); \
} while (0)

static int configure_transport(request *record)
{
    flint_curl_loop *loop = record->loop;
    EASY(CURLOPT_URL, record->url);
    EASY(CURLOPT_PROTOCOLS_STR, "http,https");
    EASY(CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    EASY(CURLOPT_FOLLOWLOCATION, 0L);
    EASY(CURLOPT_UNRESTRICTED_AUTH, 0L);
    EASY(CURLOPT_PROXY, "");
    EASY(CURLOPT_NOSIGNAL, 1L);
    EASY(CURLOPT_SSL_VERIFYPEER, 1L);
    EASY(CURLOPT_SSL_VERIFYHOST, 2L);
    if (loop->ca_path)
        EASY(CURLOPT_CAINFO, loop->ca_path);
    EASY(CURLOPT_CONNECTTIMEOUT_MS, loop->connect_ms);
    EASY(CURLOPT_PIPEWAIT, 1L);
    EASY(CURLOPT_HTTP_VERSION, (long) CURL_HTTP_VERSION_2TLS);
    EASY(CURLOPT_ACCEPT_ENCODING, "");
    EASY(CURLOPT_WRITEFUNCTION, receive_body);
    EASY(CURLOPT_WRITEDATA, record);
    EASY(CURLOPT_HEADERFUNCTION, receive_header);
    EASY(CURLOPT_HEADERDATA, record);
    EASY(CURLOPT_PRIVATE, record);
    return FLINT_HTTP_OK;
}

static int configure_method(request *record)
{
    const uint32_t method = record->method;
    if (record->upload || method == FLINT_HTTP_POST || method == FLINT_HTTP_PUT || method == FLINT_HTTP_PATCH) {
        EASY(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t) record->upload_length);
        EASY(CURLOPT_POSTFIELDS, record->upload ? (char *) record->upload : "");
    }
    if (method == FLINT_HTTP_HEAD)
        EASY(CURLOPT_NOBODY, 1L);
    EASY(CURLOPT_CUSTOMREQUEST, method_names[method]);
    return FLINT_HTTP_OK;
}

#undef EASY

static int activate(request *record)
{
    int status = configure_transport(record);
    if (!status)
        status = configure_method(record);
    if (!status)
        status = configure_headers(record);
    if (status)
        return status;

    if (CURL_ON_OWNER(record->loop, curl_multi_add_handle(record->loop->multi, record->easy)) != CURLM_OK)
        return FLINT_HTTP_IO;
    record->state = FLINT_HTTP_RUNNING;
    return FLINT_HTTP_OK;
}

int flint_http_activate(flint_curl_loop *loop, uint64_t request_id)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    request *record = lookup(loop, request_id);
    if (!record || record->state != FLINT_HTTP_PREPARED)
        return FLINT_HTTP_CONFLICT;
    return activate(record);
}

int flint_curl_start(flint_curl_loop *loop, const char *url, const char *method,
                    flint_curl_data_cb callback, void *user, uint64_t *request_id)
{
    if (!url || !method)
        return FLINT_HTTP_ARGUMENT;
    for (uint32_t i = 0; i <= FLINT_HTTP_OPTIONS; ++i) {
        if (strcmp(method, method_names[i]) != 0)
            continue;
        const int status = flint_http_begin(loop, url, strnlen(url, MAX_URL + 1), i, 0, request_id);
        if (status)
            return status;
        request *record = lookup(loop, *request_id);
        record->legacy = callback;
        record->legacy_user = user;
        const int activated = activate(record);
        if (activated)
            free_request(record);
        return activated;
    }
    return FLINT_HTTP_ARGUMENT;
}

static void get_response(request *record, CURLcode result)
{
    long status = 0;
    long version = 0;
    if (CURL_ON_OWNER(record->loop, curl_easy_getinfo(record->easy, CURLINFO_RESPONSE_CODE, &status)) == CURLE_OK)
        record->status = (uint32_t) status;
    if (CURL_ON_OWNER(record->loop, curl_easy_getinfo(record->easy, CURLINFO_HTTP_VERSION, &version)) == CURLE_OK) {
        if (version == CURL_HTTP_VERSION_2_0)
            record->version = 2;
        else if (version == CURL_HTTP_VERSION_1_0 || version == CURL_HTTP_VERSION_1_1)
            record->version = 1;
    }
    if (!record->error)
        record->error = map_curl(result);
    if (!record->error && record->loop->redirects && redirect_code(record->status)) {
        char *raw = NULL;
        if (CURL_ON_OWNER(record->loop, curl_easy_getinfo(record->easy, CURLINFO_REDIRECT_URL, &raw)) == CURLE_OK && raw)
            record->error = normalize_url(raw, strnlen(raw, MAX_URL + 1), &record->redirect);
        else if (record->location)
            record->error = FLINT_HTTP_ARGUMENT;
    }
}

static int collect(flint_curl_loop *loop)
{
    int queued;
    CURLMsg *event;
    while ((event = CURL_ON_OWNER(loop, curl_multi_info_read(loop->multi, &queued))) != NULL) {
        if (event->msg != CURLMSG_DONE)
            continue;
        request *record = NULL;
        if (CURL_ON_OWNER(loop, curl_easy_getinfo(event->easy_handle, CURLINFO_PRIVATE, &record)) != CURLE_OK
            || !record || record->state != FLINT_HTTP_RUNNING)
            return FLINT_HTTP_IO;
        get_response(record, event->data.result);
        if (CURL_ON_OWNER(loop, curl_multi_remove_handle(loop->multi, record->easy)) != CURLM_OK)
            return FLINT_HTTP_IO;
        record->state = FLINT_HTTP_COMPLETE;
        record->paused = false;
    }
    return FLINT_HTTP_OK;
}

static int action(flint_curl_loop *loop, curl_socket_t fd, int events)
{
    if (loop->fault)
        return loop->fault;
    int running;
    loop->in_action = true;
    const CURLMcode status = CURL_ON_OWNER(loop, curl_multi_socket_action(loop->multi, fd, events, &running));
    loop->in_action = false;
    if (loop->fault)
        return loop->fault;
    if (status != CURLM_OK && status != CURLM_BAD_SOCKET)
        return loop->fault = FLINT_HTTP_IO;
    const int result = collect(loop);
    if (result)
        loop->fault = result;
    return result;
}

int flint_curl_socket(flint_curl_loop *loop, intptr_t fd, int events)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    if (fd < 0 || fd > INT_MAX || (events & ~(FLINT_HTTP_READ | FLINT_HTTP_WRITE | FLINT_HTTP_ERROR)))
        return FLINT_HTTP_ARGUMENT;
    return lookup_watch(loop, fd) ? action(loop, (curl_socket_t) fd, events) : FLINT_HTTP_OK;
}

int flint_curl_timeout(flint_curl_loop *loop)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    loop->timer_pending = false;
    return action(loop, CURL_SOCKET_TIMEOUT, 0);
}

int flint_http_due(flint_curl_loop *loop)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    if (loop->fault)
        return loop->fault;
    return loop->timer_pending && clock_ms() >= loop->timer
        ? flint_curl_timeout(loop) : FLINT_HTTP_OK;
}

int flint_curl_cancel(flint_curl_loop *loop, uint64_t request_id)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    request *record = lookup(loop, request_id);
    if (!record)
        return FLINT_HTTP_NOT_FOUND;
    if (record->state == FLINT_HTTP_COMPLETE)
        return FLINT_HTTP_OK;
    if (record->state == FLINT_HTTP_RUNNING
        && CURL_ON_OWNER(loop, curl_multi_remove_handle(loop->multi, record->easy)) != CURLM_OK)
        return FLINT_HTTP_IO;
    record->state = FLINT_HTTP_COMPLETE;
    record->error = FLINT_HTTP_CANCELLED;
    record->paused = false;
    return FLINT_HTTP_OK;
}

int flint_http_view_request(flint_curl_loop *loop, uint64_t request_id, flint_http_view *view)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    request *record = lookup(loop, request_id);
    if (!record || !view)
        return FLINT_HTTP_NOT_FOUND;
    *view = (flint_http_view) {
        record->state, record->status, record->version, (uint32_t) record->error,
        record->response_headers.data, record->response_headers.length, record->body.data, record->body.length,
        record->chunk, record->chunk_length, record->redirect, record->redirect ? strlen(record->redirect) : 0,
        record->url, strlen(record->url), record->paused
    };
    return FLINT_HTTP_OK;
}

int flint_http_consume_chunk(flint_curl_loop *loop, uint64_t request_id)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    request *record = lookup(loop, request_id);
    if (!record || !record->streaming || !record->chunk_length)
        return FLINT_HTTP_CONFLICT;
    record->chunk_length = 0;
    if (record->paused && record->state == FLINT_HTTP_RUNNING) {
        record->paused = false;
        loop->in_action = true;
        const CURLcode resumed = CURL_ON_OWNER(record->loop, curl_easy_pause(record->easy, CURLPAUSE_CONT));
        loop->in_action = false;
        if (resumed != CURLE_OK)
            return record->error ? record->error : map_curl(resumed);
        return collect(loop);
    }
    return FLINT_HTTP_OK;
}

static bool same_part(CURLU *left, CURLU *right, CURLUPart part, unsigned flags)
{
    char *a = NULL;
    char *b = NULL;
    const bool matches = curl_url_get(left, part, &a, flags) == CURLUE_OK
        && curl_url_get(right, part, &b, flags) == CURLUE_OK && strcasecmp(a, b) == 0;
    curl_free(a);
    curl_free(b);
    return matches;
}

static int redirect_origin(const char *current, const char *next, bool *crosses)
{
    CURLU *left = curl_url();
    CURLU *right = curl_url();
    int status = FLINT_HTTP_MEMORY;
    if (left && right) {
        status = parse_url(left, current);
        if (!status)
            status = parse_url(right, next);
        if (!status && strncasecmp(current, "https:", 6) == 0 && strncasecmp(next, "http:", 5) == 0)
            status = FLINT_HTTP_DENIED;
        if (!status)
            *crosses = !same_part(left, right, CURLUPART_SCHEME, 0)
                || !same_part(left, right, CURLUPART_HOST, 0)
                || !same_part(left, right, CURLUPART_PORT, CURLU_DEFAULT_PORT);
    }
    curl_url_cleanup(left);
    curl_url_cleanup(right);
    return status;
}

int flint_http_follow(flint_curl_loop *loop, uint64_t request_id)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    request *record = lookup(loop, request_id);
    if (!record || record->state != FLINT_HTTP_COMPLETE || record->error || !record->redirect
        || record->chunk_length)
        return FLINT_HTTP_CONFLICT;
    if (record->redirects == MAX_REDIRECTS)
        return FLINT_HTTP_EXHAUSTED;

    bool crosses;
    const int status = redirect_origin(record->url, record->redirect, &crosses);
    if (status)
        return status;
    ++record->redirects;
    record->redirected_origin |= crosses;
    if ((record->status == 303 && record->method != FLINT_HTTP_HEAD)
        || ((record->status == 301 || record->status == 302) && record->method == FLINT_HTTP_POST)) {
        record->method = FLINT_HTTP_GET;
        record->dropped_upload = true;
        free(record->upload);
        record->upload = NULL;
        record->upload_length = 0;
    }
    CURL_ON_OWNER(record->loop, curl_easy_reset(record->easy));
    curl_slist_free_all(record->sent_headers);
    record->sent_headers = NULL;
    free(record->url);
    record->url = record->redirect;
    record->redirect = NULL;
    record->response_headers.length = 0;
    record->body.length = 0;
    record->decoded = 0;
    record->received_header_bytes = 0;
    record->status = 0;
    record->version = 0;
    record->location = false;
    record->state = FLINT_HTTP_PREPARED;
    return activate(record);
}

int flint_http_release(flint_curl_loop *loop, uint64_t request_id)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    request *record = lookup(loop, request_id);
    if (!record)
        return FLINT_HTTP_NOT_FOUND;
    if (record->state == FLINT_HTTP_RUNNING) {
        const int stopped = flint_curl_cancel(loop, request_id);
        if (stopped)
            return stopped;
    }
    free_request(record);
    return FLINT_HTTP_OK;
}

int flint_http_watch_snapshot(flint_curl_loop *loop, flint_http_watch *output, size_t capacity,
                               uint64_t *revision, size_t *count)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    if (!output || !revision || !count)
        return FLINT_HTTP_ARGUMENT;
    if (*revision == loop->watch_revision) {
        *count = SIZE_MAX;
        return FLINT_HTTP_OK;
    }
    *count = 0;
    for (size_t i = 0; i < loop->watch_capacity; ++i) {
        const flint_http_watch *watch = &loop->watches[i];
        if (!watch->generation)
            continue;
        if (*count == capacity)
            return FLINT_HTTP_EXHAUSTED;
        output[(*count)++] = *watch;
    }
    *revision = loop->watch_revision;
    return FLINT_HTTP_OK;
}

int flint_http_poll(flint_curl_loop *loop, uint32_t max_wait_ms)
{
    const int owner = owner_status(loop);
    if (owner)
        return owner;
    if (max_wait_ms > INT_MAX)
        return FLINT_HTTP_ARGUMENT;
    int status = flint_http_due(loop);
    if (status)
        return status;
    size_t count = 0;
    for (size_t i = 0; i < loop->watch_capacity; ++i) {
        const flint_http_watch *watch = &loop->watches[i];
        if (!watch->generation)
            continue;
        struct pollfd *fd = &loop->poll_fds[count];
        fd->fd = (int) watch->fd;
        fd->events = (watch->events & FLINT_HTTP_READ ? POLLIN : 0)
            | (watch->events & FLINT_HTTP_WRITE ? POLLOUT : 0);
        fd->revents = 0;
        loop->poll_generations[count++] = watch->generation;
    }
    uint64_t delay = max_wait_ms;
    if (loop->timer_pending) {
        const uint64_t now = clock_ms();
        const uint64_t remaining = now >= loop->timer ? 0 : loop->timer - now;
        if (remaining < delay)
            delay = remaining;
    }
    const int ready = poll(loop->poll_fds, count, (int) delay);
    if (ready < 0 && errno != EINTR)
        return FLINT_HTTP_IO;
    if (ready > 0) {
        for (size_t i = 0; i < count; ++i) {
            const struct pollfd *fd = &loop->poll_fds[i];
            if (!fd->revents)
                continue;
            const flint_http_watch *watch = lookup_watch(loop, fd->fd);
            if (!watch || watch->generation != loop->poll_generations[i])
                continue;
            const int events = (fd->revents & POLLIN ? FLINT_HTTP_READ : 0)
                | (fd->revents & POLLOUT ? FLINT_HTTP_WRITE : 0)
                | (fd->revents & (POLLERR | POLLHUP | POLLNVAL) ? FLINT_HTTP_ERROR : 0);
            status = action(loop, fd->fd, events);
            if (status)
                return status;
        }
    }
    return flint_http_due(loop);
}

void flint_curl_free(flint_curl_loop *loop)
{
    if (owner_identity_status(loop) == FLINT_HTTP_OK)
        free_loop(loop);
}

#endif
