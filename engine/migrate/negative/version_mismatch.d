module migrate_version_mismatch;

import flint.migrate : embeddedMigration;

@safe:

private enum migration = embeddedMigration!("V000001__bootstrap.sql", 4, "bootstrap")();
