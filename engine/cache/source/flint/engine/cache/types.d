module flint.engine.cache.types;

import flint.arena : Buffer, RequestArena, Result;
import flint.conc : Context;

@safe:

package(flint.engine.cache) alias Bytes = const(ubyte)[];

/// Compile-time marker for an explicitly registered cached invocation.
struct Cacheable
{
    /// Name of the cache bound by the invocation provider.
    string cache;
}

/// Compile-time marker for eviction after a successful invocation.
struct CacheEvict
{
    /// Name of the cache bound by the invocation provider.
    string cache;
    /// Clear the entire configured cache after a confirmed result.
    bool allEntries;
}

/// Native provider selected once when a cache opens.
enum CacheBackend : ubyte
{
    local,
    redis
}

/// Clock override for deterministic tests and monotonic simulation.
alias CacheClock = long function() @safe nothrow @nogc;

/// Payload, entry and connection settings for a cache instance.
struct CacheOptions
{
    /// In-process storage or RESP3 through the native provider.
    CacheBackend backend = CacheBackend.local;
    /// Total admitted key and value bytes.
    size_t byteCapacity = 64 * 1024 * 1024;
    /// Maximum admitted entries in the local store.
    uint entryCapacity = 65_536;
    /// Number of independently locked local hash tables.
    uint stripes = 64;
    /// Default retention for the overload without a TTL argument.
    long defaultTtlNanos = 60_000_000_000L;
    /// Remote endpoint URL, including credentials when applicable.
    string redisUrl;
    /// Optional monotonic clock for the local backend.
    CacheClock clock;
    /// Measure nanoseconds spent acquiring local stripe locks.
    bool measureLockWait;
    /// Remote key namespace. Clients with the same namespace share entries.
    string redisNamespace = "default";
    /// Optional PEM trust bundle for a rediss endpoint.
    string redisCaBundle;
}

/// Local stripe lock observations collected when measurement is enabled.
struct CacheStats
{
    /// Number of local stripe acquisitions observed.
    ulong lockAcquisitions;
    /// Total elapsed time from attempting each lock to acquiring it.
    ulong lockWaitNanos;
}

/// Load a value into the supplied caller-owned arena under a shared flight context.
alias CacheLoader = Result!Buffer delegate(ref scope RequestArena arena, ref Context context) @safe nothrow @nogc;
