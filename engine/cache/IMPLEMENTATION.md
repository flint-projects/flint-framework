# flint:engine-cache

Open one cache with a byte limit, entry limit and finite default TTL. Keys and values
are binary slices, and a hit is copied to the caller's request arena. Explicit TTL
uses nanoseconds. Zero evicts the key. Use the `local` DUB configuration for an
application that links without hiredis.

The local provider uses striped hash tables with per-stripe LRU lists. The global
payload budget accounts for every admitted key and value. A monotonic watermark
handles local TTL. Call `sweep` to examine up to 64 metadata slots per tick.

`getOrLoad` coalesces one loader per key. Each waiter has its own context. The
shared loader context cancels when all admitted waiters leave. Values and keys in
flight are owned, and explicit eviction or clear invalidates earlier loads. The
loader executes outside the cache locks.

Bind cacheable application methods obtained from DI with
`registerCachedCall!(Service.lookup, "v1")`. Supply the named cache from its
`Cacheable` annotation. Parameter DTOs should contain the full lookup identity.
The binary key combines the method and parameter type, explicit schema version
and canonical JSON for the parameter value. The adapter uses a scratch arena for
serialized bytes and a separate arena for decoded results. Call
`evictCommitted!(Service.update, Service.lookup, "v1", Parameters)` with the
transaction outcome to invalidate the corresponding read. Set `allEntries` on
`CacheEvict` to clear the configured cache after commit.

The Redis backend uses a dedicated Linux reactor worker and pinned hiredis
RESP3 with verified TLS for nonlocal endpoints. It authenticates during HELLO,
dispatches PUSH traffic separately, and bounds outstanding requests and parsed
reply trees. Namespace clear scans and deletes only matching encoded keys on the
configured primary. MOVED and ASK report unsupported. A lost connection fails
pending work once. A later call can reconnect; mutations are issued once.

The local contention fixtures exercise hits, misses, replacements and evictions
with 64- and 4096-byte values at 1, 8 and 32 threads. The Redis fixtures use
Valkey with TLS, authentication, binary keys, kernel socket I/O, invalid replies
and disconnection while a mutation is pending. The Redis size baseline performs
its workload through pinned hiredis directly.
