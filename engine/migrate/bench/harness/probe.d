/// Equivalent immutable migration bytes and seeded history for the two probes.
module probe;

import core.stdc.stdio : printf;
import core.time : MonoTime;
import flint.arena : Status;
import flint.conc : Context;
import flint.engine.sql : Driver, Pool, PoolOptions;
import std.digest.sha : sha256Of;

@safe:

/// Distinct programs and records loaded per validation.
enum rows = 1000;
private enum checksum = rows * (rows + 1) / 2;

/// Same immutable input and expected database digest for both probes.
struct Entry
{
    /// Positive migration version.
    ulong number;
    /// Embedded original SQL bytes.
    string sql;
    /// SHA-256 over those bytes.
    ubyte[32] digest;
    /// Lowercase representation stored in the seeded history.
    char[64] hex;
}

alias Replay = ulong function(ref Pool, ref Context, scope const(Entry)[]) @safe;

/// Verify behavior in debug and release builds.
void require(bool valid) nothrow @nogc
{
    if (!valid)
        assert(0, "migration probe invariant failed");
}

private ptrdiff_t lineEnd(scope const(char)[] text) pure nothrow @nogc
{
    foreach (index, character; text)
        if (character == '\n')
            return index;
    return -1;
}

private char[64] lowerHex(scope const ref ubyte[32] digest) pure nothrow @nogc
{
    enum digits = "0123456789abcdef";
    char[64] text;
    foreach (index, value; digest)
    {
        text[2 * index] = digits[value >> 4];
        text[2 * index + 1] = digits[value & 0xf];
    }
    return text;
}

private string decimal(ulong value) pure nothrow
{
    char[20] digits;
    size_t start = digits.length;
    do
    {
        digits[--start] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value != 0);
    return digits[start .. $].idup;
}

// SAFETY: Fixed NUL-terminated literal formats with matching scalar arguments.
private void report(ulong observed, bool measure, uint trials, long elapsed) @trusted nothrow @nogc
{
    printf("migration checksum %llu\n", observed);
    if (measure)
        printf("migration rows_per_trial=%d trials=%u elapsed_ns=%lld\n", rows, trials, elapsed);
}

private Entry[] load()
{
    enum programs = import("programs.sql");
    auto entries = new Entry[rows];
    size_t start;
    foreach (index, ref entry; entries)
    {
        const end = lineEnd(programs[start .. $]);
        require(end > 0);
        entry.number = index + 1;
        entry.sql = programs[start .. start + end + 1];
        entry.digest = sha256Of(cast(const(ubyte)[]) entry.sql);
        entry.hex = lowerHex(entry.digest);
        start += end + 1;
    }
    require(start == programs.length);
    return entries;
}

private void seed(ref Pool pool, ref Context context, scope const(Entry)[] entries)
{
    auto lease = pool.acquire(context);
    require(lease.ok());
    scope (exit)
        require(pool.release(lease.value).code == Status.ok);
    const sqlite = pool.driver() == Driver.sqlite;
    enum history = "CREATE TABLE flint_schema_history(version BIGINT PRIMARY KEY, description TEXT NOT NULL, "
        ~ "sha256 CHAR(64) NOT NULL, installed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, "
        ~ "execution_ms BIGINT NOT NULL, success BOOLEAN NOT NULL);";
    const metadata = "flint_schema_history" ~ (sqlite ? "_settings" : "_metadata");
    const schema = sqlite ? "'main'" : "current_schema()";
    const provider = sqlite ? "'sqlite'" : "'postgres'";
    auto setup = history ~ "CREATE TABLE " ~ metadata ~ " (installation_key INTEGER PRIMARY KEY, "
        ~ "effective_schema TEXT NOT NULL, driver TEXT NOT NULL);" ~ "INSERT INTO " ~ metadata
        ~ " VALUES(1," ~ schema ~ "," ~ provider ~ ");"
        ~ "INSERT INTO flint_schema_history(version,description,sha256,execution_ms,success) VALUES";
    foreach (ref const entry; entries)
    {
        setup ~= "(" ~ decimal(entry.number) ~ ",'probe','" ~ entry.hex[] ~ "',1,TRUE)";
        setup ~= entry.number == rows ? ";" : ",";
    }
    const seeded = lease.value.executeScript(setup, context);
    require(seeded.code == Status.ok);
}

private void clean(ref Pool pool, ref Context context)
{
    if (pool.driver() == Driver.sqlite)
        return;
    auto lease = pool.acquire(context);
    require(lease.ok());
    scope (exit)
        require(pool.release(lease.value).code == Status.ok);
    enum drop = "DROP TABLE flint_schema_history_metadata; DROP TABLE flint_schema_history;";
    require(lease.value.executeScript(drop, context).code == Status.ok);
}

/// Seed both variants identically and exercise the replay against the selected driver.
void benchmark(string[] args, Replay replay)
{
    const measure = args.length > 1 && args[1] == "--measure";
    const next = measure ? 2 : 1;
    PoolOptions settings;
    settings.driver = args.length > next ? Driver.postgres : Driver.sqlite;
    settings.connectionString = settings.driver == Driver.postgres ? args[next] : ":memory:";
    settings.maxConnections = 1;
    auto entries = load();
    Context context;
    Pool pool;
    require(pool.open(settings).code == Status.ok);
    scope (exit)
        require(pool.close(context).code == Status.ok);
    seed(pool, context, entries);
    scope (exit)
        clean(pool, context);
    ulong observed;
    uint trials;
    long elapsed;
    do
    {
        const started = MonoTime.currTime;
        observed = replay(pool, context, entries);
        elapsed += (MonoTime.currTime - started).total!"nsecs";
        require(observed == checksum);
        ++trials;
    }
    while (measure && elapsed < 100_000_000);
    report(observed, measure, trials, elapsed);
}
