module app;

import probe : measureTrial, nanos, require, rows, schema;

@safe:

private struct Sqlite;
private struct Statement;
private struct Postgres;
private struct Result;

extern (C) nothrow @nogc @system
{
    private int sqlite3_open_v2(const(char)*, Sqlite**, int, const(char)*);
    private int sqlite3_close(Sqlite*);
    private int sqlite3_prepare_v3(Sqlite*, const(char)*, int, uint, Statement**, const(char)**);
    private int sqlite3_finalize(Statement*);
    private int sqlite3_bind_int64(Statement*, int, long);
    private int sqlite3_step(Statement*);
    private int sqlite3_reset(Statement*);
    private int sqlite3_clear_bindings(Statement*);
    private long sqlite3_column_int64(Statement*, int);
    private long sqlite3_changes64(Sqlite*);

    pragma(mangle, "PQconnectdb") private Postgres* pqConnectDb(const(char)*);
    pragma(mangle, "PQstatus") private int pqStatus(const(Postgres)*);
    pragma(mangle, "PQfinish") private void pqFinish(Postgres*);
    pragma(mangle, "PQexecParams") private Result* pqExecParams(Postgres*, const(char)*, int,
            const(uint)*, const(char)**, const(int)*, const(int)*, int);
    pragma(mangle, "PQprepare") private Result* pqPrepare(Postgres*, const(char)*, const(char)*, int, const(uint)*);
    pragma(mangle, "PQexecPrepared") private Result* pqExecPrepared(Postgres*, const(char)*, int,
            const(char)**, const(int)*, const(int)*, int);
    pragma(mangle, "PQresultStatus") private int pqResultStatus(const(Result)*);
    pragma(mangle, "PQntuples") private int pqNtuples(const(Result)*);
    pragma(mangle, "PQgetlength") private int pqGetlength(const(Result)*, int, int);
    pragma(mangle, "PQgetvalue") private char* pqGetvalue(const(Result)*, int, int);
    pragma(mangle, "PQclear") private void pqClear(Result*);
}

private enum sqliteRow = 100;
private enum sqliteDone = 101;

/// Prepare a single command with the SQLite 3.54.1 interface.
// SAFETY: The caller keeps the connection alive and gives this fixture a static, NUL-terminated SQL literal.
private Statement* prepareSqlite(Sqlite* database, const(char)* sql) @trusted nothrow @nogc
{
    Statement* statement;
    require(sqlite3_prepare_v3(database, sql, -1, 1, &statement, null) == 0 && statement !is null);
    return statement;
}

// SAFETY: A fixture-owned SQLite database outlives the statement. All commands are fixed SQL literals.
private void sqliteCommand(Sqlite* database, const(char)* sql) @trusted nothrow @nogc
{
    auto statement = prepareSqlite(database, sql);
    require(sqlite3_step(statement) == sqliteDone);
    require(sqlite3_finalize(statement) == 0);
}

// SAFETY: The local benchmark owns and finalizes the database and both prepared statements.
private ulong sqliteTrial(out long queue, out long driver) @trusted nothrow @nogc
{
    queue = 0;
    Sqlite* database;
    require(sqlite3_open_v2(":memory:", &database, 0x10046, null) == 0 && database !is null);
    scope (exit)
        require(sqlite3_close(database) == 0);
    sqliteCommand(database, "PRAGMA foreign_keys=ON");
    sqliteCommand(database, "PRAGMA synchronous=FULL");
    sqliteCommand(database, schema);

    const started = nanos();
    sqliteCommand(database, "BEGIN");
    auto inserted = prepareSqlite(database, "INSERT INTO flint_probe VALUES (?)");
    scope (exit)
        require(sqlite3_finalize(inserted) == 0);
    foreach (value; 1 .. rows + 1)
    {
        require(sqlite3_bind_int64(inserted, 1, value) == 0);
        require(sqlite3_step(inserted) == sqliteDone && sqlite3_changes64(database) == 1);
        require(sqlite3_reset(inserted) == 0 && sqlite3_clear_bindings(inserted) == 0);
    }
    sqliteCommand(database, "COMMIT");

    auto selected = prepareSqlite(database, "SELECT id FROM flint_probe WHERE id=?");
    scope (exit)
        require(sqlite3_finalize(selected) == 0);
    ulong total;
    foreach (value; 1 .. rows + 1)
    {
        require(sqlite3_bind_int64(selected, 1, value) == 0 && sqlite3_step(selected) == sqliteRow);
        const received = sqlite3_column_int64(selected, 0);
        require(received == value);
        total += received;
        require(sqlite3_step(selected) == sqliteDone);
        require(sqlite3_reset(selected) == 0 && sqlite3_clear_bindings(selected) == 0);
    }
    driver = nanos() - started;
    return total;
}

// SAFETY: A fixture-owned PGconn outlives this checked synchronous command and every query result is released.
private void postgresCommand(Postgres* connection, const(char)* statement) @trusted nothrow @nogc
{
    auto result = pqExecParams(connection, statement, 0, null, null, null, null, 1);
    require(result !is null && pqResultStatus(result) == 1);
    pqClear(result);
}

// SAFETY: The fixed names and statements remain alive during synchronous preparation. OID 20 is wire Int64.
private void preparePostgres(Postgres* connection, const(char)* name, const(char)* statement) @trusted nothrow @nogc
{
    const uint type = 20;
    auto result = pqPrepare(connection, name, statement, 1, &type);
    require(result !is null && pqResultStatus(result) == 1);
    pqClear(result);
}

// SAFETY: libpq only borrows the one stack-allocated binary scalar and lengths during this synchronous call.
private Result* runPostgres(Postgres* connection, const(char)* name, ulong number) @trusted nothrow @nogc
{
    char[8] buffer;
    foreach_reverse (ref byteValue; buffer)
    {
        byteValue = cast(char) number;
        number >>= 8;
    }
    const(char)* input = buffer.ptr;
    const int length = 8;
    const int format = 1;
    auto result = pqExecPrepared(connection, name, 1, &input, &length, &format, 1);
    require(result !is null);
    return result;
}

// SAFETY: The retained PostgreSQL result guarantees column zero of its single row has eight readable bytes.
private ulong readPostgres(Result* result) @trusted nothrow @nogc
{
    require(pqResultStatus(result) == 2 && pqNtuples(result) == 1 && pqGetlength(result, 0, 0) == 8);
    const bytes = pqGetvalue(result, 0, 0);
    require(bytes !is null);
    ulong value;
    foreach (ch; bytes[0 .. 8])
        value = (value << 8) | cast(ubyte) ch;
    return value;
}

// SAFETY: The local benchmark owns the connection and every result. The connection string remains rooted.
private ulong postgresTrial(scope const(char)[] arguments, out long queue, out long driver) @trusted
{
    const dsn = arguments ~ "\0";
    queue = 0;
    auto connection = pqConnectDb(dsn.ptr);
    require(connection !is null && pqStatus(connection) == 0);
    scope (exit)
        pqFinish(connection);
    postgresCommand(connection, schema);

    const started = nanos();
    postgresCommand(connection, "BEGIN");
    preparePostgres(connection, "insert_row", "INSERT INTO flint_probe VALUES ($1)");
    foreach (value; 1 .. rows + 1)
    {
        auto result = runPostgres(connection, "insert_row", value);
        require(pqResultStatus(result) == 1);
        pqClear(result);
    }
    postgresCommand(connection, "COMMIT");

    preparePostgres(connection, "select_row", "SELECT id FROM flint_probe WHERE id=$1");
    ulong total;
    foreach (value; 1 .. rows + 1)
    {
        auto result = runPostgres(connection, "select_row", value);
        const received = readPostgres(result);
        require(received == value);
        total += received;
        pqClear(result);
    }
    driver = nanos() - started;
    return total;
}

void main(string[] args)
{
    const measure = args.length > 1 && args[1] == "--measure";
    const index = measure ? 2 : 1;
    const address = args.length > index ? args[index] : null;
    measureTrial((out long queue, out long driver) @safe {
        return address.length ? postgresTrial(address, queue, driver) : sqliteTrial(queue, driver);
    }, measure);
}
