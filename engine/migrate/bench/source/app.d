module app;

import flint.conc : Context;
import flint.engine.migrate : Migration, MigrationOptions, migrate;
import flint.engine.sql : Pool;
import probe : Entry, benchmark, require, rows;

@safe:

private ulong validate(ref Pool pool, ref Context context, scope const(Entry)[] entries)
{
    Migration[] plan;
    plan.reserve(entries.length);
    foreach (ref const entry; entries)
        plan ~= Migration(entry.number, "probe", entry.sql, entry.digest);
    MigrationOptions options;
    options.validateOnly = true;
    const outcome = migrate(pool, plan, options, context);
    require(outcome.ok());
    require(outcome.value.discovered == rows && outcome.value.applied == 0);
    require(outcome.value.currentVersion == rows);
    return outcome.value.currentVersion * (1 + outcome.value.currentVersion) / 2;
}

void main(string[] args)
{
    benchmark(args, &validate);
}
