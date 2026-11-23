module app;

import flint.arena : Error, RequestArena, Status;
import flint.conc : Context;
import flint.engine.sql : Driver, Pool, PoolOptions, Row, SqlValue, ValueKind;
import probe : measureTrial, nanos, require, rows, schema;

@safe:

private ulong trial(string address, out long queue, out long driver)
{
    PoolOptions options;
    options.maxConnections = 1;
    options.driver = address.length != 0 ? Driver.postgres : Driver.sqlite;
    options.connectionString = address.length != 0 ? address : ":memory:";
    Pool pool;
    require(pool.open(options).code == Status.ok);
    Context context;
    scope (exit)
        require(pool.close(context).code == Status.ok);

    const start = nanos();
    auto acquired = pool.acquire(context);
    queue = nanos() - start;
    require(acquired.ok());
    auto lease = acquired.value;
    scope (exit)
        require(pool.release(lease).code == Status.ok);
    scope RequestArena arena;
    require(lease.execute(schema, [], arena, context).ok());

    const insert = options.driver == Driver.sqlite
        ? "INSERT INTO flint_probe VALUES (?)" : "INSERT INTO flint_probe VALUES ($1)";
    const select = options.driver == Driver.sqlite
        ? "SELECT id FROM flint_probe WHERE id=?" : "SELECT id FROM flint_probe WHERE id=$1";
    const begin = nanos();
    require(lease.execute("BEGIN", [], arena, context).ok());
    foreach (value; 1 .. rows + 1)
    {
        const SqlValue[1] param = [SqlValue(ValueKind.int64, value)];
        const inserted = lease.execute(insert, param[], arena, context);
        require(inserted.ok() && inserted.value == 1);
    }
    require(lease.execute("COMMIT", [], arena, context).ok());

    ulong total;
    foreach (value; 1 .. rows + 1)
    {
        const SqlValue[1] param = [SqlValue(ValueKind.int64, value)];
        uint found;
        const selected = lease.query(select, param[], arena, context, (ref Row row) @safe nothrow @nogc {
            const result = row.value(0, arena);
            require(result.ok() && result.value.kind == ValueKind.int64 && result.value.integer == value);
            total += result.value.integer;
            ++found;
            return Error.init;
        });
        require(selected.code == Status.ok && found == 1);
    }
    driver = nanos() - begin;
    return total;
}

void main(string[] args)
{
    const measure = args.length > 1 && args[1] == "--measure";
    const index = measure ? 2 : 1;
    const address = args.length > index ? args[index] : null;
    measureTrial((out long queue, out long driver) => trial(address, queue, driver), measure);
}
