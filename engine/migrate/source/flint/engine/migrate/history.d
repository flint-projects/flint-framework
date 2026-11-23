/// Database-scoped migration history and progress verification.
module flint.engine.migrate.history;

import flint.arena : Error, RequestArena, Result, Status;
import flint.conc : Context;
import flint.engine.migrate.embedding : digestText, matchDigest, validDigestText;
import flint.engine.migrate.types : Migration;
import flint.engine.sql : Connection, Driver, Row, SqlValue, ValueKind;
import std.conv : to;

@safe:
package(flint.engine.migrate):

private enum malformed = Error(Status.invalidArgument, "malformed SQL migration history");

/// SQL identifiers qualified against the schema selected during startup.
struct History
{
    private string name;
    private string metaName;
    private string qualified;
    private string metaQualified;
    private string schema;
    private string provider;
    private Driver driver;

    Error open(ref Connection connection, Driver selected, string table, ref Context context)
    {
        driver = selected;
        if (driver == Driver.sqlite)
        {
            schema = "main";
            provider = "sqlite";
        }
        else
        {
            provider = "postgres";
            const discovered = readSchema(connection, context, schema);
            if (discovered.code != Status.ok)
                return discovered;
        }
        name = table;
        metaName = table ~ (driver == Driver.sqlite ? "_settings" : "_metadata");
        const namespace_ = quote(schema) ~ ".";
        qualified = namespace_ ~ quote(name);
        metaQualified = namespace_ ~ quote(metaName);
        return Error.init;
    }

    Result!bool exists(ref Connection connection, ref Context context)
    {
        return tableExists(connection, context, name);
    }

    Result!bool metadataExists(ref Connection connection, ref Context context)
    {
        return tableExists(connection, context, metaName);
    }

    Error install(ref Connection connection, ref Context context)
    {
        const timeType = driver == Driver.sqlite ? "TIMESTAMP" : "TIMESTAMPTZ";
        const history = "CREATE TABLE " ~ qualified ~ " (version BIGINT PRIMARY KEY, description TEXT NOT NULL, "
            ~ "sha256 CHAR(64) NOT NULL, installed_at " ~ timeType
            ~ " NOT NULL DEFAULT CURRENT_TIMESTAMP, " ~ "execution_ms BIGINT NOT NULL, success BOOLEAN NOT NULL)";
        auto status = command(connection, history, context);
        if (status.code != Status.ok)
            return status;
        const meta = "CREATE TABLE " ~ metaQualified ~ " (installation_key INTEGER PRIMARY KEY, "
            ~ "effective_schema TEXT NOT NULL, driver TEXT NOT NULL)";
        status = command(connection, meta, context);
        if (status.code != Status.ok)
            return status;
        const insert = "INSERT INTO " ~ metaQualified ~ " (installation_key,effective_schema,driver) VALUES (1,$1,$2)";
        ubyte[256] bytes;
        scope arena = RequestArena(bytes[]);
        SqlValue[2] values;
        status = bindText(arena, schema, values[0]);
        if (status.code == Status.ok)
            status = bindText(arena, provider, values[1]);
        if (status.code != Status.ok)
            return status;
        return connection.execute(insert, values[], arena, context).error;
    }

    Error checkMetadata(ref Connection connection, ref Context context)
    {
        const exists = metadataExists(connection, context);
        if (!exists.ok())
            return exists.error;
        if (!exists.value)
            return Error(Status.conflict, "migration history has no installation metadata");
        ubyte[512] bytes;
        scope arena = RequestArena(bytes[]);
        const sql = "SELECT effective_schema, driver FROM " ~ metaQualified ~ " WHERE installation_key=1";
        bool verified;
        const expectedSchema = schema;
        const expectedDriver = provider;
        const checked = connection.query(sql, [], arena, context, (ref Row row) @safe nothrow @nogc {
            const namespace_ = row.value(0, arena);
            const providerName = row.value(1, arena);
            if (verified || !namespace_.ok() || !providerName.ok() || !equalText(arena,
                namespace_.value, expectedSchema) || !equalText(arena, providerName.value, expectedDriver))
                return Error(Status.conflict, "migration history installation metadata does not match");
            verified = true;
            return Error.init;
        });
        if (checked.code != Status.ok)
            return checked;
        return verified ? Error.init : Error(Status.conflict, "migration history installation metadata is missing");
    }

    Error read(ref Connection connection, scope const(Migration)[] plan, ref Context context, out Prefix prefix)
    {
        ubyte[256] bytes;
        scope arena = RequestArena(bytes[]);
        const sql = "SELECT version, sha256, success FROM " ~ qualified ~ " ORDER BY version";
        Drift observed;
        Prefix verified;
        const checked = connection.query(sql, [], arena, context, (ref Row row) @safe nothrow @nogc {
            return advance(row, arena, plan, verified, observed);
        });
        prefix = verified;
        return observed.kind == Issue.none ? checked : historyError(observed);
    }

    Error record(ref Connection connection, scope const ref Migration migration, long milliseconds,
            bool success, ref Context context)
    {
        const sql = "INSERT INTO " ~ qualified
            ~ " (version,description,sha256,execution_ms,success) " ~ "VALUES ($1,$2,$3,$4,$5)";
        auto bytes = new ubyte[migration.description.length + 80];
        scope arena = RequestArena(bytes);
        SqlValue[5] values;
        values[0] = integer(cast(long) migration.versionNumber);
        auto status = bindText(arena, migration.description, values[1]);
        char[64] hash;
        digestText(migration.sha256, hash);
        if (status.code == Status.ok)
            status = bindText(arena, hash[], values[2]);
        if (status.code != Status.ok)
            return status;
        values[3] = integer(milliseconds);
        values[4] = SqlValue(ValueKind.boolean, success ? 1 : 0);
        const saved = connection.execute(sql, values[], arena, context);
        if (!saved.ok())
            return saved.error;
        return saved.value == 1 ? Error.init : Error(Status.conflict, "migration history record was not inserted");
    }

    Error completeMarker(ref Connection connection, ulong versionNumber, long milliseconds, ref Context context)
    {
        const sql = "UPDATE " ~ qualified ~ " SET execution_ms=$1, success=TRUE, installed_at=CURRENT_TIMESTAMP "
            ~ "WHERE version=$2 AND success=FALSE";
        scope RequestArena unused;
        const values = [integer(milliseconds), integer(cast(long) versionNumber)];
        const done = connection.execute(sql, values, unused, context);
        if (!done.ok())
            return done.error;
        return done.value == 1 ? Error.init : Error(Status.conflict, "migration history started marker was lost");
    }

    private Result!bool tableExists(ref Connection connection, ref Context context, string relation)
    {
        enum sqlite = "SELECT 1 FROM main.sqlite_schema WHERE type='table' AND name=$1 COLLATE NOCASE";
        enum postgres = "SELECT 1 FROM information_schema.tables WHERE table_name=$1 AND table_schema=$2";
        const count = driver == Driver.sqlite ? 1 : 2;
        SqlValue[2] values;
        ubyte[256] bytes;
        scope arena = RequestArena(bytes[]);
        auto status = bindText(arena, relation, values[0]);
        if (status.code == Status.ok && count == 2)
            status = bindText(arena, schema, values[1]);
        if (status.code != Status.ok)
            return Result!bool(false, status);
        bool found;
        const result = connection.query(count == 1 ? sqlite : postgres, values[0 .. count], arena,
                context, (ref Row) @safe nothrow @nogc { found = true; return Error.init; });
        return Result!bool(found, result);
    }
}

private string quote(scope const(char)[] identifier)
{
    string result = "\"";
    foreach (ch; identifier)
        result ~= ch == '"' ? "\"\"" : [ch];
    return result ~ "\"";
}

private Error readSchema(ref Connection connection, ref Context context, out string schema)
{
    ubyte[256] bytes;
    scope arena = RequestArena(bytes[]);
    char[128] spelling;
    size_t written;
    const result = connection.query("SELECT current_schema()::text", [], arena, context,
            (ref Row row) @safe nothrow @nogc {
        const cell = row.value(0, arena);
        if (!cell.ok())
            return Error(cell.error.code, cell.error.message, cell.error.offset);
        if (cell.value.kind != ValueKind.text || cell.value.bytes.length() == 0
            || cell.value.bytes.length() > spelling.length || written != 0)
            return Error(Status.invalidArgument, "PostgreSQL has no effective migration schema");
        const copied = arena.read(cell.value.bytes, (scope const(ubyte)[] input) @safe nothrow @nogc {
            spelling[0 .. input.length] = cast(const(char)[]) input;
            written = input.length;
        });
        return Error(copied);
    });
    if (result.code != Status.ok)
        return result;
    if (written == 0)
        return Error(Status.invalidArgument, "effective PostgreSQL migration schema was not returned");
    schema = spelling[0 .. written].idup;
    return Error.init;
}

SqlValue integer(long value) pure nothrow @nogc
{
    return SqlValue(ValueKind.int64, value);
}

private Error bindText(ref scope RequestArena arena, scope const(char)[] text, out SqlValue value) nothrow @nogc
{
    const stored = arena.copyIn(cast(const(ubyte)[]) text);
    if (stored.ok())
        value = SqlValue(ValueKind.text, 0, 0, stored.value);
    return stored.error;
}

private bool equalText(ref scope RequestArena arena, SqlValue item, scope const(char)[] expected) nothrow @nogc
{
    if (item.kind != ValueKind.text)
        return false;
    bool equal;
    const copied = arena.read(item.bytes, (scope const(ubyte)[] input) @safe nothrow @nogc {
        equal = cast(const(char)[]) input == expected;
    });
    return copied == Status.ok && equal;
}

Error command(ref Connection connection, scope const(char)[] sql, ref Context context) nothrow @nogc
{
    scope RequestArena unused;
    return connection.execute(sql, [], unused, context).error;
}

struct Prefix
{
    uint matched;
    ulong versionNumber;
}

private enum Issue
{
    none,
    started,
    missing,
    changed
}

private struct Drift
{
    Issue kind;
    ulong versionNumber;
    char[64] hash;
}

private Result!bool readFields(ref Row row, ref scope RequestArena arena, ref Drift drift) nothrow @nogc
{
    if (arena.reset() != Status.ok || row.columns() != 3)
        return Result!bool(false, malformed);
    const id = row.value(0, arena);
    const hash = row.value(1, arena);
    const success = row.value(2, arena);
    if (!id.ok() || !hash.ok() || !success.ok())
        return Result!bool(false, malformed);
    if (id.value.kind != ValueKind.int64 || id.value.integer <= 0 || hash.value.kind != ValueKind.text
            || hash.value.bytes.length() != drift.hash.length || success.value.kind != ValueKind.boolean)
        return Result!bool(false, malformed);

    drift.versionNumber = cast(ulong) id.value.integer;
    const copied = arena.read(hash.value.bytes, (scope const(ubyte)[] input) @safe nothrow @nogc {
        drift.hash[] = cast(const(char)[]) input;
    });
    if (copied != Status.ok)
        return Result!bool(false, malformed);
    return Result!bool(success.value.integer != 0);
}

private Error advance(ref Row row, ref scope RequestArena arena, scope const(Migration)[] plan,
        ref Prefix verified, ref Drift drift) nothrow @nogc
{
    const fields = readFields(row, arena, drift);
    if (!fields.ok())
        return fields.error;
    if (!fields.value)
    {
        if (!validDigestText(drift.hash[]))
            return malformed;
        drift.kind = Issue.started;
    }
    else if (verified.matched >= plan.length || plan[verified.matched].versionNumber != drift.versionNumber)
        drift.kind = Issue.missing;
    else if (!matchDigest(drift.hash[], plan[verified.matched].sha256))
        drift.kind = Issue.changed;

    if (drift.kind != Issue.none)
        return Error(Status.conflict, "migration history validation failed");
    ++verified.matched;
    verified.versionNumber = drift.versionNumber;
    return Error.init;
}

private Error historyError(scope ref const Drift found)
{
    const versionNumber = found.versionNumber.to!string;
    final switch (found.kind)
    {
    case Issue.started:
        enum recovery = " is marked started. Inspect the database and reconcile its history.";
        const hash = found.hash[].idup;
        return Error(Status.conflict, "migration version " ~ versionNumber ~ " checksum " ~ hash ~ recovery);
    case Issue.missing:
        return Error(Status.conflict,
                "applied migration version " ~ versionNumber ~ " is missing from the input order");
    case Issue.changed:
        return Error(Status.conflict, "checksum drift for applied migration version " ~ versionNumber);
    case Issue.none:
        return Error.init;
    }
}
