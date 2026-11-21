module migration_contract;

import flint.arena : Error, RequestArena, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.migrate : Migration, MigrationOptions, migrate, validateHistory;
import flint.sql : Driver, Pool, PoolOptions, Row, ValueKind;
import std.digest.sha : sha256Of;
import std.process : environment;
import std.string : indexOf, replace;
import std.uuid : randomUUID;

@safe:

private Migration program(ulong number, string text, bool transactional = true)
{
    return Migration(number, "fixture", text, sha256Of(cast(const(ubyte)[]) text), transactional);
}

private Pool open(Driver driver, string address)
{
    Pool pool;
    PoolOptions options;
    options.driver = driver;
    options.connectionString = address;
    options.maxConnections = 1;
    const status = pool.open(options);
    assert(status.code == Status.ok, status.message);
    return pool;
}

private void command(ref Pool pool, ref Context context, scope const(char)[] text)
{
    auto lease = pool.acquire(context);
    assert(lease.ok(), lease.error.message);
    scope (exit)
        assert(pool.release(lease.value).code == Status.ok);
    scope RequestArena unused;
    const result = lease.value.execute(text, [], unused, context);
    assert(result.ok(), result.error.message);
}

private long count(ref Pool pool, ref Context context, scope const(char)[] text)
{
    auto lease = pool.acquire(context);
    assert(lease.ok(), lease.error.message);
    scope (exit)
        assert(pool.release(lease.value).code == Status.ok);
    scope RequestArena unused;
    bool seen;
    long count;
    const status = lease.value.query(text, [], unused, context, (ref Row row) @safe nothrow @nogc {
        const value = row.value(0, unused);
        assert(!seen && value.ok() && value.value.kind == ValueKind.int64);
        count = value.value.integer;
        seen = true;
        return Error.init;
    });
    assert(status.code == Status.ok, status.message);
    assert(seen);
    return count;
}

@("Migration preflight rejects order, malformed program bytes and mismatched digests before checkout")
unittest
{
    Pool unavailable;
    Context context;
    const one = program(1, "SELECT 1");
    const two = program(2, "SELECT 2");
    Migration zero = one;
    zero.versionNumber = 0;
    assert(migrate(unavailable, [zero], MigrationOptions.init, context).error.code == Status.invalidArgument);
    assert(migrate(unavailable, [one, one], MigrationOptions.init, context).error.code == Status.invalidArgument);
    assert(migrate(unavailable, [two, one], MigrationOptions.init, context).error.code == Status.invalidArgument);
    foreach (sql; ["", " \n\r\t", "SELECT \0 1", "SELECT '\xC2'", "SELECT '\xED\xA0\x80'"])
    {
        const invalid = program(1, sql);
        assert(migrate(unavailable, [invalid], MigrationOptions.init, context).error.code == Status.invalidArgument);
    }
    Migration wrongBytes = one;
    wrongBytes.sql = "SELECT 1\r\n";
    assert(migrate(unavailable, [wrongBytes], MigrationOptions.init, context).error.code == Status.conflict);
    Migration emptyDescription = one;
    emptyDescription.description = "";
    assert(migrate(unavailable, [emptyDescription], MigrationOptions.init, context).error.code == Status
            .invalidArgument);
    auto large = new char[1_048_577];
    large[] = ' ';
    large[0 .. 8] = "SELECT 1";
    const allowed = program(1, large[0 .. $ - 1].idup);
    assert(migrate(unavailable, [allowed], MigrationOptions.init, context)
            .error.message == "SQL pool rejected acquisition");
    const excessive = program(1, large.idup);
    assert(migrate(unavailable, [excessive], MigrationOptions.init, context).error.code == Status.invalidArgument);
}

private void exerciseHistory(ref Pool pool, ref Context context, string bootstrap,
        string relationCount, string metadataTable)
{
    auto plan = [program(1, bootstrap)];
    assert(validateHistory(pool, plan, context).code == Status.ok);
    assert(count(pool, context, relationCount) == 0);

    auto applied = migrate(pool, plan, MigrationOptions.init, context);
    assert(applied.ok(), applied.error.message);
    assert(applied.value.discovered == 1 && applied.value.applied == 1 && applied.value.currentVersion == 1);
    assert(count(pool, context, "SELECT COUNT(*) FROM migrated_rows WHERE label='value;with;semicolons'") == 1);

    const follow = program(2, "INSERT INTO migrated_rows VALUES (2,'will not run')");
    const drifted = [program(1, bootstrap ~ "\r\n"), follow];
    const drift = migrate(pool, drifted, MigrationOptions.init, context);
    assert(drift.error.code == Status.conflict && drift.error.message.indexOf("checksum drift") >= 0);
    const removed = migrate(pool, [follow], MigrationOptions.init, context);
    assert(removed.error.code == Status.conflict && removed.error.message.indexOf("is missing") >= 0);
    assert(count(pool, context, "SELECT COUNT(*) FROM migrated_rows") == 1);

    const badProgram = program(2,
            "INSERT INTO migrated_rows VALUES(2,'must roll back');" ~ "INSERT INTO missing_table VALUES (2);");
    const failed = migrate(pool, plan ~ badProgram, MigrationOptions.init, context);
    assert(!failed.ok() && failed.error.message.indexOf("migration version 2 failed") >= 0, failed.error.message);
    assert(failed.value.currentVersion == 1 && failed.value.applied == 0);
    assert(count(pool, context, "SELECT COUNT(*) FROM migrated_rows") == 1);
    assert(count(pool, context, "SELECT COUNT(*) FROM flint_schema_history") == 1);

    const escape = program(2, "INSERT INTO migrated_rows VALUES(2,'no escape'); /* ; */ END; SELECT 1;");
    const refused = migrate(pool, plan ~ escape, MigrationOptions.init, context);
    assert(!refused.ok(), "script transaction control was accepted");
    assert(count(pool, context, "SELECT COUNT(*) FROM migrated_rows") == 1);

    const verified = migrate(pool, plan, MigrationOptions.init, context);
    assert(verified.ok() && verified.value.applied == 0 && verified.value.currentVersion == 1, verified.error.message);
    command(pool, context, "UPDATE " ~ metadataTable ~ " SET driver='different'");
    assert(validateHistory(pool, plan, context).code == Status.conflict);
    const restored = pool.driver() == Driver.sqlite ? "sqlite" : "postgres";
    command(pool, context, "UPDATE " ~ metadataTable ~ " SET driver='" ~ restored ~ "'");
}

version (FlintNativeSqlite) @("SQLite startup uses one real-parser transaction with durable history and drift checks")
unittest
{
    auto pool = open(Driver.sqlite, ":memory:");
    Context context;
    scope (exit)
        assert(pool.close(context).code == Status.ok);
    enum bootstrap = "CREATE TABLE migrated_rows (id BIGINT PRIMARY KEY, label TEXT);"
        ~ "CREATE TABLE source_rows (id BIGINT);"
        ~ "CREATE TRIGGER fixture_trigger AFTER INSERT ON source_rows BEGIN"
        ~ " INSERT INTO migrated_rows VALUES(new.id, 'value;with;semicolons');"
        ~ " SELECT ';'; END;" ~ "INSERT INTO source_rows VALUES(1); -- a literal semicolon ;\n";
    exerciseHistory(pool, context, bootstrap,
            "SELECT COUNT(*) FROM main.sqlite_schema WHERE name='flint_schema_history'",
            "flint_schema_history_settings");
    const nontransactional = program(2, "CREATE TABLE unreachable(id BIGINT)", false);
    assert(migrate(pool, [program(1, bootstrap), nontransactional], MigrationOptions.init, context)
            .error.code == Status.unsupported);
    assert(count(pool, context, "SELECT COUNT(*) FROM main.sqlite_schema WHERE name='unreachable'") == 0);
}

version (FlintNativeLibpq) @(
        "PostgreSQL migrations preserve complete SQL bodies and support explicit concurrent index creation")
unittest
{
    const address = environment.get("FLINT_MIGRATE_PG_TEST_DSN");
    if (address.length == 0)
        return;
    auto pool = open(Driver.postgres, address);
    Context context;
    scope (exit)
        assert(pool.close(context).code == Status.ok);
    const schema = "flint_migration_" ~ randomUUID().toString().replace("-", "");
    command(pool, context, "CREATE SCHEMA " ~ schema);
    scope (exit)
        command(pool, context, "DROP SCHEMA " ~ schema ~ " CASCADE");
    command(pool, context, "SET search_path=" ~ schema);
    enum bootstrap = "/* outer /* another ; */ comment */"
        ~ "CREATE FUNCTION startup_label() RETURNS TEXT AS $body$ BEGIN RETURN 'value;with;semicolons';"
        ~ "END; $body$ LANGUAGE plpgsql;" ~ "CREATE TABLE migrated_rows (id BIGINT PRIMARY KEY, label TEXT);"
        ~ "INSERT INTO migrated_rows VALUES(1, startup_label());";
    exerciseHistory(pool, context, bootstrap, "SELECT COUNT(*) FROM information_schema.tables"
            ~ " WHERE table_schema=current_schema() AND table_name='flint_schema_history'",
            "flint_schema_history_metadata");

    const concurrent = program(2, "CREATE INDEX CONCURRENTLY migrated_label ON migrated_rows (label)", false);
    const applied = migrate(pool, [program(1, bootstrap), concurrent], MigrationOptions.init, context);
    assert(applied.ok(), applied.error.message);
    assert(applied.value.currentVersion == 2 && applied.value.applied == 1);
    enum indexCount = "SELECT COUNT(*) FROM pg_indexes WHERE schemaname=current_schema() "
        ~ "AND indexname='migrated_label'";
    assert(count(pool, context, indexCount) == 1);
    assert(count(pool, context, "SELECT COUNT(*) FROM flint_schema_history WHERE success") == 2);

    auto lease = pool.acquire(context);
    assert(lease.ok(), lease.error.message);
    scope (exit)
        assert(pool.release(lease.value).code == Status.ok);
    auto source = CancelSource.create(Context.init, Deadline.afterMillis(50));
    assert(source.ok());
    auto limited = source.value.context();
    assert(lease.value.executeScript("SELECT pg_sleep(5); SELECT 1;", limited).code == Status.timedOut);
    scope RequestArena unused;
    assert(lease.value.execute("SELECT 1", [], unused, context).ok());
}
