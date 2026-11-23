#ifndef FLINT_SQL_PRIVATE_H
#define FLINT_SQL_PRIVATE_H

#include "flint_sql.h"
#include <stdatomic.h>

#define FLINT_SQL_READ 1u
#define FLINT_SQL_WRITE 2u
#define FLINT_SQL_ERROR 4u

enum flint_sql_value_kind {
    FLINT_SQL_NULL, FLINT_SQL_BOOL, FLINT_SQL_INT, FLINT_SQL_FLOAT, FLINT_SQL_TEXT, FLINT_SQL_BYTES
};

typedef struct {
    flint_sql_cell cell;
    const void *data;
} flint_sql_parameter;

struct flint_sql_operation {
    char *text;
    flint_sql_parameter *params;
    size_t parameter_count;
    int64_t deadline;
    uint64_t affected;
    uint64_t lease_slot;
    uint64_t lease_identity;
    unsigned phase;
    int driver;
    int started;
    int cache;
    int cancel_started;
    int cancel_done;
    unsigned row_index;
    int status;
    int rows;
    int script;
    int reusable;
    int dirty;
    atomic_int cancelled;
    flint_sql_failure failure;
    /* Driver-owned storage. The row source cannot advance while its Row is published. */
    void *connection;
    void *row;
};

typedef struct {
    const char *address;
    unsigned prepared;
} flint_sql_backend_options;

typedef struct {
    uint64_t slot;
    uint64_t pool_identity;
} flint_sql_retirement;

void flint_sql_retired(flint_sql_retirement receipt);
int flint_sql_utf8(const void *data, size_t length);
/* Keep the first failure an operation reports; later ones are consequences of it. */
void flint_sql_note_failure(flint_sql_operation *operation, const char *state, int vendor, const char *message);

#ifdef FLINT_HAS_SQLITE
int flint_sqlite_available(void);
flint_sqlite_connection *flint_sqlite_worker(const char *path, unsigned prepared);
int flint_sqlite_begin(flint_sqlite_connection *connection, flint_sql_operation *operation);
int flint_sqlite_drive(flint_sqlite_connection *connection, flint_sql_operation *operation,
                       int *fd, unsigned *interest);
uint32_t flint_sqlite_columns(const flint_sql_operation *operation);
int flint_sqlite_cell(const flint_sql_operation *operation, uint32_t index, flint_sql_cell *cell,
                      const void **data);
const char *flint_sqlite_name(const flint_sql_operation *operation, uint32_t index);
void flint_sqlite_next(flint_sqlite_connection *connection, flint_sql_operation *operation);
void flint_sqlite_abandon(flint_sqlite_connection *connection, flint_sql_operation *operation,
                         flint_sql_retirement receipt);
void flint_sqlite_retire(flint_sqlite_connection *connection, flint_sql_retirement receipt);
#endif

#ifdef FLINT_HAS_LIBPQ
int flint_pg_script_allowed(const char *sql, int ordinary_backslash);
int flint_pg_available(void);
flint_pg_connection *flint_pg_open(const flint_sql_backend_options *options);
int flint_pg_drive(flint_pg_connection *connection, flint_sql_operation *operation,
                  int *fd, unsigned *interest);
uint32_t flint_pg_columns(const flint_sql_operation *operation);
int flint_pg_cell(const flint_sql_operation *operation, uint32_t index, flint_sql_cell *cell,
                  const void **data);
const char *flint_pg_name(const flint_sql_operation *operation, uint32_t index);
void flint_pg_next(flint_sql_operation *operation);
void flint_pg_discard(flint_sql_operation *operation);
void flint_pg_retire(flint_pg_connection *connection, flint_sql_retirement receipt);
#endif

#endif
