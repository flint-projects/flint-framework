/// Embedded startup migrations with database-scoped locking and history validation.
module flint.migrate;

import flint.arena : Error, Result;
import flint.conc : Context;
import flint.migrate.runner : migratePool;
import flint.sql : Pool;
public import flint.migrate.embedding : embeddedMigration;
public import flint.migrate.types : Migration, MigrationOptions, MigrationReport;

@safe:

/// Verify the existing history and apply pending SQL before serving traffic.
Result!MigrationReport migrate(ref Pool pool, scope const(Migration)[] migrations,
        MigrationOptions options, ref Context context)
{
    return migratePool(pool, migrations, options, context);
}

/// Check the default history table without applying the migration programs.
Error validateHistory(ref Pool pool, scope const(Migration)[] migrations, ref Context context)
{
    MigrationOptions options;
    options.validateOnly = true;
    return migratePool(pool, migrations, options, context).error;
}
