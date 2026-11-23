#define _POSIX_C_SOURCE 200809L
#include "flint_sql_private.h"
#include "flint_clock.h"

#if (defined(__linux__) || defined(__APPLE__)) && defined(FLINT_HAS_SQLITE)

#include <errno.h>
#if defined(__linux__)
#include <linux/magic.h>
#endif
#include <math.h>
#include <pthread.h>
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#if defined(__APPLE__)
#include <sys/mount.h>
#include "flint_wake.h"
#else
#include <sys/eventfd.h>
#include <sys/vfs.h>
#endif
#include <time.h>
#include <unistd.h>

typedef struct {
    char *sql;
    sqlite3_stmt *statement;
    unsigned char *types;
    size_t count;
    uint64_t touched;
} cached_statement;

struct flint_sqlite_connection {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    char *path;
    sqlite3 *database;
    flint_sql_operation *pending;
    flint_sql_operation *orphan;
    flint_sql_retirement retirement;
    cached_statement *cache;
    uint64_t clock;
    unsigned capacity;
    unsigned progress;
    int wake;
#if defined(__APPLE__)
    int wake_writer;
#endif
    int flags;
    int closing;
    int startup;
    int running_script;
};

int flint_sqlite_available(void)
{
    return sqlite3_threadsafe() != 0 && sqlite3_libversion_number() == 3054001;
}

/* SQLSTATE for an extended result code, so JDBC-level translation sees what PostgreSQL would report. */
static const char *sqlite_state(int extended)
{
    switch (extended) {
    case SQLITE_CONSTRAINT_PRIMARYKEY: case SQLITE_CONSTRAINT_UNIQUE: return "23505";
    case SQLITE_CONSTRAINT_FOREIGNKEY: return "23503";
    case SQLITE_CONSTRAINT_NOTNULL: return "23502";
    case SQLITE_CONSTRAINT_CHECK: return "23514";
    default: break;
    }
    switch (extended & 0xff) {
    case SQLITE_CONSTRAINT: return "23000";
    case SQLITE_ERROR: return "42000";
    case SQLITE_BUSY: case SQLITE_LOCKED: return "40001";
    case SQLITE_READONLY: return "25006";
    case SQLITE_PERM: case SQLITE_AUTH: return "42501";
    case SQLITE_TOOBIG: return "22001";
    case SQLITE_MISMATCH: return "22005";
    case SQLITE_RANGE: return "07009";
    case SQLITE_FULL: return "53100";
    case SQLITE_NOMEM: return "53200";
    case SQLITE_CANTOPEN: return "08001";
    case SQLITE_INTERRUPT: return "57014";
    case SQLITE_IOERR: case SQLITE_CORRUPT: case SQLITE_NOTADB: return "58030";
    default: return "HY000";
    }
}

/* Record a failed prepare, bind or step while the connection's error state still describes it. */
static void note_sqlite(sqlite3 *database, flint_sql_operation *operation, int result)
{
    if (result == SQLITE_OK || result == SQLITE_DONE || result == SQLITE_ROW)
        return;
    int extended = sqlite3_extended_errcode(database);
    const char *message = sqlite3_errmsg(database);
    if ((extended & 0xff) != (result & 0xff)) {
        /* The connection's state belongs to another call; report the result itself. */
        extended = result;
        message = sqlite3_errstr(result);
    }
    flint_sql_note_failure(operation, sqlite_state(extended), extended, message);
}

static int sqlite_status(int result)
{
    switch (result & 0xff) {
    case SQLITE_OK: case SQLITE_ROW: case SQLITE_DONE: return FLINT_SQL_OK;
    case SQLITE_NOMEM: return FLINT_SQL_NOMEM;
    case SQLITE_INTERRUPT: return FLINT_SQL_CANCELLED;
    case SQLITE_BUSY: case SQLITE_LOCKED: case SQLITE_CONSTRAINT: return FLINT_SQL_CONFLICT;
    case SQLITE_RANGE: case SQLITE_MISMATCH: case SQLITE_ERROR: return FLINT_SQL_INVALID;
    case SQLITE_READONLY: case SQLITE_PERM: case SQLITE_AUTH: return FLINT_SQL_PERMISSION;
    case SQLITE_TOOBIG: case SQLITE_FULL: return FLINT_SQL_EXHAUSTED;
    case SQLITE_CANTOPEN: return FLINT_SQL_UNAVAILABLE;
    default: return FLINT_SQL_IO;
    }
}

static int interrupt_requested(void *input)
{
    flint_sql_operation *operation = input;
    if (atomic_load(&operation->cancelled))
        return 1;
    struct timespec now;
    if (clock_gettime(FLINT_DEADLINE_CLOCK, &now))
        return 1;
    return (int64_t)now.tv_sec * INT64_C(1000000000) + now.tv_nsec >= operation->deadline;
}

static int busy(void *input, int attempts)
{
    (void)attempts;
    if (interrupt_requested(input))
        return 0;
    struct timespec pause = {0, 1000000};
    nanosleep(&pause, NULL);
    return !interrupt_requested(input);
}

static int empty_tail(const char *tail)
{
    while (*tail) {
        if (*tail == ' ' || (*tail >= '\t' && *tail <= '\r') || *tail == ';')
            ++tail;
        else if (tail[0] == '-' && tail[1] == '-') {
            tail += 2;
            while (*tail && *tail != '\n')
                ++tail;
        } else if (tail[0] == '/' && tail[1] == '*') {
            const char *end = strstr(tail + 2, "*/");
            if (!end)
                return 0;
            tail = end + 2;
        } else
            return 0;
    }
    return 1;
}

static void evict(cached_statement *entry)
{
    sqlite3_finalize(entry->statement);
    free(entry->types);
    free(entry->sql);
    memset(entry, 0, sizeof(*entry));
}

static int same_types(const cached_statement *entry, const flint_sql_operation *operation)
{
    if (entry->count != operation->parameter_count)
        return 0;
    for (size_t index = 0; index < entry->count; ++index) {
        if (entry->types[index] != operation->params[index].cell.kind)
            return 0;
    }
    return 1;
}

static void store_prepared(flint_sqlite_connection *connection, cached_statement *entry,
                           sqlite3_stmt *statement, const flint_sql_operation *operation,
                           cached_statement **cached)
{
    char *sql = strdup(operation->text);
    size_t count = operation->parameter_count;
    unsigned char *types = count ? malloc(count) : NULL;
    if (!sql || (count && !types)) {
        free(sql);
        free(types);
        return;
    }
    for (size_t index = 0; index < count; ++index)
        types[index] = (unsigned char)operation->params[index].cell.kind;
    evict(entry);
    *entry = (cached_statement){sql, statement, types, count, ++connection->clock};
    *cached = entry;
}

static sqlite3_stmt *prepare(flint_sqlite_connection *connection, const flint_sql_operation *operation,
                              cached_statement **cached, int *status)
{
    cached_statement *oldest = NULL;
    for (unsigned index = 0; index < connection->capacity; ++index) {
        cached_statement *entry = &connection->cache[index];
        if (entry->sql && !strcmp(entry->sql, operation->text) && same_types(entry, operation)) {
            entry->touched = ++connection->clock;
            *cached = entry;
            return entry->statement;
        }
        if (!oldest || entry->touched < oldest->touched)
            oldest = entry;
    }

    const char *tail = NULL;
    sqlite3_stmt *statement = NULL;
    int result = sqlite3_prepare_v3(connection->database, operation->text, -1,
                    oldest ? SQLITE_PREPARE_PERSISTENT : 0, &statement, &tail);
    if (result != SQLITE_OK || !statement || !empty_tail(tail)) {
        *status = result == SQLITE_OK ? FLINT_SQL_INVALID : sqlite_status(result);
        sqlite3_finalize(statement);
        return NULL;
    }
    if (oldest)
        store_prepared(connection, oldest, statement, operation, cached);
    return statement;
}

static int bind(sqlite3_stmt *statement, int index, const flint_sql_parameter *parameter)
{
    const flint_sql_cell *cell = &parameter->cell;
    switch (cell->kind) {
    case FLINT_SQL_NULL:
        return sqlite3_bind_null(statement, index);
    case FLINT_SQL_BOOL: case FLINT_SQL_INT:
        return sqlite3_bind_int64(statement, index, cell->integer);
    case FLINT_SQL_FLOAT:
        return sqlite3_bind_double(statement, index, cell->floating);
    case FLINT_SQL_TEXT:
        return sqlite3_bind_text64(statement, index, parameter->data, cell->length, SQLITE_STATIC, SQLITE_UTF8);
    case FLINT_SQL_BYTES:
        return sqlite3_bind_blob64(statement, index, parameter->data, cell->length, SQLITE_STATIC);
    default:
        return SQLITE_MISMATCH;
    }
}

static int bind_all(sqlite3_stmt *statement, const flint_sql_operation *operation)
{
    if ((size_t)sqlite3_bind_parameter_count(statement) != operation->parameter_count)
        return SQLITE_RANGE;
    for (size_t index = 0; index < operation->parameter_count; ++index) {
        int result = bind(statement, (int)index + 1, &operation->params[index]);
        if (result != SQLITE_OK)
            return result;
    }
    return SQLITE_OK;
}

static void notify(flint_sqlite_connection *connection)
{
#if defined(__APPLE__)
    flint_wake_signal(connection->wake_writer);
#else
    uint64_t signal = 1;
    while (write(connection->wake, &signal, sizeof(signal)) < 0 && errno == EINTR) {}
#endif
}

typedef struct {
    flint_sql_cell cell;
    void *data;
    /* Owned by the statement, which outlives the published row. */
    const char *name;
    int status;
} sqlite_cell;

typedef struct {
    sqlite_cell *cells;
    uint32_t columns;
} sqlite_row;

static int sqlite_read_cell(sqlite3_stmt *statement, uint32_t index, flint_sql_cell *cell, const void **data);

static void dispose_row(sqlite_row *row)
{
    for (uint32_t index = 0; index < row->columns; ++index)
        free(row->cells[index].data);
    free(row->cells);
}

static int snapshot_row(sqlite3_stmt *statement, sqlite_row *row)
{
    row->columns = (uint32_t)sqlite3_column_count(statement);
    row->cells = calloc(row->columns, sizeof(row->cells[0]));
    if (!row->cells)
        return 0;
    for (uint32_t index = 0; index < row->columns; ++index) {
        sqlite_cell *entry = &row->cells[index];
        const void *bytes = NULL;
        entry->name = sqlite3_column_name(statement, (int)index);
        entry->status = sqlite_read_cell(statement, index, &entry->cell, &bytes);
        if (entry->status != FLINT_SQL_OK || !entry->cell.length)
            continue;
        entry->data = malloc(entry->cell.length);
        if (!entry->data) {
            dispose_row(row);
            return 0;
        }
        memcpy(entry->data, bytes, entry->cell.length);
    }
    return 1;
}

static int publish_row(flint_sqlite_connection *connection, flint_sql_operation *operation, sqlite3_stmt *statement)
{
    sqlite_row row;
    if (!snapshot_row(statement, &row))
        return SQLITE_NOMEM;
    pthread_mutex_lock(&connection->lock);
    if (connection->closing) {
        pthread_mutex_unlock(&connection->lock);
        dispose_row(&row);
        return SQLITE_INTERRUPT;
    }
    operation->row = &row;
    connection->progress = FLINT_SQL_ROW;
    notify(connection);
    while (connection->progress == FLINT_SQL_ROW)
        pthread_cond_wait(&connection->changed, &connection->lock);
    operation->row = NULL;
    pthread_mutex_unlock(&connection->lock);
    dispose_row(&row);
    return interrupt_requested(operation) ? SQLITE_INTERRUPT : SQLITE_OK;
}

static int step_rows(flint_sqlite_connection *connection, sqlite3_stmt *statement, flint_sql_operation *operation)
{
    sqlite3_int64 before = sqlite3_total_changes64(connection->database);
    for (;;) {
        if (interrupt_requested(operation))
            return SQLITE_INTERRUPT;
        int result = sqlite3_step(statement);
        if (result != SQLITE_ROW) {
            if (result == SQLITE_DONE && sqlite3_total_changes64(connection->database) != before)
                operation->affected = (uint64_t)sqlite3_changes64(connection->database);
            return result;
        }
        if (operation->rows) {
            int status = publish_row(connection, operation, statement);
            if (status != SQLITE_OK)
                return status;
        }
    }
}

static int step_script(flint_sqlite_connection *connection, flint_sql_operation *operation)
{
    const char *cursor = operation->text;
    connection->running_script = 1;
    int result = SQLITE_DONE;
    while (*cursor) {
        if (interrupt_requested(operation)) {
            result = SQLITE_INTERRUPT;
            break;
        }
        sqlite3_stmt *statement = NULL;
        const char *tail = NULL;
        result = sqlite3_prepare_v3(connection->database, cursor, -1, 0, &statement, &tail);
        if (result == SQLITE_OK) {
            if (!tail || tail <= cursor)
                result = SQLITE_ERROR;
            else if (!statement)
                result = SQLITE_DONE;
            else if (sqlite3_bind_parameter_count(statement) != 0)
                result = SQLITE_RANGE;
            else
                result = step_rows(connection, statement, operation);
        }
        note_sqlite(connection->database, operation, result);
        sqlite3_finalize(statement);
        if (result != SQLITE_DONE)
            break;
        cursor = tail;
    }
    connection->running_script = 0;
    return result;
}

static int step_statement(flint_sqlite_connection *connection, flint_sql_operation *operation)
{
    cached_statement *entry = NULL;
    int status = FLINT_SQL_OK;
    sqlite3_stmt *statement = prepare(connection, operation, &entry, &status);
    if (!statement) {
        if (sqlite3_errcode(connection->database) != SQLITE_OK)
            note_sqlite(connection->database, operation, sqlite3_errcode(connection->database));
        else
            flint_sql_note_failure(operation, "42000", SQLITE_ERROR, "a statement must hold exactly one SQL command");
        return status;
    }
    int result = bind_all(statement, operation);
    if (result == SQLITE_OK)
        result = step_rows(connection, statement, operation);
    note_sqlite(connection->database, operation, result);
    if (entry) {
        sqlite3_reset(statement);
        sqlite3_clear_bindings(statement);
        if ((result & 0xff) == SQLITE_SCHEMA)
            evict(entry);
    } else
        sqlite3_finalize(statement);
    return sqlite_status(result);
}

static void run(flint_sqlite_connection *connection, flint_sql_operation *operation)
{
    if (connection->startup != FLINT_SQL_OK) {
        operation->reusable = 0;
        operation->status = connection->startup;
        return;
    }
    sqlite3 *database = connection->database;
    sqlite3_busy_handler(database, busy, operation);
    sqlite3_progress_handler(database, 1000, interrupt_requested, operation);

    operation->status = operation->script ? sqlite_status(step_script(connection, operation))
                                         : step_statement(connection, operation);
    if (interrupt_requested(operation))
        operation->status = FLINT_SQL_CANCELLED;
    sqlite3_busy_handler(database, NULL, NULL);
    sqlite3_progress_handler(database, 0, NULL, NULL);
    operation->dirty = !sqlite3_get_autocommit(database);
    if (operation->status == FLINT_SQL_IO)
        operation->reusable = 0;
}

static void destroy(flint_sqlite_connection *connection)
{
    for (unsigned index = 0; index < connection->capacity; ++index)
        evict(&connection->cache[index]);
    sqlite3_close(connection->database);
    flint_sql_operation_free(connection->orphan);
#if defined(__APPLE__)
    flint_wake_close(connection->wake, connection->wake_writer);
#else
    close(connection->wake);
#endif
    pthread_cond_destroy(&connection->changed);
    pthread_mutex_destroy(&connection->lock);
    free(connection->path);
    free(connection->cache);
    const flint_sql_retirement receipt = connection->retirement;
    free(connection);
    flint_sql_retired(receipt);
}

static int local_database(sqlite3 *database, const char *schema)
{
    const char *path = sqlite3_db_filename(database, schema ? schema : "main");
    struct statfs info;
    if (!path || !path[0] || statfs(path, &info))
        return 0;
#if defined(__APPLE__)
    /* Darwin's local file systems; network and FUSE mounts report their own names. */
    return strcmp(info.f_fstypename, "apfs") == 0 || strcmp(info.f_fstypename, "hfs") == 0
        || strcmp(info.f_fstypename, "tmpfs") == 0;
#else
    switch ((unsigned long)info.f_type) {
    case EXT4_SUPER_MAGIC: case XFS_SUPER_MAGIC: case BTRFS_SUPER_MAGIC:
    case TMPFS_MAGIC: case RAMFS_MAGIC: case F2FS_SUPER_MAGIC:
        return 1;
    default:
        return 0;
    }
#endif
}

static int permit_sql(void *context, int action, const char *first, const char *second,
                       const char *schema, const char *origin)
{
    (void)origin;
    const flint_sqlite_connection *connection = context;
    if (connection->running_script && (action == SQLITE_TRANSACTION || action == SQLITE_SAVEPOINT))
        return SQLITE_DENY;
    if (action == SQLITE_PRAGMA && first && second &&
        !strcasecmp(first, "journal_mode") && !strcasecmp(second, "wal") &&
        !local_database(connection->database, schema))
        return SQLITE_DENY;
    return SQLITE_OK;
}

static void *worker(void *input)
{
    flint_sqlite_connection *connection = input;
    sqlite3 *database = NULL;
    int result = sqlite3_open_v2(connection->path, &database, connection->flags, NULL);
    if (result == SQLITE_OK) {
        const char *tail;
        sqlite3_stmt *statement = NULL;
        result = sqlite3_prepare_v3(database, "PRAGMA foreign_keys=ON", -1, 0, &statement, &tail);
        if (result == SQLITE_OK)
            result = sqlite3_step(statement);
        sqlite3_finalize(statement);
        if (result == SQLITE_DONE) {
            result = sqlite3_prepare_v3(database, "PRAGMA synchronous=FULL", -1, 0, &statement, &tail);
            if (result == SQLITE_OK)
                result = sqlite3_step(statement);
            sqlite3_finalize(statement);
        }
    }
    pthread_mutex_lock(&connection->lock);
    connection->database = database;
    if (result == SQLITE_DONE)
        result = sqlite3_set_authorizer(database, permit_sql, connection);
    connection->startup = sqlite_status(result);
    while (!connection->closing) {
        if (!connection->pending) {
            pthread_cond_wait(&connection->changed, &connection->lock);
            continue;
        }
        flint_sql_operation *operation = connection->pending;
        pthread_mutex_unlock(&connection->lock);
        run(connection, operation);
        pthread_mutex_lock(&connection->lock);
        connection->pending = NULL;
        connection->progress = FLINT_SQL_COMPLETE;
        notify(connection);
    }
    pthread_mutex_unlock(&connection->lock);
    destroy(connection);
    return NULL;
}

static flint_sqlite_connection *start_worker(const char *path, unsigned prepared, int flags)
{
    flint_sqlite_connection *connection = calloc(1, sizeof(*connection));
    if (!connection)
        return NULL;
    connection->path = strdup(path);
    connection->cache = prepared ? calloc(prepared, sizeof(connection->cache[0])) : NULL;
    if (!connection->path || (prepared && !connection->cache))
        goto fail_memory;
#if defined(__APPLE__)
    if (flint_wake_open(&connection->wake, &connection->wake_writer))
        goto fail_memory;
#else
    connection->wake = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (connection->wake < 0)
        goto fail_memory;
#endif
    if (pthread_mutex_init(&connection->lock, NULL))
        goto fail_fd;
    if (pthread_cond_init(&connection->changed, NULL))
        goto fail_mutex;
    connection->capacity = prepared;
    connection->flags = flags | SQLITE_OPEN_FULLMUTEX;
    pthread_attr_t attr;
    if (pthread_attr_init(&attr))
        goto fail_cond;
    int error = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    if (!error)
        error = pthread_create(&thread, &attr, worker, connection);
    pthread_attr_destroy(&attr);
    if (!error)
        return connection;
fail_cond:
    pthread_cond_destroy(&connection->changed);
fail_mutex:
    pthread_mutex_destroy(&connection->lock);
fail_fd:
#if defined(__APPLE__)
    flint_wake_close(connection->wake, connection->wake_writer);
#else
    close(connection->wake);
#endif
fail_memory:
    free(connection->path);
    free(connection->cache);
    free(connection);
    return NULL;
}

flint_sqlite_connection *flint_sqlite_worker(const char *path, unsigned prepared)
{
    return start_worker(path, prepared, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI);
}

flint_sqlite_connection *flint_sqlite_open(const char *path, int flags)
{
    if (!path || !flint_sqlite_available())
        return NULL;
    return start_worker(path, 0, flags);
}

int flint_sqlite_begin(flint_sqlite_connection *connection, flint_sql_operation *operation)
{
    pthread_mutex_lock(&connection->lock);
    connection->pending = operation;
    connection->progress = FLINT_SQL_WAIT;
    pthread_cond_signal(&connection->changed);
    pthread_mutex_unlock(&connection->lock);
    return FLINT_SQL_OK;
}

int flint_sqlite_drive(flint_sqlite_connection *connection, flint_sql_operation *operation,
                       int *fd, unsigned *interest)
{
    (void)operation;
    pthread_mutex_lock(&connection->lock);
#if defined(__APPLE__)
    flint_wake_drain(connection->wake);
#else
    uint64_t count;
    while (read(connection->wake, &count, sizeof(count)) < 0 && errno == EINTR) {}
#endif
    int progress = connection->progress;
    pthread_mutex_unlock(&connection->lock);
    *fd = connection->wake;
    *interest = FLINT_SQL_READ;
    return progress;
}

void flint_sqlite_next(flint_sqlite_connection *connection, flint_sql_operation *operation)
{
    (void)operation;
    pthread_mutex_lock(&connection->lock);
    connection->progress = FLINT_SQL_WAIT;
    pthread_cond_signal(&connection->changed);
    pthread_mutex_unlock(&connection->lock);
}

uint32_t flint_sqlite_columns(const flint_sql_operation *operation)
{
    const sqlite_row *row = operation->row;
    return row ? row->columns : 0;
}

const char *flint_sqlite_name(const flint_sql_operation *operation, uint32_t index)
{
    const sqlite_row *row = operation->row;
    return row && index < row->columns ? row->cells[index].name : NULL;
}

int flint_sqlite_cell(const flint_sql_operation *operation, uint32_t index, flint_sql_cell *cell, const void **data)
{
    const sqlite_row *row = operation->row;
    if (!row || index >= row->columns)
        return FLINT_SQL_INVALID;
    const sqlite_cell *entry = &row->cells[index];
    *cell = entry->cell;
    *data = entry->data;
    return entry->status;
}

static int sqlite_read_cell(sqlite3_stmt *statement, uint32_t index, flint_sql_cell *cell, const void **data)
{
    switch (sqlite3_column_type(statement, (int)index)) {
    case SQLITE_NULL:
        *cell = (flint_sql_cell){.kind = FLINT_SQL_NULL};
        break;
    case SQLITE_INTEGER: {
        const char *type = sqlite3_column_decltype(statement, (int)index);
        int64_t value = sqlite3_column_int64(statement, (int)index);
        int boolean = type && (!strcasecmp(type, "BOOL") || !strcasecmp(type, "BOOLEAN"));
        if (boolean && value != 0 && value != 1)
            return FLINT_SQL_INVALID;
        *cell = (flint_sql_cell){.kind = boolean ? FLINT_SQL_BOOL : FLINT_SQL_INT, .integer = value};
        break;
    }
    case SQLITE_FLOAT: {
        double value = sqlite3_column_double(statement, (int)index);
        if (!isfinite(value))
            return FLINT_SQL_INVALID;
        *cell = (flint_sql_cell){.kind = FLINT_SQL_FLOAT, .floating = value};
        break;
    }
    case SQLITE_TEXT:
        *data = sqlite3_column_text(statement, (int)index);
        if (!*data)
            return FLINT_SQL_NOMEM;
        *cell = (flint_sql_cell){.kind = FLINT_SQL_TEXT, .length = (size_t)sqlite3_column_bytes(statement, (int)index)};
        if (!flint_sql_utf8(*data, cell->length))
            return FLINT_SQL_INVALID;
        break;
    case SQLITE_BLOB:
        *data = sqlite3_column_blob(statement, (int)index);
        *cell = (flint_sql_cell){.kind = FLINT_SQL_BYTES, .length = (size_t)sqlite3_column_bytes(statement, (int)index)};
        if (!*data && cell->length)
            return FLINT_SQL_NOMEM;
        break;
    default:
        return FLINT_SQL_UNSUPPORTED;
    }
    return FLINT_SQL_OK;
}

void flint_sqlite_interrupt(flint_sqlite_connection *connection)
{
    if (!connection)
        return;
    pthread_mutex_lock(&connection->lock);
    if (connection->database)
        sqlite3_interrupt(connection->database);
    pthread_mutex_unlock(&connection->lock);
}

void flint_sqlite_abandon(flint_sqlite_connection *connection, flint_sql_operation *operation,
                         flint_sql_retirement receipt)
{
    atomic_store(&operation->cancelled, 1);
    pthread_mutex_lock(&connection->lock);
    int owned = connection->pending == operation;
    if (owned)
        connection->orphan = operation;
    if (connection->database)
        sqlite3_interrupt(connection->database);
    connection->progress = FLINT_SQL_WAIT;
    connection->retirement = receipt;
    connection->closing = 1;
    pthread_cond_signal(&connection->changed);
    pthread_mutex_unlock(&connection->lock);
    if (!owned)
        flint_sql_operation_free(operation);
}

void flint_sqlite_retire(flint_sqlite_connection *connection, flint_sql_retirement receipt)
{
    pthread_mutex_lock(&connection->lock);
    connection->retirement = receipt;
    connection->closing = 1;
    pthread_cond_signal(&connection->changed);
    pthread_mutex_unlock(&connection->lock);
}

int flint_sqlite_close(flint_sqlite_connection *connection)
{
    if (!connection)
        return FLINT_SQL_INVALID;
    flint_sqlite_retire(connection, (flint_sql_retirement){0});
    return FLINT_SQL_OK;
}

#endif
