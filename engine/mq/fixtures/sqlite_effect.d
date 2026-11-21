/// Test-only idempotent database effect for the live JetStream fixture.
module sqlite_effect;

@safe:

private struct Sqlite;
private struct Statement;

extern (C) private @system nothrow @nogc
{
    int sqlite3_open(const(char)* name, Sqlite** output);
    int sqlite3_close(Sqlite* db);
    int sqlite3_exec(Sqlite* db, const(char)* sql, void* callback, void* user, char** error);
    int sqlite3_prepare_v2(Sqlite* db, const(char)* sql, int bytes, Statement** output, const(char)** tail);
    int sqlite3_finalize(Statement* statement);
    int sqlite3_bind_int64(Statement* statement, int field, long value);
    int sqlite3_step(Statement* statement);
    int sqlite3_reset(Statement* statement);
    int sqlite3_changes(Sqlite* db);
}

/// Fixture-owned connection and permanently prepared idempotent insert.
struct Effects
{
    private Sqlite* connection;
    private Statement* insertion;

    /// Start the test database and prepare its one statement.
    // SAFETY: A fixture owner retains the private SQLite connection and prepared statement until close.
    @trusted bool open()
    {
        enum table = "CREATE TABLE effects(id integer PRIMARY KEY)";
        enum sql = "INSERT OR IGNORE INTO effects(id) VALUES(?1)";
        const status = sqlite3_open(":memory:", &connection);
        if (status == 0 && sqlite3_exec(connection, table, null, null, null) == 0
                && sqlite3_prepare_v2(connection, sql, -1, &insertion, null) == 0)
            return true;
        const destroyed = close();
        assert(destroyed);
        return false;
    }

    /// Apply one scalar idempotency key and return the affected row count.
    // SAFETY: The synchronous statement uses only the scalar offset and runs on the fixture owner thread.
    @trusted int insert(long id) nothrow @nogc
    {
        if (sqlite3_bind_int64(insertion, 1, id) != 0 || sqlite3_step(insertion) != 101)
            return -1;
        const changes = sqlite3_changes(connection);
        return sqlite3_reset(insertion) == 0 ? changes : -1;
    }

    /// Finalize the prepared statement and close the fixture database.
    // SAFETY: The fixture closes after all handlers have returned. No callbacks can retain its statement.
    @trusted bool close()
    {
        const finalized = sqlite3_finalize(insertion);
        const released = sqlite3_close(connection);
        return finalized == 0 && released == 0;
    }
}
