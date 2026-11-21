/* Flint SQL ABI. Only approved bindings may call this interface. */
#ifndef FLINT_SQL_ABI_H
#define FLINT_SQL_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct flint_pg_connection flint_pg_connection;
typedef struct flint_sqlite_connection flint_sqlite_connection;
typedef struct flint_sql_operation flint_sql_operation;

flint_pg_connection *flint_pg_connect_start(const char *connection_string);
int flint_pg_connect_poll(flint_pg_connection *connection, intptr_t *socket);
int flint_pg_send(flint_pg_connection *connection, const char *query,
                  size_t parameter_count, const char *const *values,
                  const int *lengths, const int *formats);
int flint_pg_consume(flint_pg_connection *connection);
int flint_pg_cancel_start(flint_pg_connection *connection);
int flint_pg_cancel_poll(flint_pg_connection *connection);
void flint_pg_close(flint_pg_connection *connection);
flint_sqlite_connection *flint_sqlite_open(const char *path, int flags);
void flint_sqlite_interrupt(flint_sqlite_connection *connection);
int flint_sqlite_close(flint_sqlite_connection *connection);

enum flint_sql_status {
    FLINT_SQL_OK, FLINT_SQL_INVALID, FLINT_SQL_NOMEM, FLINT_SQL_CANCELLED,
    FLINT_SQL_TIMEOUT, FLINT_SQL_NOT_FOUND, FLINT_SQL_CONFLICT,
    FLINT_SQL_IO, FLINT_SQL_UNAVAILABLE, FLINT_SQL_UNSUPPORTED,
    FLINT_SQL_PERMISSION, FLINT_SQL_EXHAUSTED
};

enum flint_sql_progress {
    FLINT_SQL_COMPLETE, FLINT_SQL_WAIT, FLINT_SQL_ROW
};

typedef struct {
    int kind;
    int64_t integer;
    double floating;
    size_t length;
} flint_sql_cell;

int flint_sql_pool_open(int driver, const char *address, size_t length, unsigned capacity,
                        unsigned waiters, unsigned prepared, uint64_t *slot, uint64_t *identity);
int flint_sql_pool_acquire(uint64_t slot, uint64_t identity, uint64_t *ticket,
                           uint64_t *lease_slot, uint64_t *lease_identity);
void flint_sql_pool_withdraw(uint64_t slot, uint64_t identity, uint64_t ticket);
int flint_sql_pool_close(uint64_t slot, uint64_t identity);
int flint_sql_pool_release(uint64_t slot, uint64_t identity,
                           uint64_t lease_slot, uint64_t lease_identity);
int flint_sql_pool_dirty(uint64_t slot, uint64_t identity, uint64_t lease_slot, uint64_t lease_identity);
void flint_sql_pool_retire(uint64_t lease_slot, uint64_t lease_identity);
int flint_sql_pool_claim_transaction(uint64_t lease_slot, uint64_t lease_identity);
void flint_sql_pool_finish_transaction(uint64_t lease_slot, uint64_t lease_identity);

flint_sql_operation *flint_sql_operation_new(const char *sql, size_t length,
                                             size_t parameter_count, int rows,
                                             int64_t deadline, int *status);
flint_sql_operation *flint_sql_operation_new_script(const char *sql, size_t length,
                                                    int64_t deadline, int *status);
int flint_sql_operation_bind(flint_sql_operation *operation, size_t index, int kind,
                              int64_t integer, double floating, const void *data, size_t length);
int flint_sql_operation_start(flint_sql_operation *operation, uint64_t slot, uint64_t identity);
int flint_sql_operation_drive(flint_sql_operation *operation, int *fd, unsigned *interest);
void flint_sql_operation_cancel(flint_sql_operation *operation);
void flint_sql_operation_abort(flint_sql_operation *operation);
uint64_t flint_sql_operation_publish_row(flint_sql_operation *operation);
void flint_sql_operation_next(flint_sql_operation *operation);
int flint_sql_operation_finish(flint_sql_operation *operation, uint64_t *affected);
void flint_sql_operation_free(flint_sql_operation *operation);

uint32_t flint_sql_row_columns(uint64_t slot, uint64_t row);
int flint_sql_row_info(uint64_t slot, uint64_t row, uint32_t column, flint_sql_cell *output);
int flint_sql_row_copy(uint64_t slot, uint64_t row, uint32_t column, void *data, size_t length);
int flint_sql_poll(int fd, unsigned interest, unsigned millis);

#ifdef __cplusplus
}
#endif

#endif
