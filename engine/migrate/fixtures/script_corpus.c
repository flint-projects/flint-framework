#include "flint_sql_private.h"

#undef NDEBUG
#include <assert.h>
#include <stdlib.h>
#include <string.h>

static void postgres_guard(void)
{
    const char *valid[] = {
        "SELECT ';COMMIT;', \"rollback\"; SELECT 2",
        "/* outer /* COMMIT; */ comment */ SELECT 1; -- ROLLBACK\n SELECT 2",
        "CREATE FUNCTION f() RETURNS TEXT AS $x$ BEGIN RETURN 'a;b'; END; $x$ LANGUAGE plpgsql",
        "CREATE FUNCTION f() RETURNS INTEGER LANGUAGE SQL BEGIN ATOMIC "
        "SELECT CASE WHEN TRUE THEN 1 ELSE 2 END; END; SELECT 3",
        "SELECT E'\\\' ;COMMIT'; SELECT 2",
    };
    for (size_t index = 0; index < sizeof(valid) / sizeof(valid[0]); ++index) {
        const char *seed = valid[index];
        assert(flint_pg_script_allowed(seed, 0));
        for (size_t length = 0; length <= strlen(seed); ++length) {
            char *prefix = malloc(length + 1);
            assert(prefix);
            memcpy(prefix, seed, length);
            prefix[length] = 0;
            (void)flint_pg_script_allowed(prefix, 0);
            (void)flint_pg_script_allowed(prefix, 1);
            free(prefix);
        }
    }
    const char *blocked[] = {
        "BEGIN", "START TRANSACTION", ";COMMIT AND CHAIN", "SELECT 1; END",
        "ABORT", "ROLLBACK TO SAVEPOINT fixture", "SAVEPOINT fixture", "RELEASE fixture",
        "SELECT 1; PREPARE /* ; */ TRANSACTION 'prepared'",
        "CREATE FUNCTION f() RETURNS INTEGER LANGUAGE SQL BEGIN ATOMIC "
        "SELECT CASE WHEN TRUE THEN 1 ELSE 2 END; END; COMMIT",
        "SELECT '$' ; /* unclosed", "SELECT $tag$never closed",
    };
    for (size_t index = 0; index < sizeof(blocked) / sizeof(blocked[0]); ++index)
        assert(!flint_pg_script_allowed(blocked[index], 0));
    assert(!flint_pg_script_allowed("SELECT '\\'; COMMIT; --'; SELECT 1", 0));
    assert(flint_pg_script_allowed("SELECT '\\'; COMMIT; --'; SELECT 1", 1));
}

static void create_and_copy(void)
{
    const size_t maximum = 1u << 20;
    char *bytes = malloc(maximum);
    assert(bytes);
    memset(bytes, ' ', maximum);
    memcpy(bytes, "SELECT 1", 8);
    int status;
    assert(!flint_sql_operation_new_script(bytes, 0, INT64_MAX, &status) && status == FLINT_SQL_INVALID);
    const size_t edges[] = {1, 7, 8, 255, 256, 257, 1023, 1024, 1025, maximum - 1, maximum};
    for (size_t index = 0; index < sizeof(edges) / sizeof(edges[0]); ++index) {
        size_t length = edges[index];
        flint_sql_operation *operation = flint_sql_operation_new_script(bytes, length, INT64_MAX, &status);
        assert(operation && operation->script && status == FLINT_SQL_OK);
        char last = bytes[length - 1];
        bytes[length - 1] = (char)0xc2;
        assert(operation->text[length - 1] == last && operation->text[length] == 0);
        flint_sql_operation_free(operation);
        assert(!flint_sql_operation_new_script(bytes, length, INT64_MAX, &status) && status == FLINT_SQL_INVALID);
        bytes[length - 1] = '\0';
        assert(!flint_sql_operation_new_script(bytes, length, INT64_MAX, &status) && status == FLINT_SQL_INVALID);
        bytes[length - 1] = last;
    }
    free(bytes);
}

static void retire_cancelled_scripts(void)
{
    uint64_t pool, epoch, lease, generation, ticket = 0;
    assert(flint_sql_pool_open(1, ":memory:", 8, 1, 1, 4, &pool, &epoch) == FLINT_SQL_OK);
    const char script[] = "SELECT 1; SELECT 2; SELECT 3;";
    for (unsigned index = 0; index < 128; ++index) {
        int acquired;
        while ((acquired = flint_sql_pool_acquire(pool, epoch, &ticket, &lease, &generation)) == FLINT_SQL_CONFLICT)
            assert(flint_sql_poll(-1, 0, 1) == FLINT_SQL_OK);
        assert(acquired == FLINT_SQL_OK);
        int status;
        flint_sql_operation *operation = flint_sql_operation_new_script(script, sizeof(script) - 1, INT64_MAX, &status);
        assert(operation && status == FLINT_SQL_OK);
        assert(flint_sql_operation_start(operation, lease, generation) == FLINT_SQL_OK);
        flint_sql_operation_cancel(operation);
        flint_sql_operation_abort(operation);
        assert(flint_sql_pool_release(pool, epoch, lease, generation) == FLINT_SQL_OK);
        assert(flint_sql_pool_release(pool, epoch, lease, generation) == FLINT_SQL_NOT_FOUND);
    }
    int closed;
    while ((closed = flint_sql_pool_close(pool, epoch)) == FLINT_SQL_CONFLICT)
        assert(flint_sql_poll(-1, 0, 1) == FLINT_SQL_OK);
    assert(closed == FLINT_SQL_OK);
}

int main(void)
{
    postgres_guard();
    create_and_copy();
    retire_cancelled_scripts();
    return 0;
}
