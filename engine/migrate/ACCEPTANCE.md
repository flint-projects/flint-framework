# flint:engine-migrate acceptance traceability

Source: `handoff/specs/tier-3/migrate.md` section 7 ("Required unit, protocol, fuzz and benchmark acceptance").
PostgreSQL rows run when `FLINT_MIGRATE_PG_TEST_DSN` names a disposable PostgreSQL 18.6 database (D suite) or when
`--postgres` names an empty one (process fixtures); both were run against a local 18.6 instance.

| Spec item | Covering test(s) | Status |
| --- | --- | --- |
| embedded_bytes — same script compiled twice gives identical bytes/hash | `fixtures/embedding.py <compiler>` (compiles `fixtures/embed.d` twice and compares output with Python `hashlib`), DMD and LDC | covered |
| embedded_bytes — one CRLF/LF change produces checksum drift | `fixtures/embedding.py` (CRLF rewrite changes the embedded digest); `tests/migration_contract.d:"Migration preflight rejects order, malformed program bytes and mismatched digests before checkout"` (`SELECT 1\r\n` → `conflict`); drift row below | covered |
| embedded_bytes — invalid filename/version/sidecar and oversize/invalid UTF-8 fail compile | `negative/path_escape.d`, `negative/version_mismatch.d`, `negative/invalid_sidecar.d` and size/encoding cases in `fixtures/embedding.py`; `tools/migration_manifest.py --check` on `tests/migrations` | covered |
| order_validation — duplicate, zero and out-of-order versions fail before opening the database | `tests/migration_contract.d:"Migration preflight rejects order, malformed program bytes and mismatched digests before checkout"` (uses a never-opened `Pool`; empty description, empty/NUL/invalid UTF-8 SQL and 1 MiB+1 also rejected) | covered |
| history_drift — modified applied migration fails startup without executing new scripts | `exerciseHistory` in `"SQLite startup uses one real-parser transaction with durable history and drift checks"` and `"PostgreSQL migrations preserve complete SQL bodies and support explicit concurrent index creation"` | covered |
| history_drift — removed applied migration fails startup | same (`is missing`, row count unchanged) | covered |
| transaction_rollback — insert then fail; data and success history absent | `exerciseHistory` (both drivers); `fixtures/concurrency.py` `fail` mode (separate process, SQLite) via `fixtures/run_startup.py` | covered |
| concurrent_start — two processes, each migration applies once, second sees completed history | `fixtures/concurrency.py` `concurrent()` on SQLite and PostgreSQL, built and run by `fixtures/run_startup.py` (DMD and LDC) | added (runner) |
| lock_timeout — held lock, deadline expires, no partial work, no leaked connection (process level) | `fixtures/concurrency.py` `timeout()` (SQLite and PostgreSQL; probe checks no advisory lock remains and the single pooled lease is reusable) via `fixtures/run_startup.py` | added (runner) |
| lock_timeout — same with a pending migration in-process: `timedOut`, no history table or migration object created, lease returned, later run applies | `tests/migration_contract.d:"lock_timeout: a held SQLite write lock times out with no partial work or leaked lease"`; `"lock_timeout: a held PostgreSQL advisory lock times out with no partial work or leaked lease"` | added |
| sql_program — dollar-quoted PostgreSQL functions, semicolons in strings/comments | `"PostgreSQL migrations preserve complete SQL bodies and support explicit concurrent index creation"` | covered |
| sql_program — SQLite triggers execute intact; script transaction control rejected | `"SQLite startup uses one real-parser transaction with durable history and drift checks"` | covered |
| nontransactional_recovery — crash after started marker; next startup blocks with version/hash; never retried or marked success | `fixtures/concurrency.py` `crash()` (PostgreSQL; kills the worker while its nontransactional `pg_sleep` migration runs, then asserts the version/checksum message and that the unsuccessful marker remains) via `fixtures/run_startup.py` | added (runner) |
| nontransactional_recovery — explicit nontransactional success path; SQLite nontransactional rejected | PostgreSQL `CREATE INDEX CONCURRENTLY` row and SQLite `unsupported` row in the two driver tests | covered |
| migration_bench — load/validate 1000 embedded migrations; bounded startup query count | `bench/trace/run.py <compiler> <dir> [--postgres dsn]` (links `bench/trace/provider.c` with `--wrap`; one validateOnly run over 1000 entries issues 6 SQLite / 7 PostgreSQL provider statements; cap 12), DMD and LDC | added (runner) |
| migration_bench — compiler template counts | canonical fixture measured by `tools/measure_builds.py`: 1580 instances ≤ 2000 (`artifacts/tasks/m6-integration/complete-run/builds.json`); not re-measured in this pass | covered (existing evidence) |
| Native boundary corpora under ASan / LDC sanitizer configuration | whole D suite (both drivers) under LDC `-fsanitize=address` (`--build=plain`, `ASAN_OPTIONS=detect_leaks=0`); no migrate-owned C code (SQL shim corpus: `engine/sql/tests/native_asan.py`) | covered (run) |
| Fuzz seeds: truncated input, maximum lengths, empty values, cancellation | preflight test (empty/whitespace, truncated UTF-8, 1 MiB boundary); `executeScript` deadline → `timedOut` then reuse in the PostgreSQL test; lock_timeout rows | covered |
| Compile-fail tests assert nonzero exit and stable diagnostic | `negative/*.d` via `fixtures/embedding.py` | covered |

## Stub review

No always-success paths found. Note: `IMPLEMENTATION.md` still carries the scaffold placeholder text ("intentionally
contains no production implementation") although the package is implemented; it was left unchanged.

## Commands

```sh
FLINT_MIGRATE_PG_TEST_DSN=... dub test :migrate --compiler=dmd
FLINT_MIGRATE_PG_TEST_DSN=... dub test :migrate --compiler=ldc2
python3 engine/migrate/fixtures/embedding.py dmd    # and ldc2
python3 engine/migrate/fixtures/run_startup.py dmd <dir> --postgres <empty-db-dsn>    # and ldc2
python3 engine/migrate/bench/trace/run.py dmd <dir> --postgres <dsn>    # and ldc2
python3 tools/migration_manifest.py --input engine/migrate/tests/migrations \
  --output engine/migrate/fixtures/generated_plan.d --module generated_plan --check
```
