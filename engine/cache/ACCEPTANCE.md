# flint:engine-cache acceptance traceability

Source: `handoff/specs/tier-3/cache.md` section 7 ("Required unit, protocol, fuzz and benchmark acceptance").
Redis rows run under `tests/redis_fixture/run.py`, which starts an ephemeral authenticated Valkey 9.1.2 and the
scripted RESP3 peer (`tests/redis_fixture/server.go`). Start a fresh `run.py` per compiler: the peer's
disconnect counter is per process, so one peer shared by a DMD and an LDC run fails the second
`readText(peer("DROPS")) == "1"` check.

| Spec item | Covering test(s) | Status |
| --- | --- | --- |
| binary_keys — empty and NUL-containing keys/values keep lengths; prefixes do not alias (local, 1 stripe) | `tests/local.d:"binary keys and output are copied by length across TTL and generation boundaries"` | covered |
| binary_keys — eight empty/NUL-prefixed/NUL-suffixed keys and values across 64 stripes | `tests/local.d:"binary_keys: empty, NUL-prefixed and NUL-suffixed keys and values never alias across 64 stripes"` | added |
| binary_keys — Valkey binary keys and values | `tests/redis_behavior.d:"Valkey RESP3 AUTH, binary values, TTL and ordered namespace clear"` | covered |
| capacity_bound — entry and byte pressure evict the expected LRU victim in its stripe; oversized value rejected without flushing | `tests/local.d:"entry and byte pressure evict the least recently touched item in one stripe"` | covered |
| capacity_bound — 1024 keys over 64 stripes stay within the 128-entry cap; 512 records against a 1 KiB byte cap keep at most 32 | `tests/local.d:"capacity_bound: entry and byte caps hold across 64 stripes under 8x entry and 16x byte pressure"` | added |
| capacity_bound — entry capacity below the stripe count stays bounded and sweeps safely | `tests/local.d:"capacity_bound: an entry capacity below the stripe count stays bounded across every stripe"` | added |
| ttl_clock — fake monotonic clock at the exact TTL boundary; a clock moving backwards does not extend life; TTL 0 evicts; negative TTL rejected | `tests/local.d:"binary keys and output are copied by length across TTL and generation boundaries"` (`CacheOptions.clock`) | covered |
| single_flight — 100 waiters, one loader call; 99 cancel and the last succeeds | `tests/local.d:"100 callers share one load and 99 can cancel independently"` | covered |
| single_flight — last waiter leaving cancels the shared load | `tests/local.d:"the monitor cancels a shared loader after its last caller leaves"` | covered |
| evict_loader_race — evict during a load; stale generation cannot resurrect (local) | `tests/local.d:"explicit eviction during a load prevents late publication"`; `tests/local.d:"an explicit put during a load is not overwritten by the late loader result"` | covered |
| evict_loader_race — same through the Redis backend and public facade | `tests/redis_behavior.d:"public Redis cache composes with app fibers and preserves flight eviction order"`, `"a Redis put during a flight is not overwritten by the late loader result"`; `tests/facade_redis.d:"the public Redis cache facade coalesces loader publication with eviction"` | covered |
| resp3_push — PUSH interleaved with replies; requests get the right responses; MOVED/ASK unsupported | `tests/redis_behavior.d:"PUSH messages are retired independently and cluster replies are unsupported"`; native `tests/redis_fixture/native.c` "independent PUSH dispatch with two outstanding tickets" | covered |
| remote_failure — disconnect between request and reply fails pending work once, no mutation retry | `tests/redis_behavior.d:"disconnect settles an uncertain mutation once and never retries it"` (peer counts exactly one mutation) | covered |
| remote_failure — bounded pending queue (1024), cancellation detaches before reuse; oversized/deep/unknown/truncated/cross-namespace replies fail safely | `tests/redis_behavior.d:"retains one bounded pending generation and detaches cancellation before reuse"`, `"oversized, deep, invalid and cross-namespace replies fail safely"` | covered |
| cache_bench — hit/miss/evict contention at 1/8/32 threads, 64 B and 4 KiB; p99 and lock wait | `bench/source/app.d` + `bench/harness/cache_probe.d` (`probe-cache` prints `p99_upper_ns`, `lock_count`, `lock_wait_ns`, `gc_bytes` per row; run here: 6 rows, `gc_bytes=0`) | covered |
| Native boundary corpora under ASan | `tests/redis_fixture/native.py` (C shim + `native.c` with `-fsanitize=address,undefined`, leak detection, against Valkey and the scripted peer) | covered (run) |
| LDC D sanitizer configuration | whole D suite under LDC `-fsanitize=address` (`--build=plain`, `ASAN_OPTIONS=detect_leaks=0`) inside `tests/redis_fixture/run.py` | covered (run) |
| Fuzz seeds: truncated input, maximum lengths, empty values, cancellation, generation reuse | native corpus (16 MiB reply, nesting, truncated RESP, unexpected tags); empty key/value rows; cancellation rows above; generation rows (`clear`/evict during flight) | covered |
| Compile-fail tests assert nonzero exit and stable diagnostic | `negative/redis_reply_escape.d`, `negative/redis_worker_escape.d`, `negative/redis_private_bridge.d`, run by `tests/redis_fixture/negative.py dmd` and `... ldc2` | covered |

## Stub review

No always-success paths found. `Cache.close` on a never-opened handle and `sweep` are intentional.
The stripe count is already clamped to the entry capacity (`State` constructor), which the new capacity test exercises.

## Commands

```sh
go build -trimpath -o <dir>/redis-fixture engine/cache/tests/redis_fixture/server.go
python3 engine/cache/tests/redis_fixture/run.py --server <dir>/redis-fixture --valkey <valkey-server> -- dub test :cache --compiler=dmd
python3 engine/cache/tests/redis_fixture/run.py --server <dir>/redis-fixture --valkey <valkey-server> -- dub test :cache --compiler=ldc2
python3 engine/cache/tests/redis_fixture/native.py --prefix <native-prefix> --server <dir>/redis-fixture --valkey <valkey-server> --output <dir>/corpus
python3 engine/cache/tests/redis_fixture/negative.py dmd    # and ldc2
engine/cache/bench/build/probe-cache
```
