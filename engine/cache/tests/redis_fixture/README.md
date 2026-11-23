# Redis and Valkey verification

The Linux Redis backend uses one private Reactor owner for its hiredis connection. Producers submit length-delimited commands to a bounded ticket queue. The owner performs DNS setup off application loops, drives socket readiness, negotiates RESP3 with optional HELLO AUTH, and settles copied replies. A cancelled waiter retires independently of any command already accepted by Redis. The backend does not retry mutations. Closing cancels pending tickets, drains hiredis callbacks, and joins the owner.

Plain redis URLs accept loopback literals and localhost. Use rediss for other hosts. TLS checks the expected DNS name or IP address against the peer certificate and uses the Linux trust store or CacheOptions.redisCaBundle. CacheOptions.redisNamespace defaults to default. Choose distinct namespaces for isolated stores. Clear serializes a bounded SCAN and DEL pass and checks each returned key prefix. Cancellation can end a clear after it has removed earlier pages.

Each connection supports 1,024 pending tickets, a 16 MiB aggregate reply limit, and 32 nested reply levels. Queued commands, the hiredis write buffer, and retained replies each have a byte limit. PUSH is consumed separately from request completions. MOVED and ASK are reported as unsupported.

## Protocol and sanitizer checks

Prepare the pinned provider, build the Go fixture, and supply a Valkey server binary. The runner starts ephemeral loopback peers and a TLS endpoint for the probe.

~~~sh
python3 tools/native_build.py --library hiredis --target linux-x86_64-glibc --phase build --emit-dub
go build -trimpath -o artifacts/redis-fixture engine/cache/tests/redis_fixture/server.go
python3 engine/cache/tests/redis_fixture/run.py --server artifacts/redis-fixture \
  --valkey "$VALKEY_SERVER" -- dub test :cache --compiler=dmd
python3 engine/cache/tests/redis_fixture/run.py --server artifacts/redis-fixture \
  --valkey "$VALKEY_SERVER" -- dub test :cache --compiler=ldc2
python3 engine/cache/tests/redis_fixture/native.py --prefix "$FLINT_NATIVE_PREFIX" \
  --server artifacts/redis-fixture --valkey "$VALKEY_SERVER" --output artifacts/redis-native-corpus
~~~

## Redis release probes

The feature and reference exercise SET with TTL, a hit, eviction, and a miss against real Valkey over a warmed TLS connection. They check 1,024 cycles each at 64 bytes and 4 KiB, emit matching checksums, and report cycle p99 and D GC allocation. The native corpus separately observes native allocation calls.

~~~sh
python3 engine/cache/bench/redis/check.py --prefix "$FLINT_NATIVE_PREFIX" \
  --server artifacts/redis-fixture --valkey "$VALKEY_SERVER" --output artifacts/cache-redis-probes
~~~
