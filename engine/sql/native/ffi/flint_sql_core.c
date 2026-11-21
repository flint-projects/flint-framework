#define _POSIX_C_SOURCE 200809L
#include "flint_sql_private.h"

#if defined(__linux__) && (defined(FLINT_HAS_SQLITE) || defined(FLINT_HAS_LIBPQ))

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { MAX_POOLS = 64, MAX_CONNECTIONS = 16, MAX_WAITERS = 256, MAX_PREPARED = 128 };
enum { DRIVER_POSTGRES, DRIVER_SQLITE };

typedef struct {
    void *native;
    flint_sql_operation *active;
    uint64_t lease;
    uint64_t row;
    uint32_t columns;
    int transaction;
    int retired;
    int retiring;
    int dirty;
} connection_slot;

typedef struct {
    char *address;
    uint64_t identity;
    uint64_t tickets[MAX_WAITERS];
    connection_slot connections[MAX_CONNECTIONS];
    unsigned capacity;
    unsigned max_waiters;
    unsigned waiting;
    unsigned prepared;
    int driver;
    int closing;
} pool_slot;

static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static uint64_t sequence;
static pool_slot pools[MAX_POOLS];

static uint64_t next_identity(void)
{
    return sequence == UINT64_MAX ? 0 : ++sequence;
}

static pool_slot *pool_at(uint64_t slot, uint64_t generation)
{
    if (!slot || slot > MAX_POOLS || !generation || pools[slot - 1].identity != generation)
        return NULL;
    return &pools[slot - 1];
}

static connection_slot *connection_at(uint64_t slot, pool_slot **owner)
{
    if (!slot || slot > MAX_POOLS * MAX_CONNECTIONS)
        return NULL;
    pool_slot *pool = &pools[(slot - 1) / MAX_CONNECTIONS];
    if (!pool->identity)
        return NULL;
    *owner = pool;
    return &pool->connections[(slot - 1) % MAX_CONNECTIONS];
}

static int backend_available(int driver)
{
#ifdef FLINT_HAS_SQLITE
    if (driver == DRIVER_SQLITE)
        return flint_sqlite_available();
#endif
#ifdef FLINT_HAS_LIBPQ
    if (driver == DRIVER_POSTGRES)
        return flint_pg_available();
#endif
    return 0;
}

int flint_sql_pool_open(int driver, const char *address, size_t length, unsigned capacity,
                        unsigned waiters, unsigned prepared, uint64_t *slot, uint64_t *identity)
{
    if (!capacity || capacity > MAX_CONNECTIONS || waiters > MAX_WAITERS || prepared > MAX_PREPARED ||
        !address || !length || length > INT_MAX || memchr(address, 0, length) ||
        (driver != DRIVER_SQLITE && driver != DRIVER_POSTGRES))
        return FLINT_SQL_INVALID;
    if (!backend_available(driver))
        return FLINT_SQL_UNSUPPORTED;
    size_t bytes = driver == DRIVER_SQLITE && length == 8 && !memcmp(address, ":memory:", 8)
                   ? 80 : length + 1;
    char *copy = malloc(bytes);
    if (!copy)
        return FLINT_SQL_NOMEM;
    memcpy(copy, address, length);
    copy[length] = 0;

    pthread_mutex_lock(&gate);
    for (size_t index = 0; index < MAX_POOLS; ++index) {
        pool_slot *pool = &pools[index];
        if (pool->identity)
            continue;
        uint64_t generation = next_identity();
        if (!generation)
            break;
        if (bytes != length + 1)
            snprintf(copy, bytes, "file:flint-sql-%llu?mode=memory&cache=shared",
                     (unsigned long long)generation);
        pool->address = copy;
        pool->identity = generation;
        pool->capacity = capacity;
        pool->max_waiters = waiters;
        pool->prepared = prepared;
        pool->driver = driver;
        *slot = index + 1;
        *identity = generation;
        pthread_mutex_unlock(&gate);
        return FLINT_SQL_OK;
    }
    pthread_mutex_unlock(&gate);
    free(copy);
    return FLINT_SQL_EXHAUSTED;
}

static void remove_ticket(pool_slot *pool, uint64_t ticket)
{
    for (unsigned index = 0; index < pool->waiting; ++index) {
        if (pool->tickets[index] == ticket) {
            --pool->waiting;
            memmove(&pool->tickets[index], &pool->tickets[index + 1],
                    (pool->waiting - index) * sizeof(pool->tickets[0]));
            break;
        }
    }
}

int flint_sql_pool_acquire(uint64_t slot, uint64_t identity, uint64_t *ticket,
                           uint64_t *lease_slot, uint64_t *lease_identity)
{
    pthread_mutex_lock(&gate);
    pool_slot *pool = pool_at(slot, identity);
    int status = FLINT_SQL_UNAVAILABLE;
    if (pool && !pool->closing) {
        status = FLINT_SQL_EXHAUSTED;
        if (!pool->waiting || pool->tickets[0] == *ticket) {
            for (unsigned index = 0; index < pool->capacity; ++index) {
                connection_slot *connection = &pool->connections[index];
                if (connection->lease || connection->retiring)
                    continue;
                uint64_t lease = next_identity();
                if (lease) {
                    connection->lease = lease;
                    *lease_slot = (slot - 1) * MAX_CONNECTIONS + index + 1;
                    *lease_identity = lease;
                    remove_ticket(pool, *ticket);
                    *ticket = 0;
                    status = FLINT_SQL_OK;
                }
                pthread_mutex_unlock(&gate);
                return status;
            }
        }
        if (*ticket) {
            status = FLINT_SQL_CONFLICT;
        } else if (pool->waiting < pool->max_waiters) {
            *ticket = next_identity();
            if (*ticket) {
                pool->tickets[pool->waiting++] = *ticket;
                status = FLINT_SQL_CONFLICT;
            }
        }
    }
    pthread_mutex_unlock(&gate);
    return status;
}

void flint_sql_pool_withdraw(uint64_t slot, uint64_t identity, uint64_t ticket)
{
    pthread_mutex_lock(&gate);
    pool_slot *pool = pool_at(slot, identity);
    if (pool && ticket)
        remove_ticket(pool, ticket);
    pthread_mutex_unlock(&gate);
}

void flint_sql_retired(flint_sql_retirement receipt)
{
    if (!receipt.slot)
        return;
    pthread_mutex_lock(&gate);
    pool_slot *owner = NULL;
    connection_slot *connection = connection_at(receipt.slot, &owner);
    if (connection && owner->identity == receipt.pool_identity)
        connection->retiring = 0;
    pthread_mutex_unlock(&gate);
}

static void close_native(int driver, void *native, flint_sql_retirement receipt)
{
    if (!native)
        return;
#ifdef FLINT_HAS_SQLITE
    if (driver == DRIVER_SQLITE)
        flint_sqlite_retire(native, receipt);
#endif
#ifdef FLINT_HAS_LIBPQ
    if (driver == DRIVER_POSTGRES)
        flint_pg_retire(native, receipt);
#endif
}

int flint_sql_pool_close(uint64_t slot, uint64_t identity)
{
    void *native[MAX_CONNECTIONS] = {0};
    pthread_mutex_lock(&gate);
    pool_slot *pool = pool_at(slot, identity);
    if (!pool) {
        pthread_mutex_unlock(&gate);
        return FLINT_SQL_NOT_FOUND;
    }
    pool->closing = 1;
    for (unsigned index = 0; index < pool->capacity; ++index) {
        if (pool->connections[index].lease) {
            pthread_mutex_unlock(&gate);
            return FLINT_SQL_CONFLICT;
        }
    }

    int pending = 0;
    for (unsigned index = 0; index < pool->capacity; ++index) {
        connection_slot *connection = &pool->connections[index];
        native[index] = connection->native;
        connection->native = NULL;
        if (native[index])
            connection->retiring = 1;
        if (connection->retiring)
            pending = 1;
    }

    if (!pending) {
        char *address = pool->address;
        memset(pool, 0, sizeof(*pool));
        pthread_mutex_unlock(&gate);
        free(address);
        return FLINT_SQL_OK;
    }
    int driver = pool->driver;
    pthread_mutex_unlock(&gate);
    for (unsigned index = 0; index < MAX_CONNECTIONS; ++index) {
        const flint_sql_retirement receipt = {(slot - 1) * MAX_CONNECTIONS + index + 1, identity};
        close_native(driver, native[index], receipt);
    }
    return FLINT_SQL_CONFLICT;
}

int flint_sql_pool_release(uint64_t slot, uint64_t identity,
                           uint64_t lease_slot, uint64_t lease_identity)
{
    pthread_mutex_lock(&gate);
    pool_slot *owner = NULL;
    connection_slot *connection = connection_at(lease_slot, &owner);
    if (!connection || !lease_identity || connection->lease != lease_identity ||
        owner != pool_at(slot, identity)) {
        pthread_mutex_unlock(&gate);
        return FLINT_SQL_NOT_FOUND;
    }
    if (connection->active) {
        pthread_mutex_unlock(&gate);
        return FLINT_SQL_CONFLICT;
    }
    void *native = NULL;
    int driver = owner->driver;
    if (connection->retired || connection->transaction || connection->dirty) {
        native = connection->native;
        connection->native = NULL;
        if (native)
            connection->retiring = 1;
    }
    const flint_sql_retirement receipt = {lease_slot, identity};
    connection->lease = 0;
    connection->retired = 0;
    connection->transaction = 0;
    connection->dirty = 0;
    pthread_mutex_unlock(&gate);
    close_native(driver, native, receipt);
    return FLINT_SQL_OK;
}

int flint_sql_pool_dirty(uint64_t slot, uint64_t identity, uint64_t lease_slot, uint64_t lease_identity)
{
    pthread_mutex_lock(&gate);
    pool_slot *owner = NULL;
    connection_slot *connection = connection_at(lease_slot, &owner);
    int dirty = connection && lease_identity && connection->lease == lease_identity &&
                owner == pool_at(slot, identity) && !connection->active && !connection->retired &&
                connection->dirty;
    pthread_mutex_unlock(&gate);
    return dirty;
}

static int update_lease(uint64_t slot, uint64_t identity, int action)
{
    pthread_mutex_lock(&gate);
    pool_slot *owner = NULL;
    connection_slot *connection = connection_at(slot, &owner);
    int status = FLINT_SQL_NOT_FOUND;
    if (connection && identity && connection->lease == identity) {
        status = FLINT_SQL_OK;
        if (action == 0)
            connection->retired = 1;
        else if (action == 1 && connection->transaction)
            status = FLINT_SQL_CONFLICT;
        else
            connection->transaction = action == 1;
    }
    pthread_mutex_unlock(&gate);
    return status;
}

void flint_sql_pool_retire(uint64_t slot, uint64_t identity)
{
    (void)update_lease(slot, identity, 0);
}

int flint_sql_pool_claim_transaction(uint64_t slot, uint64_t identity)
{
    return update_lease(slot, identity, 1);
}

void flint_sql_pool_finish_transaction(uint64_t slot, uint64_t identity)
{
    (void)update_lease(slot, identity, 2);
}

int flint_sql_utf8(const void *data, size_t length)
{
    const unsigned char *text = data;
    size_t index = 0;
    while (index != length) {
        unsigned lead = text[index++];
        if (lead < 0x80)
            continue;
        unsigned width;
        uint32_t scalar;
        uint32_t minimum;
        if (lead >= 0xc2 && lead <= 0xdf) {
            width = 1; scalar = lead & 0x1f; minimum = 0x80;
        } else if (lead >= 0xe0 && lead <= 0xef) {
            width = 2; scalar = lead & 0xf; minimum = 0x800;
        } else if (lead >= 0xf0 && lead <= 0xf4) {
            width = 3; scalar = lead & 7; minimum = 0x10000;
        } else {
            return 0;
        }
        if (length - index < width)
            return 0;
        while (width--) {
            unsigned trail = text[index++];
            if ((trail & 0xc0) != 0x80)
                return 0;
            scalar = (scalar << 6) | (trail & 0x3f);
        }
        if (scalar < minimum || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff))
            return 0;
    }
    return 1;
}

flint_sql_operation *flint_sql_operation_new(const char *sql, size_t length,
                                             size_t count, int rows, int64_t deadline, int *status)
{
    *status = FLINT_SQL_INVALID;
    if (!sql || !length || length > INT_MAX || count > UINT16_MAX ||
        memchr(sql, 0, length) || !flint_sql_utf8(sql, length))
        return NULL;
    *status = FLINT_SQL_NOMEM;
    flint_sql_operation *operation = calloc(1, sizeof(*operation));
    if (!operation)
        return NULL;
    operation->text = malloc(length + 1);
    operation->params = count ? calloc(count, sizeof(operation->params[0])) : NULL;
    if (!operation->text || (count && !operation->params)) {
        flint_sql_operation_free(operation);
        return NULL;
    }
    memcpy(operation->text, sql, length);
    operation->text[length] = 0;
    operation->parameter_count = count;
    operation->deadline = deadline;
    operation->rows = rows;
    operation->reusable = 1;
    atomic_init(&operation->cancelled, 0);
    *status = FLINT_SQL_OK;
    return operation;
}

flint_sql_operation *flint_sql_operation_new_script(const char *sql, size_t length,
                                                    int64_t deadline, int *status)
{
    flint_sql_operation *operation = flint_sql_operation_new(sql, length, 0, 0, deadline, status);
    if (operation)
        operation->script = 1;
    return operation;
}

int flint_sql_operation_bind(flint_sql_operation *operation, size_t index, int kind,
                              int64_t integer, double floating, const void *data, size_t length)
{
    if (!operation || index >= operation->parameter_count ||
        kind < FLINT_SQL_NULL || kind > FLINT_SQL_BYTES || length > INT_MAX ||
        (length && !data) || (kind < FLINT_SQL_TEXT && length) ||
        (kind == FLINT_SQL_BOOL && integer != 0 && integer != 1) ||
        (kind == FLINT_SQL_FLOAT && !isfinite(floating)) ||
        (kind == FLINT_SQL_TEXT && !flint_sql_utf8(data, length)))
        return FLINT_SQL_INVALID;
    flint_sql_parameter *parameter = &operation->params[index];
    if (parameter->data)
        return FLINT_SQL_CONFLICT;
    if (kind >= FLINT_SQL_TEXT) {
        void *owned = malloc(length ? length : 1);
        if (!owned)
            return FLINT_SQL_NOMEM;
        if (length)
            memcpy(owned, data, length);
        parameter->data = owned;
    }
    parameter->cell = (flint_sql_cell){kind, integer, floating, length};
    return FLINT_SQL_OK;
}

void flint_sql_operation_free(flint_sql_operation *operation)
{
    if (!operation)
        return;
    for (size_t index = 0; index < operation->parameter_count; ++index)
        free((void *)operation->params[index].data);
    free(operation->params);
    free(operation->text);
    free(operation);
}

static void *open_native(const pool_slot *pool)
{
#ifdef FLINT_HAS_SQLITE
    if (pool->driver == DRIVER_SQLITE)
        return flint_sqlite_worker(pool->address, pool->prepared);
#endif
#ifdef FLINT_HAS_LIBPQ
    if (pool->driver == DRIVER_POSTGRES) {
        const flint_sql_backend_options options = {pool->address, pool->prepared};
        return flint_pg_open(&options);
    }
#endif
    return NULL;
}

int flint_sql_operation_start(flint_sql_operation *operation, uint64_t slot, uint64_t identity)
{
    pthread_mutex_lock(&gate);
    pool_slot *owner = NULL;
    connection_slot *connection = connection_at(slot, &owner);
    if (!connection || !identity || connection->lease != identity) {
        pthread_mutex_unlock(&gate);
        return FLINT_SQL_NOT_FOUND;
    }
    if (connection->active || connection->retired) {
        int status = connection->retired ? FLINT_SQL_UNAVAILABLE : FLINT_SQL_CONFLICT;
        pthread_mutex_unlock(&gate);
        return status;
    }
    connection->active = operation;
    operation->lease_slot = slot;
    operation->lease_identity = identity;
    pthread_mutex_unlock(&gate);

    if (!connection->native)
        connection->native = open_native(owner);
    operation->connection = connection->native;
    operation->driver = owner->driver;
    if (!operation->connection) {
        operation->reusable = 0;
        operation->status = FLINT_SQL_UNAVAILABLE;
    }
#ifdef FLINT_HAS_SQLITE
    else if (operation->driver == DRIVER_SQLITE) {
        const int status = flint_sqlite_begin(operation->connection, operation);
        if (status != FLINT_SQL_OK) {
            operation->status = status;
            operation->reusable = 0;
        } else
            operation->started = 1;
    }
#endif
    else
        operation->started = 1;
    return FLINT_SQL_OK;
}

int flint_sql_operation_drive(flint_sql_operation *operation, int *fd, unsigned *interest)
{
    *fd = -1;
    *interest = 0;
    if (!operation->started && operation->status != FLINT_SQL_OK)
        return FLINT_SQL_COMPLETE;
#ifdef FLINT_HAS_SQLITE
    if (operation->driver == DRIVER_SQLITE)
        return flint_sqlite_drive(operation->connection, operation, fd, interest);
#endif
#ifdef FLINT_HAS_LIBPQ
    if (operation->driver == DRIVER_POSTGRES)
        return flint_pg_drive(operation->connection, operation, fd, interest);
#endif
    return FLINT_SQL_COMPLETE;
}

void flint_sql_operation_cancel(flint_sql_operation *operation)
{
    atomic_store(&operation->cancelled, 1);
#ifdef FLINT_HAS_SQLITE
    if (operation->driver == DRIVER_SQLITE && operation->connection)
        flint_sqlite_interrupt(operation->connection);
#endif
}

void flint_sql_operation_abort(flint_sql_operation *operation)
{
    pthread_mutex_lock(&gate);
    pool_slot *owner = NULL;
    connection_slot *connection = connection_at(operation->lease_slot, &owner);
    flint_sql_retirement receipt = {0};
    void *native = NULL;
    if (connection && connection->active == operation) {
        connection->active = NULL;
        connection->row = 0;
        connection->retired = 1;
        connection->dirty = 0;
        native = connection->native;
        connection->native = NULL;
        if (native) {
            receipt = (flint_sql_retirement){operation->lease_slot, owner->identity};
            connection->retiring = 1;
        }
    }
    pthread_mutex_unlock(&gate);

#ifdef FLINT_HAS_SQLITE
    if (operation->driver == DRIVER_SQLITE && native) {
        flint_sqlite_abandon(native, operation, receipt);
        return;
    }
#endif
#ifdef FLINT_HAS_LIBPQ
    if (operation->driver == DRIVER_POSTGRES)
        flint_pg_discard(operation);
#endif
    close_native(operation->driver, native, receipt);
    flint_sql_operation_free(operation);
}

static uint32_t row_columns(const flint_sql_operation *operation)
{
#ifdef FLINT_HAS_SQLITE
    if (operation->driver == DRIVER_SQLITE)
        return flint_sqlite_columns(operation);
#endif
#ifdef FLINT_HAS_LIBPQ
    if (operation->driver == DRIVER_POSTGRES)
        return flint_pg_columns(operation);
#endif
    return 0;
}

uint64_t flint_sql_operation_publish_row(flint_sql_operation *operation)
{
    pthread_mutex_lock(&gate);
    pool_slot *owner = NULL;
    connection_slot *connection = connection_at(operation->lease_slot, &owner);
    uint64_t row = 0;
    if (connection && connection->active == operation) {
        connection->columns = row_columns(operation);
        if (connection->columns)
            row = next_identity();
        connection->row = row;
    }
    pthread_mutex_unlock(&gate);
    return row;
}

void flint_sql_operation_next(flint_sql_operation *operation)
{
    pthread_mutex_lock(&gate);
    pool_slot *owner = NULL;
    connection_slot *connection = connection_at(operation->lease_slot, &owner);
    if (connection && connection->active == operation)
        connection->row = 0;
    pthread_mutex_unlock(&gate);
#ifdef FLINT_HAS_SQLITE
    if (operation->driver == DRIVER_SQLITE)
        flint_sqlite_next(operation->connection, operation);
#endif
#ifdef FLINT_HAS_LIBPQ
    if (operation->driver == DRIVER_POSTGRES)
        flint_pg_next(operation);
#endif
}

int flint_sql_operation_finish(flint_sql_operation *operation, uint64_t *affected)
{
    pthread_mutex_lock(&gate);
    pool_slot *owner = NULL;
    connection_slot *connection = connection_at(operation->lease_slot, &owner);
    if (!connection || connection->active != operation) {
        pthread_mutex_unlock(&gate);
        return FLINT_SQL_NOT_FOUND;
    }
    connection->row = 0;
    connection->active = NULL;
    connection->dirty = operation->dirty;
    if (!operation->reusable)
        connection->retired = 1;
    *affected = operation->affected;
    int status = operation->status;
    pthread_mutex_unlock(&gate);
    return status;
}

static int read_cell(uint64_t slot, uint64_t row, uint32_t index, flint_sql_cell *cell, const void **data)
{
    pool_slot *owner = NULL;
    connection_slot *connection = connection_at(slot, &owner);
    if (!connection || !row || row != connection->row || !connection->active)
        return FLINT_SQL_NOT_FOUND;
    if (index >= connection->columns)
        return FLINT_SQL_INVALID;
#ifdef FLINT_HAS_SQLITE
    if (owner->driver == DRIVER_SQLITE)
        return flint_sqlite_cell(connection->active, index, cell, data);
#endif
#ifdef FLINT_HAS_LIBPQ
    if (owner->driver == DRIVER_POSTGRES)
        return flint_pg_cell(connection->active, index, cell, data);
#endif
    return FLINT_SQL_UNSUPPORTED;
}

uint32_t flint_sql_row_columns(uint64_t slot, uint64_t generation)
{
    pthread_mutex_lock(&gate);
    pool_slot *owner = NULL;
    const connection_slot *connection = connection_at(slot, &owner);
    uint32_t count = connection && generation && connection->row == generation ? connection->columns : 0;
    pthread_mutex_unlock(&gate);
    return count;
}

int flint_sql_row_info(uint64_t slot, uint64_t row, uint32_t index, flint_sql_cell *output)
{
    const void *data = NULL;
    pthread_mutex_lock(&gate);
    int status = read_cell(slot, row, index, output, &data);
    pthread_mutex_unlock(&gate);
    return status;
}

int flint_sql_row_copy(uint64_t slot, uint64_t row, uint32_t index, void *output, size_t length)
{
    flint_sql_cell cell;
    const void *data = NULL;
    pthread_mutex_lock(&gate);
    int status = read_cell(slot, row, index, &cell, &data);
    if (status == FLINT_SQL_OK) {
        if (cell.kind < FLINT_SQL_TEXT || cell.length != length || (length && !output))
            status = FLINT_SQL_INVALID;
        else if (length)
            memcpy(output, data, length);
    }
    pthread_mutex_unlock(&gate);
    return status;
}

int flint_sql_poll(int fd, unsigned interest, unsigned millis)
{
    if (millis > INT_MAX)
        return FLINT_SQL_INVALID;
    struct pollfd watch = {fd, 0, 0};
    if (interest & FLINT_SQL_READ)
        watch.events |= POLLIN;
    if (interest & FLINT_SQL_WRITE)
        watch.events |= POLLOUT;
    int ready = poll(fd < 0 ? NULL : &watch, fd < 0 ? 0 : 1, (int)millis);
    return ready >= 0 || errno == EINTR ? FLINT_SQL_OK : FLINT_SQL_IO;
}

#endif
