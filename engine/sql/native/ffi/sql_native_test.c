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

int main(void)
{
    saturation();
    invalid_native_input();
    boundary_values();
    dropped_operations();
    return 0;
}
