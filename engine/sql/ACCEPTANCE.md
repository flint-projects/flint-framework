# flint:engine-sql acceptance traceability

Source: `handoff/specs/tier-3/sql.md` section 7 ("Required unit, protocol, fuzz and benchmark acceptance").
PostgreSQL rows run when `FLINT_SQL_PG_TEST_DSN` names a disposable PostgreSQL 18.6 database; they were run
against a local 18.6 instance on both compilers. SQLite rows always run when the native profile is linked.

| Spec item | Covering test(s) | Status |
| --- | --- | --- |
| bind_injection — quote/comment/semicolon payloads remain data, structure unchanged (SQLite) | `tests/contract_tests.d:"bind_injection: SQLite quote, comment, semicolon and NUL payloads stay data"`; `tests/contract_tests.d:"SQLite typed values, explicit binding, statement boundaries and stale rows"` | added |
| bind_injection — same payloads on PostgreSQL | `tests/contract_tests.d:"bind_injection and value_nulls: PostgreSQL payloads stay data and NULLs stay distinct"` | added |
| bind_injection — embedded NUL stays data (bytes on both drivers; text on SQLite, explicit `invalidArgument` for PostgreSQL text) | `tests/contract_tests.d:"SQLite typed values, explicit binding, statement boundaries and stale rows"`, `tests/contract_tests.d:"PostgreSQL typed values and live cancel drain with transaction reset"` (`exerciseTextRules`); NUL bytes in both bind_injection tests | covered |
| bind_injection — multi-statement text is rejected rather than executed | `exerciseValues` (`SELECT 1; SELECT 2` → `invalidArgument`) in the two typed-values tests | covered |
| value_nulls — NULL/empty text/empty blob/zero/false distinct, SQLite | `tests/contract_tests.d:"value_nulls: SQLite NULL, empty text, empty blob, zero and false stay distinct"`; `tests/contract_tests.d:"SQLite typed values, explicit binding, statement boundaries and stale rows"` | added |
| value_nulls — same, PostgreSQL | `tests/contract_tests.d:"bind_injection and value_nulls: PostgreSQL payloads stay data and NULLs stay distinct"`; `tests/contract_tests.d:"PostgreSQL typed values and live cancel drain with transaction reset"` | added |
| pool_saturation — 16 active leases + 256 waiters bounded; waiter 257 fails promptly; cancelled waiters leave the queue (D API, 256 threads) | `tests/contract_tests.d:"pool_saturation: 16 leases and 256 queued waiters stay bounded, waiter 257 fails and cancelled waiters leave"` | added |
| pool_saturation — exact queue cap, withdrawal and FIFO head at the C boundary | `native/ffi/sql_native_test.c` `saturation()`, run by `tests/native_asan.py` | added (runner) |
| pool_saturation — 16 leases with no waiters reject; released copies are stale | `tests/contract_tests.d:"Sixteen live SQLite leases saturate and cannot be used after release"`; `tests/contract_tests.d:"an exhausted pool hands a released lease to its queued waiter without a polling stall"` | covered |
| pg_cancel_drain — cancel `pg_sleep`, reuse immediately, no old result, no aborted transaction | `tests/contract_tests.d:"PostgreSQL typed values and live cancel drain with transaction reset"` (same backend PID after release, `SELECT 123` returns 123 inside the formerly open transaction's session) | covered |
| pg_cancel_drain — cancellation on a reactor keeps the owner heartbeat and leaves the pool reusable | `tests/offload.d:"libpq socket progression and cancellation preserve owner reactor heartbeat"` | covered |
| sqlite_busy — write lock held by another connection; timeout returns without blocking a reactor heartbeat | `tests/offload.d:"Busy SQLite uses a worker and permits reactor heartbeat during cancellation"` | covered |
| transaction_atomic — two-step mutation with callback failure rolls back both | `exerciseTransaction` in `tests/contract_tests.d:"SQLite typed values, explicit binding, statement boundaries and stale rows"` and `"PostgreSQL typed values and live cancel drain with transaction reset"`; nested call rejected with `conflict` in the same helper | covered |
| transaction_atomic — commit ambiguity surfaced, never retried | `tests/contract_tests.d:"PostgreSQL disconnect prevents reuse and surfaces a commit without acknowledgment"` (now also asserts the body ran exactly once) | added (assertion) |
| transaction_atomic — server-side ROLLBACK answering COMMIT is a failure | `tests/contract_tests.d:"PostgreSQL reports a commit that the server turned into a rollback as a failure"` | covered |
| prepared_eviction — 129 distinct statements evict one safely; evicted statement re-runs | `exercisePrepared` in both typed-values tests | covered |
| prepared_eviction — execution after schema invalidation replans or reports a typed error | `exercisePrepared` (`ALTER TABLE` then cached `SELECT *` → ok or `unsupported`) | covered |
| row_lifetime — saved Row rejected after callback/query completion before reading C memory | `exerciseValues` (`saved.columns() == 0`, `saved.value(0)` → `notFound`); C corpus `invalid_native_input()` row info/copy on unknown generations | covered |
| row_lifetime — Row/lease cannot be forged | `fixtures/negative/forge_row.d`, `fixtures/negative/forge_lease.d`, run by `fixtures/negative/verify.py` (DMD and LDC, exit 1 + stable diagnostic) | added (runner) |
| sql_bench — prepared SELECT and INSERT/transaction on loopback PostgreSQL and local SQLite; queue wait and driver time separate | `bench/source/app.d` (`probe-sql --measure` and `probe-sql --measure <dsn>`; prints `queue_ns` and `driver_ns`) | covered |
| Native boundary corpora under AddressSanitizer | `tests/native_asan.py` (shims + `sql_native_test.c` with `-fsanitize=address,undefined`, leak detection on) | added |
| LDC D sanitizer configuration | whole D suite (SQLite + PostgreSQL rows) under `DFLAGS='-g -O1 -unittest -preview=dip1000 -boundscheck=on -fsanitize=address' dub test :sql --compiler=ldc2 --build=plain` with `ASAN_OPTIONS=detect_leaks=0` (the D GC is not leak-tracked); native archives are the uninstrumented pinned profile, the C shims are covered instrumented by `tests/native_asan.py` | covered (run) |
| Fuzz seeds: truncated input, maximum lengths, empty values, cancellation, generation reuse | `native/ffi/sql_native_test.c` (`boundary_values()` 0..256 B, 1 KiB±1, 1 MiB±1, trailing invalid UTF-8 byte; overlong UTF-8; `dropped_operations()` cancel/abort 128 times; stale generation release), run under ASan by `tests/native_asan.py` | covered |
| Compile-fail tests assert nonzero exit and stable diagnostic category | `fixtures/negative/verify.py` | added |

## Stub review

No always-success paths found. `Pool.close` on an unopened pool and `Connection.retire` are deliberate no-op/void
operations. `Transactional` is metadata only; the spec limits it to generated registered calls.

## Commands

```sh
FLINT_SQL_PG_TEST_DSN=... dub test :sql --compiler=dmd
FLINT_SQL_PG_TEST_DSN=... dub test :sql --compiler=ldc2
python3 packages/engine-sql/fixtures/negative/verify.py <log-dir>
python3 packages/engine-sql/tests/native_asan.py --prefix <native>/install/linux-x86_64-glibc --output <dir>
packages/engine-sql/bench/build/probe-sql --measure [<dsn>]
DFLAGS='-g -O1 -unittest -preview=dip1000 -boundscheck=on -fsanitize=address' ASAN_OPTIONS=detect_leaks=0 \
  dub test :sql --compiler=ldc2 --build=plain
```
| driver failures carry SQLSTATE, vendor code and message; the next statement clears them (both drivers) | `tests/failures.d:"SQLite failures carry SQLSTATE, extended result code and message, and rows carry column labels"`, `tests/failures.d:"PostgreSQL failures carry the server's SQLSTATE and message, and rows carry column labels"` | added |
| column labels, including labels longer than the engine's local span and PostgreSQL's 63-byte truncation | `tests/failures.d` (`exerciseLongName`); `native/ffi/sql_native_test.c` `failures_and_names()` | added |
| failure message cut at 255 bytes on a UTF-8 boundary; stale lease and row identities refused at the C boundary | `native/ffi/sql_native_test.c` `failures_and_names()`, run by `tests/native_asan.py` | added |
