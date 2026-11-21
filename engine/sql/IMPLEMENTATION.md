# flint:sql

Open a pool with a pinned PostgreSQL or SQLite provider. The pool copies the
configuration. A native connection opens on the first statement in its slot.
Acquire takes exclusive possession of one slot until release. The queue grants
leases oldest first, and a release invalidates copies of its handle.
The process-wide directory holds up to 64 open pools.

Use execute or query for one statement at a time. Supply all data through
SqlValue parameters. Text and bytes refer to handles in the given request
arena. The native boundary copies them before submitting the operation.
A query consumer can copy each cell into its arena. The row handle expires
when that callback returns.

PostgreSQL sends typed values in binary format. Its text type rejects embedded
NUL. Use bytes for binary data. SQLite preserves embedded NUL in both text and
bytes. SQLite INTEGER columns declared BOOL or BOOLEAN produce boolean cells.
Untyped integer expressions produce int64 cells.

## Connection and cleanup

SQL calls on a reactor run in a task fiber. PostgreSQL progresses through
libpq's nonblocking connect, send, flush, read and cancellation APIs on the
owner. An owned startup helper runs the initial connection call so name
resolution can leave the reactor. A SQLite connection has one worker. It
prepares, binds, steps and snapshots results before publishing one row at a time.

The connection directory remains occupied until native cancellation or
retirement acknowledges ownership. A bounded cleanup may retire the native
connection. Release rolls back a remaining transaction before it admits a new
lease. The transaction helper rolls back a failed callback and returns an
unknown-outcome error when it loses the commit acknowledgment.

SQLite enables foreign keys and synchronous FULL at startup. A client can
choose another synchronous setting or request WAL through an explicit PRAGMA.
The SQLite authorizer permits WAL only for a database on a recognized local
filesystem.

## Verification

Prepare and link the locked native profile before exercising both drivers.

```sh
python3 tools/native_build.py --profile sql --target linux-x86_64-glibc --phase build --emit-dub
dub test :sql --compiler=dmd
dub test :sql --compiler=ldc2
python3 tools/gates.py --package sql --gate structural
```

Set FLINT_SQL_PG_TEST_DSN to a disposable UTF-8 PostgreSQL instance to run the
live protocol fixtures. The disconnect fixture terminates a connection created
by that test. The native C fixture covers the exact queue cap, invalid inputs,
UTF-8 boundary sizes and retirement while an operation is in flight. Files
under fixtures/negative exercise the private handle boundaries in both D
compilers.

The benchmark and direct-provider control default to a SQLite memory
database and accept a PostgreSQL connection string as a positional argument.
Each trial writes 256 bound values in one transaction and reads them back
through a second prepared statement. Run with --measure to accumulate at
least 100 milliseconds of driver time and report queue wait separately.
