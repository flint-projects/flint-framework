#include "flint_sql.h"

#undef NDEBUG
#include <assert.h>
#include <stdlib.h>
#include <string.h>

enum { leases = 16, waiters = 256 };

static void saturation(void)
{
    uint64_t slot, pool, ticket = 0;
    uint64_t held[leases], generations[leases];
    assert(flint_sql_pool_open(1, ":memory:", 8, leases, waiters, 0, &slot, &pool) == FLINT_SQL_OK);
    for (size_t index = 0; index < leases; ++index) {
        assert(flint_sql_pool_acquire(slot, pool, &ticket, &held[index], &generations[index]) == FLINT_SQL_OK);
        assert(ticket == 0);
    }

    uint64_t pending[waiters] = {0};
    uint64_t next_slot, next_generation;
    for (size_t index = 0; index < waiters; ++index) {
        assert(flint_sql_pool_acquire(slot, pool, &pending[index], &next_slot, &next_generation)
            == FLINT_SQL_CONFLICT);
        assert(pending[index] != 0);
    }
    assert(flint_sql_pool_acquire(slot, pool, &ticket, &next_slot, &next_generation) == FLINT_SQL_EXHAUSTED);
    assert(ticket == 0);
    flint_sql_pool_withdraw(slot, pool, pending[0]);
    flint_sql_pool_withdraw(slot, pool, pending[100]);

    assert(flint_sql_pool_release(slot, pool, held[0], generations[0]) == FLINT_SQL_OK);
    assert(flint_sql_pool_acquire(slot, pool, &pending[2], &next_slot, &next_generation) == FLINT_SQL_CONFLICT);
    assert(flint_sql_pool_acquire(slot, pool, &pending[1], &next_slot, &next_generation) == FLINT_SQL_OK);
    assert(next_slot == held[0] && next_generation != generations[0]);
    assert(flint_sql_pool_release(slot, pool, next_slot, generations[0]) == FLINT_SQL_NOT_FOUND);
    assert(flint_sql_pool_release(slot, pool, next_slot, next_generation) == FLINT_SQL_OK);

    for (size_t index = 1; index < leases; ++index)
        assert(flint_sql_pool_release(slot, pool, held[index], generations[index]) == FLINT_SQL_OK);
    for (size_t index = 2; index < waiters; ++index)
        flint_sql_pool_withdraw(slot, pool, pending[index]);
    assert(flint_sql_pool_close(slot, pool) == FLINT_SQL_OK);
    assert(flint_sql_pool_close(slot, pool) == FLINT_SQL_NOT_FOUND);
}

static void invalid_native_input(void)
{
    int status;
    assert(!flint_sql_operation_new("SELECT\0 1", 9, 0, 0, INT64_MAX, &status));
    assert(status == FLINT_SQL_INVALID);
    assert(!flint_sql_operation_new("SELECT 1", 8, 65536, 0, INT64_MAX, &status));
    assert(status == FLINT_SQL_INVALID);
    flint_sql_operation *operation = flint_sql_operation_new("SELECT ?", 8, 1, 1, INT64_MAX, &status);
    assert(operation && status == FLINT_SQL_OK);
    assert(flint_sql_operation_bind(operation, 1, 4, 0, 0.0, "", 0) == FLINT_SQL_INVALID);
    assert(flint_sql_operation_bind(operation, 0, 4, 0, 0.0, "\xc0\x80", 2) == FLINT_SQL_INVALID);
    assert(flint_sql_operation_bind(operation, 0, 1, 2, 0.0, NULL, 0) == FLINT_SQL_INVALID);
    assert(flint_sql_operation_start(operation, UINT64_MAX, 1) == FLINT_SQL_NOT_FOUND);
    flint_sql_operation_free(operation);
    flint_sql_cell cell;
    assert(flint_sql_row_info(1, 2, 0, &cell) == FLINT_SQL_NOT_FOUND);
    assert(flint_sql_row_copy(1, 2, 0, NULL, 0) == FLINT_SQL_NOT_FOUND);
}

static void boundary_value(size_t length)
{
    int status;
    unsigned char *value = malloc(length ? length : 1);
    assert(value);
    memset(value, 'a', length);
    flint_sql_operation *operation = flint_sql_operation_new("SELECT ?", 8, 1, 1, INT64_MAX, &status);
    assert(operation && status == FLINT_SQL_OK);
    assert(flint_sql_operation_bind(operation, 0, 4, 0, 0.0, value, length) == FLINT_SQL_OK);
    if (length)
        value[length - 1] = 0xff;
    flint_sql_operation_free(operation);

    operation = flint_sql_operation_new("SELECT ?", 8, 1, 1, INT64_MAX, &status);
    assert(operation && status == FLINT_SQL_OK);
    if (length)
        assert(flint_sql_operation_bind(operation, 0, 4, 0, 0.0, value, length) == FLINT_SQL_INVALID);
    assert(flint_sql_operation_bind(operation, 0, 5, 0, 0.0, value, length) == FLINT_SQL_OK);
    flint_sql_operation_free(operation);
    free(value);
}

static void boundary_values(void)
{
    for (size_t length = 0; length <= 256; ++length)
        boundary_value(length);
    const size_t lengths[] = {1023, 1024, 1025, 1048575, 1048576, 1048577};
    for (size_t index = 0; index < sizeof(lengths) / sizeof(lengths[0]); ++index)
        boundary_value(lengths[index]);
}

static void dropped_operations(void)
{
    uint64_t pool_slot, pool_generation, lease, generation;
    assert(flint_sql_pool_open(1, ":memory:", 8, 1, 1, 4, &pool_slot, &pool_generation) == FLINT_SQL_OK);
    uint64_t ticket = 0;
    for (unsigned index = 0; index < 128; ++index) {
        int acquired;
        while ((acquired = flint_sql_pool_acquire(pool_slot, pool_generation, &ticket, &lease, &generation))
                == FLINT_SQL_CONFLICT)
            assert(flint_sql_poll(-1, 0, 1) == FLINT_SQL_OK);
        assert(acquired == FLINT_SQL_OK);
        int status;
        const char sql[] = "SELECT 1";
        flint_sql_operation *operation = flint_sql_operation_new(sql, sizeof(sql) - 1, 0, 1, INT64_MAX, &status);
        assert(operation && status == FLINT_SQL_OK);
        assert(flint_sql_operation_start(operation, lease, generation) == FLINT_SQL_OK);
        flint_sql_operation_cancel(operation);
        flint_sql_operation_abort(operation);
        assert(flint_sql_pool_release(pool_slot, pool_generation, lease, generation) == FLINT_SQL_OK);
    }
    int closed;
    while ((closed = flint_sql_pool_close(pool_slot, pool_generation)) == FLINT_SQL_CONFLICT)
        assert(flint_sql_poll(-1, 0, 1) == FLINT_SQL_OK);
    assert(closed == FLINT_SQL_OK);
}

typedef void (*row_check)(uint64_t lease, uint64_t row);

static int run_statement(uint64_t lease, uint64_t generation, const char *sql, row_check check)
{
    int status;
    flint_sql_operation *operation = flint_sql_operation_new(sql, strlen(sql), 0, 1, INT64_MAX, &status);
    assert(operation && status == FLINT_SQL_OK);
    assert(flint_sql_operation_start(operation, lease, generation) == FLINT_SQL_OK);
    for (;;) {
        int fd;
        unsigned interest;
        const int progress = flint_sql_operation_drive(operation, &fd, &interest);
        if (progress == FLINT_SQL_COMPLETE)
            break;
        if (progress == FLINT_SQL_ROW) {
            const uint64_t row = flint_sql_operation_publish_row(operation);
            assert(row);
            if (check)
                check(lease, row);
            flint_sql_operation_next(operation);
            continue;
        }
        assert(flint_sql_poll(fd, interest, 10) == FLINT_SQL_OK);
    }
    uint64_t affected;
    const int result = flint_sql_operation_finish(operation, &affected);
    flint_sql_operation_free(operation);
    return result;
}

static void check_names(uint64_t lease, uint64_t row)
{
    char name[16];
    size_t length = 0;
    assert(flint_sql_row_name(lease, row, 0, name, sizeof(name), &length) == FLINT_SQL_OK);
    assert(length == 2 && !memcmp(name, "id", 2));
    assert(flint_sql_row_name(lease, row, 1, name, sizeof(name), &length) == FLINT_SQL_OK);
    assert(length == 10 && !memcmp(name, "first_name", 10));
    /* Too small: nothing written past the span, and the full length reported. */
    memset(name, 'x', sizeof(name));
    assert(flint_sql_row_name(lease, row, 1, name, 4, &length) == FLINT_SQL_EXHAUSTED);
    assert(length == 10 && name[0] == 'x');
    assert(flint_sql_row_name(lease, row, 2, name, sizeof(name), &length) == FLINT_SQL_INVALID);
    assert(flint_sql_row_name(lease, row + 1, 0, name, sizeof(name), &length) == FLINT_SQL_NOT_FOUND);
}

static void failures_and_names(void)
{
    uint64_t pool_slot, pool_generation, lease, generation, ticket = 0;
    assert(flint_sql_pool_open(1, ":memory:", 8, 1, 1, 4, &pool_slot, &pool_generation) == FLINT_SQL_OK);
    assert(flint_sql_pool_acquire(pool_slot, pool_generation, &ticket, &lease, &generation) == FLINT_SQL_OK);
    flint_sql_failure failure;
    assert(flint_sql_lease_failure(lease, generation + 1, &failure) == FLINT_SQL_NOT_FOUND);
    assert(flint_sql_lease_failure(UINT64_MAX, generation, &failure) == FLINT_SQL_NOT_FOUND);

    /* A CHECK constraint named with 300 two-byte characters makes a message longer than the record. */
    char create[1024] = "CREATE TABLE customers (id INTEGER PRIMARY KEY, first_name TEXT UNIQUE, CONSTRAINT \"";
    for (int index = 0; index < 300; ++index)
        strcat(create, "\xc3\xa9");
    strcat(create, "\" CHECK (id > 0))");
    assert(run_statement(lease, generation, create, NULL) == FLINT_SQL_OK);
    assert(flint_sql_lease_failure(lease, generation, &failure) == FLINT_SQL_OK && !failure.state[0]);
    assert(run_statement(lease, generation, "INSERT INTO customers VALUES (1, 'Josh')", NULL) == FLINT_SQL_OK);

    assert(run_statement(lease, generation, "INSERT INTO customers VALUES (2, 'Josh')", NULL) == FLINT_SQL_CONFLICT);
    assert(flint_sql_lease_failure(lease, generation, &failure) == FLINT_SQL_OK);
    assert(!strcmp(failure.state, "23505") && failure.vendor == 2067);
    assert(failure.length > 0 && failure.length == strlen(failure.message));

    assert(run_statement(lease, generation, "INSERT INTO customers VALUES (-1, 'Jeff')", NULL) == FLINT_SQL_CONFLICT);
    assert(flint_sql_lease_failure(lease, generation, &failure) == FLINT_SQL_OK);
    assert(!strcmp(failure.state, "23514"));
    assert(failure.length < FLINT_SQL_MESSAGE_CAPACITY && failure.message[failure.length] == 0);
    assert(failure.length > FLINT_SQL_MESSAGE_CAPACITY - 4);
    /* Cut on a character boundary: the last kept byte ends a two-byte sequence. */
    assert((unsigned char)failure.message[failure.length - 1] == 0xa9);

    assert(run_statement(lease, generation, "SELECT id, first_name FROM customers", check_names) == FLINT_SQL_OK);
    assert(flint_sql_lease_failure(lease, generation, &failure) == FLINT_SQL_OK && !failure.state[0]);
    assert(run_statement(lease, generation, "SELECT 1; SELECT 2", NULL) == FLINT_SQL_INVALID);
    assert(flint_sql_lease_failure(lease, generation, &failure) == FLINT_SQL_OK && !strcmp(failure.state, "42000"));

    assert(flint_sql_pool_release(pool_slot, pool_generation, lease, generation) == FLINT_SQL_OK);
    assert(flint_sql_lease_failure(lease, generation, &failure) == FLINT_SQL_NOT_FOUND);
    int closed;
    while ((closed = flint_sql_pool_close(pool_slot, pool_generation)) == FLINT_SQL_CONFLICT)
        assert(flint_sql_poll(-1, 0, 1) == FLINT_SQL_OK);
    assert(closed == FLINT_SQL_OK);
}

int main(void)
{
    saturation();
    invalid_native_input();
    boundary_values();
    dropped_operations();
    failures_and_names();
    return 0;
}
