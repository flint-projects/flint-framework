/// Typed hiredis boundary with detached reply ownership.
module flint.cache.ffi.hiredis;

import core.thread : Thread;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.cache.types : CacheOptions;

@safe:

package(flint.cache) enum Kind : uint
{
    get = 1,
    set,
    evict,
    clear
}

package(flint.cache) struct Watch
{
    int wakeFd;
    int socketFd;
    uint interest;
}

private struct NativeOptions
{
    const(char)* url;
    size_t urlLength;
    const(char)* namespaceName;
    size_t namespaceLength;
    const(char)* caFile;
    size_t caLength;
    size_t limit;
}

private struct NativeResult
{
    uint status;
    ubyte* bytes;
    size_t length;
}

private struct Connection;

extern (C) private @system nothrow @nogc
{
    int flint_redis_create(const(NativeOptions)*, Connection**);
    int flint_redis_resolve(Connection*);
    int flint_redis_attach(Connection*);
    int flint_redis_ready(Connection*);
    int flint_redis_watch_now(Connection*, Watch*);
    int flint_redis_pump(Connection*);
    int flint_redis_tick(Connection*);
    int flint_redis_readable(Connection*);
    int flint_redis_writable(Connection*);
    void flint_redis_stop(Connection*);
    void flint_redis_finish(Connection*, int);
    void flint_redis_free(Connection*);
    int flint_redis_wait(Connection*, uint);
    int flint_redis_issue(Connection*, uint, const(ubyte)*, size_t, const(ubyte)*, size_t, long, ulong*);
    int flint_redis_take(Connection*, ulong, NativeResult*);
    int flint_redis_abandon(Connection*, ulong);
    void flint_redis_release_bytes(ubyte*);
    ulong flint_redis_pushes(Connection*);
}

version (FlintCacheLocal)
{
}
else version (linux)
    version (FlintNativeHiredis) version = FlintRedisLinux;

version (FlintRedisLinux)
    private enum linked = true;
else
    private enum linked = false;

private enum waiting = 12;

// SAFETY: Typed callers use a live connection and checked slice bounds. Native operations
// copy inputs, own callbacks, serialize shared state, and cannot throw into D.
private int native(alias fn, Args...)(scope Args args) @trusted nothrow @nogc
{
    static if (linked)
        return fn(args);
    else
        return Status.unsupported;
}

private Error failure(int status) pure nothrow @nogc
{
    static immutable string[] messages = [
        null, "invalid Redis endpoint, namespace or command", "Redis allocation failed",
        "Redis cache closed", "Redis provider deadline elapsed",
        "Redis cache entry or ticket absent",
        "Redis transport owner conflict", "Redis transport or response failed",
        "Redis endpoint is unavailable", "Redis provider, protocol or cluster routing is unsupported",
        "Redis authentication or TLS policy rejected",
        "Redis request, response or queue limit exceeded",
    ];
    static assert(messages.length == Status.max + 1);
    return Error(cast(Status) status, messages[status]);
}

package(flint.cache) struct Probe
{
    bool pending;
    Error error;
}

package(flint.cache) struct Completion
{
    bool pending;
    Result!Buffer output;
}

package(flint.cache) struct Bridge
{
    private Connection* connection;
    @disable this(this);

    Error open(CacheOptions options) nothrow @nogc
    {
        NativeOptions input;
        input.url = options.redisUrl.length ? &options.redisUrl[0] : null;
        input.urlLength = options.redisUrl.length;
        input.namespaceName = options.redisNamespace.length ? &options.redisNamespace[0] : null;
        input.namespaceLength = options.redisNamespace.length;
        input.caFile = options.redisCaBundle.length ? &options.redisCaBundle[0] : null;
        input.caLength = options.redisCaBundle.length;
        input.limit = options.byteCapacity;
        return failure(native!flint_redis_create(&input, &connection));
    }

    Error resolve() nothrow @nogc
    {
        return failure(native!flint_redis_resolve(connection));
    }

    Error attach() nothrow @nogc
    {
        return failure(native!flint_redis_attach(connection));
    }

    Probe ready() nothrow @nogc
    {
        const status = native!flint_redis_ready(connection);
        return status == waiting ? Probe(true) : Probe(false, failure(status));
    }

    Result!Watch watch() nothrow @nogc
    {
        Watch value;
        const status = native!flint_redis_watch_now(connection, &value);
        return Result!Watch(value, failure(status));
    }

    Error wake() nothrow @nogc
    {
        return failure(native!flint_redis_pump(connection));
    }

    Error tick() nothrow @nogc
    {
        return failure(native!flint_redis_tick(connection));
    }

    Error readable() nothrow @nogc
    {
        return failure(native!flint_redis_readable(connection));
    }

    Error writable() nothrow @nogc
    {
        return failure(native!flint_redis_writable(connection));
    }

    Error waitBriefly() nothrow @nogc
    {
        return failure(native!flint_redis_wait(connection, 5U));
    }

    Result!ulong issue(Kind command, scope const(ubyte)[] key, scope const(ubyte)[] value, long ttl) nothrow @nogc
    {
        ulong ticket;
        const status = native!flint_redis_issue(connection, cast(uint) command, key.length
                ? &key[0] : null, key.length, value.length ? &value[0] : null, value.length, ttl, &ticket);
        return Result!ulong(ticket, failure(status));
    }

    // SAFETY: A successful take transfers one bounded allocation to this thread. We copy into
    // the caller arena before freeing it. No borrowed range escapes or enters a callback.
    Completion take(ulong ticket, ref scope RequestArena arena, bool copy) @trusted nothrow @nogc
    {
        NativeResult reply;
        const status = native!flint_redis_take(connection, ticket, &reply);
        if (status == waiting)
            return Completion(true);
        if (status != Status.ok)
            return Completion(false, Result!Buffer(Buffer.init, failure(status)));
        scope (exit)
            static if (linked)
                flint_redis_release_bytes(reply.bytes);
        if (reply.status != Status.ok)
            return Completion(false, Result!Buffer(Buffer.init, failure(reply.status)));
        return Completion(false, copy ? arena.copyIn(reply.bytes[0 .. reply.length]) : Result!Buffer.init);
    }

    void abandon(ulong ticket) nothrow @nogc
    {
        const status = native!flint_redis_abandon(connection, ticket);
        assert(status == Status.ok || status == Status.notFound);
    }

    // SAFETY: Stop only signals the owner's wake descriptor. The live connection serializes
    // producers and shutdown without touching caller storage or invoking D.
    void requestStop() @trusted nothrow @nogc
    {
        static if (linked)
            flint_redis_stop(connection);
    }

    // SAFETY: Called by the owner when readiness is removed, or before the owner starts.
    // Hiredis exhausts native callbacks before releasing its socket, with no D callback.
    void finish(Status status) @trusted nothrow @nogc
    {
        static if (linked)
            flint_redis_finish(connection, cast(int) status);
    }

    // SAFETY: Called by startup on failure or once the worker and all callers have dropped
    // the managed control object. The native destructor retains no D references.
    void destroy() @trusted nothrow @nogc
    {
        static if (linked)
            flint_redis_free(connection);
        connection = null;
    }

    version (unittest)
    {
        // SAFETY: The live connection exposes only an atomic counter, with no borrowed output.
        ulong pushes() @trusted nothrow @nogc
        {
            static if (linked)
                return flint_redis_pushes(connection);
            else
                return 0;
        }
    }
}

// SAFETY: Druntime owns a reference to the worker delegate until it returns. The worker uses
// only its managed control object and the native state it owns, with no caller borrows.
@trusted package(flint.cache) void startDriver(void delegate() @safe nothrow work)
{
    auto thread = new Thread(work);
    thread.isDaemon = true;
    thread.start();
}
