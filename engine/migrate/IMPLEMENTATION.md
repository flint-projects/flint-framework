# flint:engine-migrate

Run versioned SQL programs once, before the application serves traffic. Declare
each program with `embeddedMigration`, which loads a vetted file name from the D
string-import path together with the SHA-256 of its exact bytes. The digest is
computed at compile time, so a CRLF/LF change or any edit to an applied script
is reported as drift instead of being reapplied. `tools/migration_manifest.py`
checks a migrations directory and its sidecar digests.

`migrate(pool, migrations, options, context)` verifies the plan before it
checks out a connection: versions must be positive, unique and ascending, and
every program must be nonempty valid UTF-8 within the size limit whose digest
matches its bytes. `validateHistory` performs the same checks against the
recorded history without applying anything.

## Locking and history

One connection holds a database-scoped lock for the whole run. PostgreSQL
uses `pg_advisory_lock` on a fixed key and SQLite uses `BEGIN IMMEDIATE`. The
wait is bounded by `MigrationOptions.lockTimeoutNanos`. A lock timeout leaves
no partial work and releases the lease. The history table (default
`flint_schema_history`) is created on first use. Each run compares the stored
versions, descriptions and digests with the plan before applying pending
programs, and reports `discovered`, `applied` and `currentVersion`.

## Applying programs

SQLite applies all pending programs and their history rows in the one locked
transaction. PostgreSQL applies each transactional program and its history row
in its own transaction, so a failure leaves earlier versions committed and the
failing one absent. A program marked `transactional = false` (for example
`CREATE INDEX CONCURRENTLY`) first commits a started marker with
`success = FALSE`, runs outside a transaction and then completes the marker.
A crash in between leaves the marker visible, and the next run refuses to
continue until an operator resolves it. Failures name the migration version.

## Verification

`tests/migration_contract.d` covers preflight, history drift, lock timeout and
failure atomicity on SQLite and, when `FLINT_MIGRATE_PG_TEST_DSN` names a
disposable PostgreSQL 18.6 database, on PostgreSQL. `fixtures/run_startup.py`
runs concurrent startups, lock timeouts, rollback and the crash marker as
separate processes. `fixtures/embedding.py` and `negative/` check compile-time
embedding, and `bench/trace/run.py` counts the statements issued to validate
1,000 migrations. `ACCEPTANCE.md` maps every specification item to its test.
