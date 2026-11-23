module migrate_path_escape;

import flint.engine.migrate : embeddedMigration;

@safe:

private enum migration = embeddedMigration!("../V000001__bootstrap.sql", 1, "bootstrap")();
