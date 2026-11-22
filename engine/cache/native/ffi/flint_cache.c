#define _POSIX_C_SOURCE 200809L
#include "flint_cache.h"
#include "flint_clock.h"

#if defined(FLINT_HAS_HIREDIS) && (defined(__linux__) || defined(__APPLE__))

#include <arpa/inet.h>
#include <errno.h>
#include <hiredis/async.h>
#include <hiredis/hiredis_ssl.h>
#include <hiredis/sds.h>
#include <inttypes.h>
#include <netdb.h>
#include <openssl/crypto.h>
#include <openssl/ssl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#if defined(__APPLE__)
#include "flint_wake.h"
#else
#include <sys/eventfd.h>
#endif
#include <time.h>
#include <unistd.h>

enum {
    TICKET_BITS = 10,
    MAX_PENDING = 1 << TICKET_BITS,
    MAX_REPLY = 16 * 1024 * 1024,
    MAX_PENDING_BYTES = 64 * 1024 * 1024,
    MAX_URL = 2048,
    MAX_HOST = 253,
    MAX_SECRET = 256,
    MAX_NAMESPACE = 64,
    MAX_SCAN_ENTRIES = 512,
    MAX_SCAN_PAGES = 16384,
    EVENT_READ = 1,
    EVENT_WRITE = 2
};

enum slot_state { SLOT_FREE, SLOT_QUEUED, SLOT_SENT, SLOT_DONE };
enum connection_state { STARTING, READY, FAILED, STOPPING, STOPPED };
enum scan_stage { SCANNING, DELETING };

typedef struct endpoint {
    char host[MAX_HOST + 1];
    char dial[INET6_ADDRSTRLEN];
    uint16_t port, database;
    bool tls, authenticated, ip_literal;
    char user[MAX_SECRET], password[MAX_SECRET];
    size_t user_length, password_length;
} endpoint;

typedef struct operation {
    uint64_t ticket;
    enum slot_state state;
    uint32_t kind;
    bool abandoned;
    char *wire;
    size_t wire_length;
    uint8_t *result;
    size_t result_length;
    int status;
} operation;

struct flint_redis_connection {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    enum connection_state state;
    int failure;
    int wake_fd;
#if defined(__APPLE__)
    int wake_writer;
#endif
    uint64_t generation;
    unsigned queue_head, queue_count, taken;
    uint16_t fifo[MAX_PENDING];
    operation *slots;
    size_t wire_bytes, reply_bytes, payload_limit;
    atomic_bool stop;
    atomic_bool stopped;
    atomic_uint_fast64_t pushes;

    endpoint address;
    char *ca_file;
    char prefix[MAX_NAMESPACE + 8];
    size_t prefix_length;

    /* Everything below belongs exclusively to the owner loop after attach. */
    redisAsyncContext *client;
    SSL_CTX *tls_context;
    SSL *tls_session;
    pthread_t owner;
    sigset_t previous_mask;
    bool owner_known, timer_pending, pipe_mask_saved;
    unsigned interest, awaiting;
    uint64_t timer;
    redisReplyObjectFunctions *objects;
    redisReplyObjectFunctions bounded;
    redisContextFuncs io;
    ssize_t (*read_socket)(redisContext *, char *, size_t);
    size_t parse_bytes;
    int parser_error;

    operation *clear;
    enum scan_stage scan_stage;
    unsigned scan_pages;
    char cursor[21];
};

static uint64_t time_ms(void)
{
    struct timespec clock;
    return clock_gettime(FLINT_DEADLINE_CLOCK, &clock) == 0
        ? (uint64_t)clock.tv_sec * 1000 + (uint64_t)clock.tv_nsec / 1000000 : 0;
}

static int digit(char value)
{
    if (value >= '0' && value <= '9')
        return value - '0';
    if (value >= 'a' && value <= 'f')
        return value - 'a' + 10;
    return value >= 'A' && value <= 'F' ? value - 'A' + 10 : -1;
}

static bool decode_secret(const char *input, size_t length, char output[MAX_SECRET], size_t *used)
{
    *used = 0;
    for (size_t i = 0; i < length; ++i) {
        int byte = (unsigned char)input[i];
        if (byte == '%') {
            if (length - i < 3)
                return false;
            const int top = digit(input[i + 1]);
            const int bottom = digit(input[i + 2]);
            if (top < 0 || bottom < 0)
                return false;
            byte = (top << 4) | bottom;
            i += 2;
        } else if (byte <= ' ' || byte >= 127) {
            return false;
        }
        if (*used == MAX_SECRET)
            return false;
        output[(*used)++] = (char)byte;
    }
    return true;
}

static bool parse_uint(const char *text, size_t length, uint64_t limit, uint64_t *out)
{
    *out = 0;
    if (!length)
        return false;
    for (size_t i = 0; i < length; ++i) {
        const unsigned value = (unsigned char)text[i] - '0';
        if (value > 9 || value > limit || *out > (limit - value) / 10)
            return false;
        *out = *out * 10 + value;
    }
    return true;
}

static bool credentials(endpoint *target, const char *start, size_t length)
{
    const char *colon = memchr(start, ':', length);
    const size_t username = colon ? (size_t)(colon - start) : 0;
    if (username) {
        if (!decode_secret(start, username, target->user, &target->user_length))
            return false;
    } else {
        memcpy(target->user, "default", 7);
        target->user_length = 7;
    }
    const char *password = colon ? colon + 1 : start;
    target->authenticated = true;
    return decode_secret(password, length - (size_t)(password - start), target->password, &target->password_length);
}

static bool host_character(unsigned char value)
{
    return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z')
        || (value >= '0' && value <= '9') || value == '.' || value == '-';
}

static int read_host(endpoint *target, const char *start, const char *end)
{
    bool bracketed = start != end && *start == '[';
    const char *host_start = start + bracketed;
    const char *host_end = bracketed ? memchr(host_start, ']', (size_t)(end - host_start))
                                     : memchr(host_start, ':', (size_t)(end - host_start));
    if (bracketed && !host_end)
        return FLINT_REDIS_ARGUMENT;
    if (!host_end)
        host_end = end;
    const size_t length = (size_t)(host_end - host_start);
    if (!length || length > MAX_HOST)
        return FLINT_REDIS_ARGUMENT;
    memcpy(target->host, host_start, length);
    target->host[length] = 0;

    uint64_t port = 6379;
    const char *service = host_end + bracketed;
    if (service != end && (*service != ':' || !parse_uint(service + 1, (size_t)(end - service - 1), 65535, &port)))
        return FLINT_REDIS_ARGUMENT;
    if (!port)
        return FLINT_REDIS_ARGUMENT;
    target->port = (uint16_t)port;

    struct in_addr v4;
    struct in6_addr v6;
    const bool is4 = !bracketed && inet_pton(AF_INET, target->host, &v4) == 1;
    const bool is6 = bracketed && inet_pton(AF_INET6, target->host, &v6) == 1;
    target->ip_literal = is4 || is6;
    if (bracketed && !is6)
        return FLINT_REDIS_ARGUMENT;
    if (!target->ip_literal)
        for (size_t i = 0; i < length; ++i)
            if (!host_character((unsigned char)target->host[i]))
                return FLINT_REDIS_ARGUMENT;

    bool local = (is4 && (ntohl(v4.s_addr) >> 24) == 127) || (is6 && IN6_IS_ADDR_LOOPBACK(&v6));
    if (local || target->tls)
        return FLINT_REDIS_OK;
    if (strcasecmp(target->host, "localhost") == 0) {
        memcpy(target->dial, "127.0.0.1", sizeof("127.0.0.1"));
        return FLINT_REDIS_OK;
    }
    return FLINT_REDIS_DENIED;
}

static int read_url(endpoint *target, const char *url, size_t length)
{
    if (!url || length > MAX_URL || length < 9 || memchr(url, 0, length))
        return FLINT_REDIS_ARGUMENT;
    const char *end = url + length;
    const char *start;
    if (length > 9 && strncasecmp(url, "rediss://", 9) == 0) {
        start = url + 9;
        target->tls = true;
    } else if (strncasecmp(url, "redis://", 8) == 0) {
        start = url + 8;
    } else {
        return FLINT_REDIS_ARGUMENT;
    }
    for (const char *scan = start; scan < end; ++scan)
        if (*scan == '?' || *scan == '#')
            return FLINT_REDIS_ARGUMENT;

    const char *path = memchr(start, '/', (size_t)(end - start));
    if (path && path + 1 < end) {
        uint64_t database;
        if (!parse_uint(path + 1, (size_t)(end - path - 1), 65535, &database))
            return FLINT_REDIS_ARGUMENT;
        target->database = (uint16_t)database;
    }
    if (path)
        end = path;

    const char *login = memchr(start, '@', (size_t)(end - start));
    if (login) {
        if (!credentials(target, start, (size_t)(login - start)))
            return FLINT_REDIS_ARGUMENT;
        start = login + 1;
    }
    return read_host(target, start, end);
}

static bool namespace_prefix(flint_redis_connection *connection, const char *name, size_t length)
{
    if (!name || !length || length > MAX_NAMESPACE)
        return false;
    for (size_t i = 0; i < length; ++i)
        if (!host_character((unsigned char)name[i]) && name[i] != '_')
            return false;
    memcpy(connection->prefix, "flint:", 6);
    memcpy(connection->prefix + 6, name, length);
    connection->prefix[6 + length] = ':';
    connection->prefix_length = 7 + length;
    return true;
}

static char *trust_file(const flint_redis_options *options)
{
    if (options->ca_length) {
        char *path = malloc(options->ca_length + 1);
        if (path) {
            memcpy(path, options->ca_file, options->ca_length);
            path[options->ca_length] = 0;
        }
        return path;
    }
    const char *const paths[] = {"/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt",
                                 "/etc/ssl/cert.pem"};
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); ++i)
        if (access(paths[i], R_OK) == 0)
            return strdup(paths[i]);
    return NULL;
}

static int prepare_sync(flint_redis_connection *connection)
{
    if (pthread_mutex_init(&connection->lock, NULL) != 0)
        return FLINT_REDIS_IO;
    pthread_condattr_t attrs;
    if (pthread_condattr_init(&attrs) != 0) {
        pthread_mutex_destroy(&connection->lock);
        return FLINT_REDIS_IO;
    }
#if defined(__APPLE__)
    /* Darwin has no pthread_condattr_setclock; flint_redis_wait uses a relative wait instead. */
    int status = 0;
#else
    int status = pthread_condattr_setclock(&attrs, CLOCK_MONOTONIC);
#endif
    if (!status)
        status = pthread_cond_init(&connection->changed, &attrs);
    pthread_condattr_destroy(&attrs);
    if (status)
        pthread_mutex_destroy(&connection->lock);
    return status ? FLINT_REDIS_IO : FLINT_REDIS_OK;
}

int flint_redis_create(const flint_redis_options *options, flint_redis_connection **out)
{
    if (!out)
        return FLINT_REDIS_ARGUMENT;
    *out = NULL;
    if (!options || !options->payload_limit || options->payload_limit > MAX_PENDING_BYTES
        || options->ca_length > 4096 || (options->ca_length && (!options->ca_file
            || memchr(options->ca_file, 0, options->ca_length))))
        return FLINT_REDIS_ARGUMENT;

    flint_redis_connection *connection = calloc(1, sizeof(*connection));
    if (!connection)
        return FLINT_REDIS_MEMORY;
    connection->wake_fd = -1;
#if defined(__APPLE__)
    connection->wake_writer = -1;
#endif
    int status = read_url(&connection->address, options->url, options->url_length);
    if (!status && !namespace_prefix(connection, options->namespace_name, options->namespace_length))
        status = FLINT_REDIS_ARGUMENT;
    if (!status)
        status = prepare_sync(connection);
    if (status) {
        OPENSSL_cleanse(&connection->address, sizeof(connection->address));
        free(connection);
        return status;
    }

    connection->payload_limit = options->payload_limit;
    connection->slots = calloc(MAX_PENDING, sizeof(*connection->slots));
#if defined(__APPLE__)
    if (flint_wake_open(&connection->wake_fd, &connection->wake_writer))
        connection->wake_fd = connection->wake_writer = -1;
#else
    connection->wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
#endif
    if (connection->address.tls)
        connection->ca_file = trust_file(options);
    atomic_init(&connection->stop, false);
    atomic_init(&connection->stopped, false);
    atomic_init(&connection->pushes, 0);
    if (!connection->slots || connection->wake_fd < 0 || (connection->address.tls && options->ca_length && !connection->ca_file)) {
        const int error = connection->wake_fd < 0 ? FLINT_REDIS_IO : FLINT_REDIS_MEMORY;
        flint_redis_free(connection);
        return error;
    }
    *out = connection;
    return FLINT_REDIS_OK;
}

int flint_redis_resolve(flint_redis_connection *connection)
{
    if (!connection)
        return FLINT_REDIS_ARGUMENT;
    endpoint *address = &connection->address;
    if (address->dial[0])
        return FLINT_REDIS_OK;
    if (address->ip_literal) {
        memcpy(address->dial, address->host, strlen(address->host) + 1);
        return FLINT_REDIS_OK;
    }
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM };
    struct addrinfo *list = NULL;
    const int resolved = getaddrinfo(address->host, NULL, &hints, &list);
    if (resolved != 0)
        return resolved == EAI_MEMORY ? FLINT_REDIS_MEMORY : FLINT_REDIS_UNAVAILABLE;

    const struct addrinfo *candidate = NULL;
    for (const struct addrinfo *item = list; item; item = item->ai_next) {
        if (item->ai_family == AF_INET) {
            candidate = item;
            break;
        }
        if (item->ai_family == AF_INET6 && !candidate)
            candidate = item;
    }
    const char *numeric = NULL;
    if (candidate) {
        const void *host = candidate->ai_family == AF_INET
            ? (const void *)&((const struct sockaddr_in *)candidate->ai_addr)->sin_addr
            : (const void *)&((const struct sockaddr_in6 *)candidate->ai_addr)->sin6_addr;
        numeric = inet_ntop(candidate->ai_family, host, address->dial, sizeof(address->dial));
    }
    freeaddrinfo(list);
    return numeric ? FLINT_REDIS_OK : FLINT_REDIS_UNAVAILABLE;
}

static void notify(flint_redis_connection *connection)
{
    pthread_cond_broadcast(&connection->changed);
}

static void signal_owner(const flint_redis_connection *connection)
{
    if (connection->wake_fd >= 0) {
#if defined(__APPLE__)
        flint_wake_signal(connection->wake_writer);
#else
        while (eventfd_write(connection->wake_fd, 1) < 0 && errno == EINTR) {
        }
#endif
    }
}

static int phase(const flint_redis_connection *connection)
{
    switch (connection->state) {
    case STARTING: return FLINT_REDIS_WAITING;
    case READY: return FLINT_REDIS_OK;
    case FAILED: return connection->failure;
    default: return FLINT_REDIS_CANCELLED;
    }
}

int flint_redis_ready(flint_redis_connection *connection)
{
    if (!connection)
        return FLINT_REDIS_ARGUMENT;
    pthread_mutex_lock(&connection->lock);
    const int status = phase(connection);
    pthread_mutex_unlock(&connection->lock);
    return status;
}

int flint_redis_wait(flint_redis_connection *connection, uint32_t max_wait_ms)
{
    if (!connection || max_wait_ms > 1000)
        return FLINT_REDIS_ARGUMENT;
#if defined(__APPLE__)
    /* A relative wait is immune to wall-clock steps, as the monotonic condition clock is on Linux. */
    const struct timespec limit = {max_wait_ms / 1000, (long)(max_wait_ms % 1000) * 1000000L};
    pthread_mutex_lock(&connection->lock);
    const int waited = pthread_cond_timedwait_relative_np(&connection->changed, &connection->lock, &limit);
#else
    struct timespec until;
    if (clock_gettime(CLOCK_MONOTONIC, &until) != 0)
        return FLINT_REDIS_IO;
    until.tv_nsec += (long)max_wait_ms * 1000000L;
    if (until.tv_nsec >= 1000000000L) {
        ++until.tv_sec;
        until.tv_nsec -= 1000000000L;
    }
    pthread_mutex_lock(&connection->lock);
    const int waited = pthread_cond_timedwait(&connection->changed, &connection->lock, &until);
#endif
    pthread_mutex_unlock(&connection->lock);
    return (waited == 0 || waited == ETIMEDOUT) ? FLINT_REDIS_OK : FLINT_REDIS_IO;
}

static operation *lookup(flint_redis_connection *connection, uint64_t ticket)
{
    if (!connection->slots || !ticket)
        return NULL;
    operation *task = &connection->slots[ticket & (MAX_PENDING - 1)];
    return task->state != SLOT_FREE && task->ticket == ticket ? task : NULL;
}

/* All queue and slot accounting is under the producer gate. */
static void clear_slot(flint_redis_connection *connection, operation *task)
{
    if (task->wire) {
        connection->wire_bytes -= task->wire_length;
        redisFreeCommand(task->wire);
    }
    if (task->result) {
        connection->reply_bytes -= task->result_length;
        free(task->result);
    }
    memset(task, 0, sizeof(*task));
    --connection->taken;
}

static void clear_all(flint_redis_connection *connection)
{
    if (!connection->slots)
        return;
    for (unsigned index = 0; index < MAX_PENDING; ++index)
        if (connection->slots[index].state != SLOT_FREE)
            clear_slot(connection, &connection->slots[index]);
    free(connection->slots);
    connection->slots = NULL;
}

static int issue_status(const flint_redis_connection *connection)
{
    const int status = phase(connection);
    if (status)
        return status == FLINT_REDIS_WAITING ? FLINT_REDIS_UNAVAILABLE : status;
    return connection->taken == MAX_PENDING || connection->generation == UINT64_MAX >> TICKET_BITS
        ? FLINT_REDIS_EXHAUSTED : FLINT_REDIS_OK;
}

static int enqueue(flint_redis_connection *connection, uint32_t kind, size_t argc,
                   const char **argv, const size_t *lengths, uint64_t *ticket)
{
    char *wire = NULL;
    size_t length = 0;
    if (argc) {
        const long long formatted = redisFormatCommandArgv(&wire, (int)argc, argv, lengths);
        if (formatted < 0)
            return FLINT_REDIS_MEMORY;
        length = (size_t)formatted;
        if (length > MAX_PENDING_BYTES - connection->wire_bytes) {
            redisFreeCommand(wire);
            return FLINT_REDIS_EXHAUSTED;
        }
    }
    unsigned index = 0;
    while (connection->slots[index].state != SLOT_FREE)
        ++index;
    operation *task = &connection->slots[index];
    task->ticket = (++connection->generation << TICKET_BITS) | index;
    task->state = SLOT_QUEUED;
    task->kind = kind;
    task->wire = wire;
    task->wire_length = length;
    connection->wire_bytes += length;
    const unsigned tail = (connection->queue_head + connection->queue_count) % MAX_PENDING;
    connection->fifo[tail] = (uint16_t)index;
    ++connection->queue_count;
    ++connection->taken;
    *ticket = task->ticket;
    signal_owner(connection);
    return FLINT_REDIS_OK;
}

static int queue_key(flint_redis_connection *connection, uint32_t kind, const uint8_t *key, size_t key_length,
                     const uint8_t *value, size_t value_length, int64_t ttl_nanos, uint64_t *ticket)
{
    if (kind == FLINT_REDIS_CLEAR)
        return enqueue(connection, kind, 0, NULL, NULL, ticket);
    const size_t full_length = connection->prefix_length + key_length;
    char *full_key = malloc(full_length);
    if (!full_key)
        return FLINT_REDIS_MEMORY;
    memcpy(full_key, connection->prefix, connection->prefix_length);
    if (key_length)
        memcpy(full_key + connection->prefix_length, key, key_length);

    const char *const command = kind == FLINT_REDIS_GET ? "GET" : kind == FLINT_REDIS_SET ? "SET" : "DEL";
    char ttl[24];
    const int64_t millis = ttl_nanos / 1000000 + (ttl_nanos % 1000000 != 0);
    const int ttl_length = snprintf(ttl, sizeof(ttl), "%" PRId64, millis);
    const char *args[] = {command, full_key, value_length ? (const char *)value : "", "PX", ttl};
    const size_t lengths[] = {3, full_length, value_length, 2, (size_t)ttl_length};
    const int queued = enqueue(connection, kind, kind == FLINT_REDIS_SET ? 5 : 2, args, lengths, ticket);
    free(full_key);
    return queued;
}

int flint_redis_issue(flint_redis_connection *connection, uint32_t kind, const uint8_t *key, size_t key_length,
                      const uint8_t *value, size_t value_length, int64_t ttl_nanos, uint64_t *ticket)
{
    if (!connection || !ticket || kind < FLINT_REDIS_GET || kind > FLINT_REDIS_CLEAR
        || (key_length && !key) || (value_length && !value)
        || (kind == FLINT_REDIS_SET && ttl_nanos <= 0))
        return FLINT_REDIS_ARGUMENT;
    *ticket = 0;
    const size_t limit = connection->payload_limit < MAX_REPLY ? connection->payload_limit : MAX_REPLY;
    if (key_length > limit || value_length > limit - key_length)
        return FLINT_REDIS_EXHAUSTED;

    pthread_mutex_lock(&connection->lock);
    int status = issue_status(connection);
    if (!status)
        status = queue_key(connection, kind, key, key_length, value, value_length, ttl_nanos, ticket);
    pthread_mutex_unlock(&connection->lock);
    return status;
}

int flint_redis_command(flint_redis_connection *connection, size_t argc, const char *const *argv,
                         const size_t *lengths, uint64_t *ticket)
{
    if (!connection || !ticket || !argc || argc > 16 || !argv || !lengths || !argv[0])
        return FLINT_REDIS_ARGUMENT;
    *ticket = 0;
    /* Preserve the request/reply mode on the private connection. */
    static const char *const commands[] = {"GET", "SET", "DEL", "PING", "SCAN"};
    bool allowed = false;
    for (size_t i = 0; i < sizeof(commands) / sizeof(commands[0]); ++i)
        allowed |= strlen(commands[i]) == lengths[0] && strncasecmp(argv[0], commands[i], lengths[0]) == 0;
    if (!allowed)
        return FLINT_REDIS_UNSUPPORTED;
    const char *args[16];
    size_t bytes = 0;
    for (size_t i = 0; i < argc; ++i) {
        if ((!argv[i] && lengths[i]) || lengths[i] > MAX_REPLY - bytes)
            return FLINT_REDIS_ARGUMENT;
        args[i] = lengths[i] ? argv[i] : "";
        bytes += lengths[i];
    }
    pthread_mutex_lock(&connection->lock);
    int status = issue_status(connection);
    if (!status)
        status = enqueue(connection, 0, argc, args, lengths, ticket);
    pthread_mutex_unlock(&connection->lock);
    return status;
}

int flint_redis_take(flint_redis_connection *connection, uint64_t ticket, flint_redis_result *result)
{
    if (!connection || !result)
        return FLINT_REDIS_ARGUMENT;
    *result = (flint_redis_result){0};
    pthread_mutex_lock(&connection->lock);
    operation *task = lookup(connection, ticket);
    int status = FLINT_REDIS_WAITING;
    if (atomic_load_explicit(&connection->stop, memory_order_relaxed))
        status = FLINT_REDIS_CANCELLED;
    else if (!task || task->abandoned)
        status = FLINT_REDIS_NOT_FOUND;
    else if (task->state == SLOT_DONE) {
        result->status = (unsigned)task->status;
        result->data = task->result;
        result->length = task->result_length;
        connection->reply_bytes -= task->result_length;
        task->result = NULL;
        clear_slot(connection, task);
        status = FLINT_REDIS_OK;
    }
    pthread_mutex_unlock(&connection->lock);
    return status;
}

int flint_redis_abandon(flint_redis_connection *connection, uint64_t ticket)
{
    if (!connection)
        return FLINT_REDIS_ARGUMENT;
    pthread_mutex_lock(&connection->lock);
    operation *task = lookup(connection, ticket);
    const bool found = task != NULL;
    if (found) {
        if (task->state == SLOT_DONE)
            clear_slot(connection, task);
        else
            task->abandoned = true;
        signal_owner(connection);
    }
    pthread_mutex_unlock(&connection->lock);
    return found ? FLINT_REDIS_OK : FLINT_REDIS_NOT_FOUND;
}

void flint_redis_release_bytes(uint8_t *data)
{
    free(data);
}

static bool charge(const redisReadTask *task, size_t extra)
{
    flint_redis_connection *connection = task->privdata;
    if (!task->parent) {
        connection->parse_bytes = 0;
        if (!connection->awaiting && task->type != REDIS_REPLY_PUSH) {
            connection->parser_error = FLINT_REDIS_IO;
            return false;
        }
    }
    if (extra > MAX_REPLY - sizeof(redisReply)
        || extra + sizeof(redisReply) > MAX_REPLY - connection->parse_bytes) {
        connection->parser_error = FLINT_REDIS_EXHAUSTED;
        return false;
    }
    connection->parse_bytes += sizeof(redisReply) + extra;
    return true;
}

static void *make_string(const redisReadTask *task, char *text, size_t length)
{
    flint_redis_connection *connection = task->privdata;
    if (length >= MAX_REPLY || !charge(task, length + 1))
        return NULL;

    /* This cache connection never subscribes. Even pushes with subscription-like
       names go to the independent PUSH handler instead of consuming a ticket. */
    if (task->parent && task->parent->type == REDIS_REPLY_PUSH && task->idx == 0 && task->type == REDIS_REPLY_STRING) {
        char marker[] = "flint-push";
        return connection->objects->createString(task, marker, sizeof(marker) - 1);
    }
    return connection->objects->createString(task, text, length);
}

static void *make_array(const redisReadTask *task, size_t count)
{
    flint_redis_connection *connection = task->privdata;
    if (count > MAX_REPLY / sizeof(redisReply *)) {
        connection->parser_error = FLINT_REDIS_EXHAUSTED;
        return NULL;
    }
    return charge(task, count * sizeof(redisReply *)) ? connection->objects->createArray(task, count) : NULL;
}

static void *make_integer(const redisReadTask *task, long long value)
{
    flint_redis_connection *connection = task->privdata;
    return charge(task, 0) ? connection->objects->createInteger(task, value) : NULL;
}

static void *make_double(const redisReadTask *task, double value, char *text, size_t length)
{
    flint_redis_connection *connection = task->privdata;
    return length < MAX_REPLY && charge(task, length + 1)
        ? connection->objects->createDouble(task, value, text, length) : NULL;
}

static void *make_nil(const redisReadTask *task)
{
    flint_redis_connection *connection = task->privdata;
    return charge(task, 0) ? connection->objects->createNil(task) : NULL;
}

static void *make_boolean(const redisReadTask *task, int value)
{
    flint_redis_connection *connection = task->privdata;
    return charge(task, 0) ? connection->objects->createBool(task, value) : NULL;
}

static ssize_t read_bounded(redisContext *context, char *storage, size_t length)
{
    flint_redis_connection *connection = context->privdata;
    const size_t buffered = context->reader->len - context->reader->pos;
    if (buffered >= MAX_REPLY) {
        connection->parser_error = FLINT_REDIS_EXHAUSTED;
        context->err = REDIS_ERR_PROTOCOL;
        return -1;
    }
    const size_t remaining = MAX_REPLY - buffered;
    return connection->read_socket(context, storage, length < remaining ? length : remaining);
}

static void install_limits(flint_redis_connection *connection)
{
    redisContext *context = &connection->client->c;
    redisReader *reader = context->reader;
    connection->objects = reader->fn;
    connection->bounded = (redisReplyObjectFunctions){
        make_string, make_array, make_integer, make_double, make_nil, make_boolean, connection->objects->freeObject
    };
    reader->fn = &connection->bounded;
    reader->privdata = connection;
    reader->maxdepth = 32;
    reader->maxelements = MAX_REPLY / sizeof(redisReply *);
    context->privdata = connection;
    connection->io = *context->funcs;
    connection->read_socket = connection->io.read;
    connection->io.read = read_bounded;
    context->funcs = &connection->io;
}

static int reply_error(const redisReply *reply)
{
    if (reply && reply->type == REDIS_REPLY_ERROR) {
        if (strncasecmp(reply->str, "MOVED ", 6) == 0 || strncasecmp(reply->str, "ASK ", 4) == 0
            || strncasecmp(reply->str, "NOPROTO ", 8) == 0)
            return FLINT_REDIS_UNSUPPORTED;
        if (strncasecmp(reply->str, "NOAUTH ", 7) == 0 || strncasecmp(reply->str, "WRONGPASS ", 10) == 0
            || strncasecmp(reply->str, "NOPERM ", 7) == 0)
            return FLINT_REDIS_DENIED;
        return FLINT_REDIS_IO;
    }
    return FLINT_REDIS_OK;
}

static int connection_error(flint_redis_connection *connection)
{
    if (connection->parser_error)
        return connection->parser_error;
    redisContext *context = &connection->client->c;
    if (context->err == REDIS_ERR_OOM)
        return FLINT_REDIS_MEMORY;
    if (context->err == REDIS_ERR_TIMEOUT)
        return FLINT_REDIS_TIMEOUT;
    if (strstr(context->errstr, "depth") || strstr(context->errstr, "length out of range"))
        return FLINT_REDIS_EXHAUSTED;
    if (connection->tls_session && SSL_get_verify_result(connection->tls_session) != X509_V_OK)
        return FLINT_REDIS_DENIED;
    return FLINT_REDIS_IO;
}

static void fail_connection(flint_redis_connection *connection, int failure)
{
    pthread_mutex_lock(&connection->lock);
    if (connection->state == STARTING || connection->state == READY) {
        connection->state = FAILED;
        connection->failure = failure;
        notify(connection);
    }
    pthread_mutex_unlock(&connection->lock);
}

static void ready_connection(flint_redis_connection *connection)
{
    pthread_mutex_lock(&connection->lock);
    if (connection->state == STARTING) {
        connection->state = READY;
        notify(connection);
    }
    pthread_mutex_unlock(&connection->lock);
}

static void connected_reply(redisAsyncContext *client, void *value, void *private_data)
{
    (void)private_data;
    flint_redis_connection *connection = client->data;
    --connection->awaiting;
    const redisReply *reply = value;
    if (!reply || reply->type != REDIS_REPLY_STATUS || reply->len != 2 || memcmp(reply->str, "OK", 2) != 0) {
        int status = reply_error(reply);
        fail_connection(connection, status ? status : FLINT_REDIS_IO);
        return;
    }
    ready_connection(connection);
}

static bool speaks_resp3(const redisReply *reply)
{
    if (!reply || reply->type != REDIS_REPLY_MAP)
        return false;
    for (size_t i = 0; i + 1 < reply->elements; i += 2) {
        const redisReply *key = reply->element[i];
        const redisReply *value = reply->element[i + 1];
        if ((key->type == REDIS_REPLY_STRING || key->type == REDIS_REPLY_STATUS) && key->len == 5 && memcmp(key->str, "proto", 5) == 0)
            return value->type == REDIS_REPLY_INTEGER && value->integer == 3;
    }
    return false;
}

static void hello_reply(redisAsyncContext *client, void *value, void *private_data)
{
    (void)private_data;
    flint_redis_connection *connection = client->data;
    --connection->awaiting;
    const redisReply *reply = value;
    if (!speaks_resp3(reply)) {
        int status = reply_error(reply);
        if (!status)
            status = reply ? FLINT_REDIS_UNSUPPORTED : connection_error(connection);
        fail_connection(connection, status);
        return;
    }
    if (!connection->address.database) {
        ready_connection(connection);
        return;
    }
    char number[6];
    const int length = snprintf(number, sizeof(number), "%u", (unsigned)connection->address.database);
    const char *args[] = {"SELECT", number};
    const size_t lengths[] = {6, (size_t)length};
    if (redisAsyncCommandArgv(client, connected_reply, NULL, 2, args, lengths) != REDIS_OK) {
        fail_connection(connection, connection_error(connection));
        return;
    }
    ++connection->awaiting;
}

static void on_connect(const redisAsyncContext *client, int status)
{
    flint_redis_connection *connection = client->data;
    if (status != REDIS_OK)
        fail_connection(connection, connection_error(connection));
}

static void on_disconnect(const redisAsyncContext *client, int status)
{
    flint_redis_connection *connection = client->data;
    if (status != REDIS_OK)
        fail_connection(connection, connection_error(connection));
}

static void on_push(redisAsyncContext *client, void *value)
{
    (void)value;
    flint_redis_connection *connection = client->data;
    atomic_fetch_add_explicit(&connection->pushes, 1, memory_order_relaxed);
}

uint64_t flint_redis_pushes(flint_redis_connection *connection)
{
    return connection ? atomic_load_explicit(&connection->pushes, memory_order_relaxed) : 0;
}

static void add_read(void *data) { ((flint_redis_connection *)data)->interest |= EVENT_READ; }
static void del_read(void *data) { ((flint_redis_connection *)data)->interest &= ~EVENT_READ; }
static void add_write(void *data) { ((flint_redis_connection *)data)->interest |= EVENT_WRITE; }
static void del_write(void *data) { ((flint_redis_connection *)data)->interest &= ~EVENT_WRITE; }

static void clean_events(void *data)
{
    flint_redis_connection *connection = data;
    connection->interest = 0;
    connection->timer_pending = false;
}

static void schedule_timer(void *data, struct timeval time)
{
    flint_redis_connection *connection = data;
    connection->timer_pending = time.tv_sec || time.tv_usec;
    if (connection->timer_pending)
        connection->timer = time_ms() + (uint64_t)time.tv_sec * 1000 + ((unsigned)time.tv_usec + 999) / 1000;
}

static int queue_hello(flint_redis_connection *connection)
{
    endpoint *address = &connection->address;
    const char *args[] = {"HELLO", "3", "AUTH", address->user, address->password};
    const size_t lengths[] = {5, 1, 4, address->user_length, address->password_length};
    const int result = redisAsyncCommandArgv(connection->client, hello_reply, NULL,
                                              address->authenticated ? 5 : 2, args, lengths);
    OPENSSL_cleanse(address->user, sizeof(address->user));
    OPENSSL_cleanse(address->password, sizeof(address->password));
    if (result != REDIS_OK)
        return connection_error(connection);
    ++connection->awaiting;
    return FLINT_REDIS_OK;
}

static int configure_tls(flint_redis_connection *connection)
{
    const endpoint *address = &connection->address;
    connection->tls_context = SSL_CTX_new(TLS_client_method());
    if (!connection->tls_context)
        return FLINT_REDIS_MEMORY;
    SSL_CTX_set_verify(connection->tls_context, SSL_VERIFY_PEER, NULL);
    const int trust = connection->ca_file
        ? SSL_CTX_load_verify_locations(connection->tls_context, connection->ca_file, NULL)
        : SSL_CTX_set_default_verify_paths(connection->tls_context);
    if (trust != 1)
        return FLINT_REDIS_DENIED;

    SSL *session = SSL_new(connection->tls_context);
    if (!session)
        return FLINT_REDIS_MEMORY;
    const bool named = address->ip_literal
        ? X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(session), address->host) == 1
        : SSL_set1_host(session, address->host) == 1 && SSL_set_tlsext_host_name(session, address->host) == 1;
    if (!named || redisInitiateSSL(&connection->client->c, session) != REDIS_OK) {
        SSL_free(session);
        return FLINT_REDIS_DENIED;
    }
    /* Hiredis owns the session. This alias is valid until redisAsyncFree and is
       used only on the owner to classify asynchronous verification failures. */
    connection->tls_session = session;
    return FLINT_REDIS_OK;
}

int flint_redis_attach(flint_redis_connection *connection)
{
    if (!connection || connection->owner_known || !connection->address.dial[0])
        return FLINT_REDIS_ARGUMENT;
    if (atomic_load_explicit(&connection->stop, memory_order_acquire))
        return FLINT_REDIS_CANCELLED;
    connection->owner = pthread_self();
    connection->owner_known = true;
    sigset_t blocked;
    if (sigemptyset(&blocked) != 0 || sigaddset(&blocked, SIGPIPE) != 0
            || pthread_sigmask(SIG_BLOCK, &blocked, &connection->previous_mask) != 0)
        return FLINT_REDIS_IO;
    connection->pipe_mask_saved = true;

    const struct timeval connect_limit = {.tv_sec = 5};
    const struct timeval command_limit = {.tv_sec = 10};
    redisOptions options = {0};
    options.options = REDIS_OPT_NONBLOCK | REDIS_OPT_NOAUTOFREE | REDIS_OPT_PREFER_IP_UNSPEC;
    options.connect_timeout = &connect_limit;
    options.command_timeout = &command_limit;
    REDIS_OPTIONS_SET_TCP(&options, connection->address.dial, connection->address.port);
    connection->client = redisAsyncConnectWithOptions(&options);
    if (!connection->client)
        return FLINT_REDIS_MEMORY;
    if (connection->client->err)
        return connection_error(connection);
#if defined(__APPLE__)
    /* Darwin raises SIGPIPE at the process, so the thread mask above cannot contain it. The socket
       reports EPIPE instead (ADR-024). */
    const int no_sigpipe = 1;
    if (setsockopt(connection->client->c.fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe)) != 0)
        return FLINT_REDIS_IO;
#endif
    if (connection->address.tls) {
        const int configured = configure_tls(connection);
        if (configured)
            return configured;
    }

    redisAsyncContext *client = connection->client;
    client->data = connection;
    client->ev.data = connection;
    client->ev.addRead = add_read;
    client->ev.delRead = del_read;
    client->ev.addWrite = add_write;
    client->ev.delWrite = del_write;
    client->ev.cleanup = clean_events;
    client->ev.scheduleTimer = schedule_timer;
    install_limits(connection);
    redisAsyncSetPushCallback(client, on_push);
    if (redisAsyncSetConnectCallback(client, on_connect) != REDIS_OK
            || redisAsyncSetDisconnectCallback(client, on_disconnect) != REDIS_OK)
        return FLINT_REDIS_IO;
    return queue_hello(connection);
}

static void complete_operation(flint_redis_connection *connection, operation *task, int status,
                               const char *data, size_t length)
{
    pthread_mutex_lock(&connection->lock);
    if (task->abandoned || atomic_load_explicit(&connection->stop, memory_order_relaxed)) {
        clear_slot(connection, task);
    } else {
        if (!status && length > MAX_PENDING_BYTES - connection->reply_bytes)
            status = FLINT_REDIS_EXHAUSTED;
        if (!status && length) {
            task->result = malloc(length);
            if (task->result) {
                memcpy(task->result, data, length);
                task->result_length = length;
                connection->reply_bytes += length;
            } else {
                status = FLINT_REDIS_MEMORY;
            }
        }
        task->state = SLOT_DONE;
        task->status = status;
    }
    notify(connection);
    pthread_mutex_unlock(&connection->lock);
}

static bool is_abandoned(flint_redis_connection *connection, const operation *task)
{
    pthread_mutex_lock(&connection->lock);
    const bool result = task->abandoned || atomic_load_explicit(&connection->stop, memory_order_relaxed);
    pthread_mutex_unlock(&connection->lock);
    return result;
}

static int sends(flint_redis_connection *connection, redisCallbackFn *callback, operation *task,
                 int count, const char **args, const size_t *lengths)
{
    if (redisAsyncCommandArgv(connection->client, callback, task, count, args, lengths) != REDIS_OK)
        return connection_error(connection);
    ++connection->awaiting;
    return FLINT_REDIS_OK;
}

static void operation_reply(redisAsyncContext *client, void *value, void *privdata);

static int next_scan(flint_redis_connection *connection)
{
    if (connection->scan_pages == MAX_SCAN_PAGES)
        return FLINT_REDIS_EXHAUSTED;
    ++connection->scan_pages;
    connection->scan_stage = SCANNING;
    char match[MAX_NAMESPACE + 8];
    memcpy(match, connection->prefix, connection->prefix_length);
    match[connection->prefix_length] = '*';
    const char *args[] = {"SCAN", connection->cursor, "MATCH", match, "COUNT", "64"};
    const size_t lengths[] = {4, strlen(connection->cursor), 5, connection->prefix_length + 1, 5, 2};
    return sends(connection, operation_reply, connection->clear, 6, args, lengths);
}

static bool key_in_namespace(flint_redis_connection *connection, const redisReply *key)
{
    return key->type == REDIS_REPLY_STRING && key->len >= connection->prefix_length
        && memcmp(key->str, connection->prefix, connection->prefix_length) == 0;
}

static int checked_scan_result(flint_redis_connection *connection, const redisReply *reply, bool *finished)
{
    if (reply->type != REDIS_REPLY_ARRAY || reply->elements != 2)
        return FLINT_REDIS_IO;
    const redisReply *cursor = reply->element[0];
    const redisReply *keys = reply->element[1];
    uint64_t number;
    if (cursor->type != REDIS_REPLY_STRING || cursor->len >= sizeof(connection->cursor)
        || !parse_uint(cursor->str, cursor->len, UINT64_MAX, &number) || keys->type != REDIS_REPLY_ARRAY)
        return FLINT_REDIS_IO;
    snprintf(connection->cursor, sizeof(connection->cursor), "%" PRIu64, number);
    if (keys->elements > MAX_SCAN_ENTRIES)
        return FLINT_REDIS_EXHAUSTED;
    if (!keys->elements) {
        *finished = number == 0;
        return *finished ? FLINT_REDIS_OK : next_scan(connection);
    }

    const char *args[MAX_SCAN_ENTRIES + 1];
    size_t lengths[MAX_SCAN_ENTRIES + 1];
    args[0] = "DEL";
    lengths[0] = 3;
    for (size_t i = 0; i < keys->elements; ++i) {
        const redisReply *key = keys->element[i];
        if (!key_in_namespace(connection, key))
            return FLINT_REDIS_IO;
        args[i + 1] = key->str;
        lengths[i + 1] = key->len;
    }
    connection->scan_stage = DELETING;
    return sends(connection, operation_reply, connection->clear, (int)keys->elements + 1, args, lengths);
}

static int advance_clear(flint_redis_connection *connection, const redisReply *reply, bool *finished)
{
    if (connection->scan_stage == SCANNING)
        return checked_scan_result(connection, reply, finished);
    if (reply->type != REDIS_REPLY_INTEGER || reply->integer < 0)
        return FLINT_REDIS_IO;
    *finished = strcmp(connection->cursor, "0") == 0;
    return *finished ? FLINT_REDIS_OK : next_scan(connection);
}

static void finish_clear(flint_redis_connection *connection, operation *task, int status)
{
    connection->clear = NULL;
    complete_operation(connection, task, status, NULL, 0);
}

static void operation_reply(redisAsyncContext *client, void *value, void *privdata)
{
    flint_redis_connection *connection = client->data;
    operation *task = privdata;
    --connection->awaiting;
    const redisReply *reply = value;
    int status = reply ? reply_error(reply) : connection->failure;
    if (task->kind == FLINT_REDIS_CLEAR) {
        bool finished = !reply || status;
        if (!finished && !is_abandoned(connection, task))
            status = advance_clear(connection, reply, &finished);
        else
            finished = true;
        if (finished || status)
            finish_clear(connection, task, status);
        return;
    }

    if (status || !reply) {
        complete_operation(connection, task, status ? status : FLINT_REDIS_IO, NULL, 0);
        return;
    }

    if (task->kind == FLINT_REDIS_GET) {
        if (reply->type == REDIS_REPLY_STRING) {
            if (reply->len <= connection->payload_limit)
                complete_operation(connection, task, FLINT_REDIS_OK, reply->str, reply->len);
            else
                complete_operation(connection, task, FLINT_REDIS_EXHAUSTED, NULL, 0);
        } else {
            status = reply->type == REDIS_REPLY_NIL ? FLINT_REDIS_NOT_FOUND : FLINT_REDIS_IO;
            complete_operation(connection, task, status, NULL, 0);
        }
        return;
    }

    if (task->kind == FLINT_REDIS_SET) {
        if (reply->type != REDIS_REPLY_STATUS || reply->len != 2 || memcmp(reply->str, "OK", 2) != 0)
            status = FLINT_REDIS_IO;
    } else if (task->kind == FLINT_REDIS_EVICT) {
        if (reply->type != REDIS_REPLY_INTEGER || reply->integer < 0)
            status = FLINT_REDIS_IO;
    }
    complete_operation(connection, task, status, NULL, 0);
}

static operation *next_job(flint_redis_connection *connection)
{
    pthread_mutex_lock(&connection->lock);
    operation *next = NULL;
    while (connection->queue_count && connection->state == READY) {
        operation *task = &connection->slots[connection->fifo[connection->queue_head]];
        const size_t buffered = sdslen(connection->client->c.obuf);
        if (task->kind == FLINT_REDIS_CLEAR && connection->awaiting && !task->abandoned)
            break;
        if (task->wire_length > MAX_PENDING_BYTES - buffered && !task->abandoned)
            break;
        connection->queue_head = (connection->queue_head + 1) % MAX_PENDING;
        --connection->queue_count;
        if (task->abandoned) {
            clear_slot(connection, task);
        } else {
            task->state = SLOT_SENT;
            next = task;
            break;
        }
    }
    pthread_mutex_unlock(&connection->lock);
    return next;
}

static int dispatch(flint_redis_connection *connection)
{
    while (!connection->clear) {
        operation *task = next_job(connection);
        if (!task)
            break;
        if (task->kind == FLINT_REDIS_CLEAR) {
            connection->clear = task;
            connection->scan_pages = 0;
            memcpy(connection->cursor, "0", 2);
            const int outcome = next_scan(connection);
            if (outcome) {
                finish_clear(connection, task, outcome);
                return outcome;
            }
            break;
        }
        const int sent = redisAsyncFormattedCommand(connection->client, operation_reply, task,
                                                      task->wire, task->wire_length);
        pthread_mutex_lock(&connection->lock);
        redisFreeCommand(task->wire);
        task->wire = NULL;
        connection->wire_bytes -= task->wire_length;
        pthread_mutex_unlock(&connection->lock);
        if (sent != REDIS_OK)
            return connection_error(connection);
        ++connection->awaiting;
    }
    return FLINT_REDIS_OK;
}

static bool on_owner(const flint_redis_connection *connection)
{
    return connection && connection->owner_known && pthread_equal(connection->owner, pthread_self());
}

int flint_redis_watch_now(flint_redis_connection *connection, flint_redis_watch *out)
{
    if (!on_owner(connection) || !out || !connection->client)
        return FLINT_REDIS_CONFLICT;
    out->wake_fd = connection->wake_fd;
    out->socket_fd = connection->client->c.fd;
    out->events = connection->interest;
    return FLINT_REDIS_OK;
}

static int service_status(flint_redis_connection *connection)
{
    if (!on_owner(connection) || !connection->client)
        return FLINT_REDIS_CONFLICT;
    const int status = flint_redis_ready(connection);
    return status == FLINT_REDIS_WAITING ? FLINT_REDIS_OK : status;
}

static int advance(flint_redis_connection *connection)
{
    if (connection->client->c.err)
        return connection_error(connection);
    const int status = service_status(connection);
    if (status)
        return status;
    return dispatch(connection);
}

int flint_redis_pump(flint_redis_connection *connection)
{
    const int status = service_status(connection);
    if (status)
        return status;
#if defined(__APPLE__)
    flint_wake_drain(connection->wake_fd);
#else
    eventfd_t signals;
    while (eventfd_read(connection->wake_fd, &signals) < 0 && errno == EINTR) {
    }
#endif
    return advance(connection);
}

int flint_redis_readable(flint_redis_connection *connection)
{
    const int status = service_status(connection);
    if (status)
        return status;
    if (connection->interest & EVENT_READ)
        redisAsyncHandleRead(connection->client);
    return advance(connection);
}

int flint_redis_writable(flint_redis_connection *connection)
{
    const int status = service_status(connection);
    if (status)
        return status;
    if (connection->interest & EVENT_WRITE)
        redisAsyncHandleWrite(connection->client);
    return advance(connection);
}

int flint_redis_tick(flint_redis_connection *connection)
{
    const int status = service_status(connection);
    if (status)
        return status;
    if (connection->timer_pending && time_ms() >= connection->timer) {
        connection->timer_pending = false;
        redisAsyncHandleTimeout(connection->client);
    }
    return advance(connection);
}

void flint_redis_stop(flint_redis_connection *connection)
{
    if (!connection)
        return;
    pthread_mutex_lock(&connection->lock);
    atomic_store_explicit(&connection->stop, true, memory_order_release);
    connection->state = STOPPING;
    if (atomic_load_explicit(&connection->stopped, memory_order_relaxed)) {
        clear_all(connection);
        connection->state = STOPPED;
    }
    signal_owner(connection);
    notify(connection);
    pthread_mutex_unlock(&connection->lock);
}

int flint_redis_stopped(flint_redis_connection *connection)
{
    return !connection || atomic_load_explicit(&connection->stopped, memory_order_acquire);
}

static void retire_pending(flint_redis_connection *connection, int reason)
{
    for (unsigned i = 0; i < MAX_PENDING; ++i) {
        operation *task = &connection->slots[i];
        if (task->state != SLOT_SENT && task->state != SLOT_QUEUED)
            continue;
        if (task->abandoned) {
            clear_slot(connection, task);
            continue;
        }
        if (task->wire) {
            redisFreeCommand(task->wire);
            connection->wire_bytes -= task->wire_length;
            task->wire = NULL;
        }
        task->status = reason;
        task->state = SLOT_DONE;
    }
}

static void restore_pipe_mask(flint_redis_connection *connection)
{
    if (!connection->pipe_mask_saved || !on_owner(connection))
        return;
#if !defined(__APPLE__)
    if (!sigismember(&connection->previous_mask, SIGPIPE)) {
        sigset_t generated;
        const struct timespec immediate = {0};
        sigemptyset(&generated);
        sigaddset(&generated, SIGPIPE);
        while (sigtimedwait(&generated, NULL, &immediate) < 0 && errno == EINTR) {
        }
    }
#endif
    pthread_sigmask(SIG_SETMASK, &connection->previous_mask, NULL);
    connection->pipe_mask_saved = false;
}

void flint_redis_finish(flint_redis_connection *connection, int reason)
{
    if (!connection || flint_redis_stopped(connection))
        return;
    if (!reason || reason == FLINT_REDIS_WAITING)
        reason = FLINT_REDIS_IO;
    fail_connection(connection, reason);
    if (connection->client) {
        redisAsyncFree(connection->client);
        connection->client = NULL;
    }
    connection->tls_session = NULL;
    SSL_CTX_free(connection->tls_context);
    connection->tls_context = NULL;
    restore_pipe_mask(connection);
    free(connection->ca_file);
    connection->ca_file = NULL;
    OPENSSL_cleanse(connection->address.user, sizeof(connection->address.user));
    OPENSSL_cleanse(connection->address.password, sizeof(connection->address.password));

    pthread_mutex_lock(&connection->lock);
    if (connection->wake_fd >= 0) {
#if defined(__APPLE__)
        flint_wake_close(connection->wake_fd, connection->wake_writer);
        connection->wake_writer = -1;
#else
        close(connection->wake_fd);
#endif
        connection->wake_fd = -1;
    }
    if (atomic_load_explicit(&connection->stop, memory_order_relaxed)) {
        clear_all(connection);
        connection->state = STOPPED;
    } else if (connection->slots) {
        retire_pending(connection, reason);
    }
    atomic_store_explicit(&connection->stopped, true, memory_order_release);
    notify(connection);
    pthread_mutex_unlock(&connection->lock);
}

flint_redis_connection *flint_redis_new(const char *host, uint16_t port, int tls)
{
    if (!host || !port)
        return NULL;
    char url[MAX_URL + 1];
    const bool v6 = strchr(host, ':') != NULL;
    const int length = snprintf(url, sizeof(url), "redis%s://%s%s%s:%u",
                                tls ? "s" : "", v6 ? "[" : "", host, v6 ? "]" : "", (unsigned)port);
    if (length <= 0 || (size_t)length >= sizeof(url))
        return NULL;
    flint_redis_connection *result = NULL;
    const flint_redis_options options = {url, (size_t)length, "default", 7, NULL, 0, MAX_PENDING_BYTES};
    if (flint_redis_create(&options, &result))
        return NULL;
    if (flint_redis_resolve(result) || flint_redis_attach(result)) {
        flint_redis_free(result);
        return NULL;
    }
    return result;
}

void flint_redis_free(flint_redis_connection *connection)
{
    if (!connection)
        return;
    flint_redis_stop(connection);
    flint_redis_finish(connection, FLINT_REDIS_CANCELLED);
    pthread_cond_destroy(&connection->changed);
    pthread_mutex_destroy(&connection->lock);
    free(connection->ca_file);
    OPENSSL_cleanse(&connection->address, sizeof(connection->address));
    free(connection);
}

#endif
