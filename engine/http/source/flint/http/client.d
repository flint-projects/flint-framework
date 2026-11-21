/// Owner-confined client pool and request lifecycle.
module flint.http.client;

import core.atomic : atomicLoad, atomicOp, cas;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context, Deadline;
import flint.http.ffi.shim : Bridge, NativeWatch, StreamView;
import flint.http.types : ChunkConsumer, ClientOptions, DestinationPolicy, Header, HttpMethod,
    HttpRequest, HttpRequestView, HttpResponse, HttpStreamOptions;
import flint.reactor : NativeInterest, NativeReadyFn, Reactor;

@safe:

/// A reusable libcurl pool. Each copy refers to the same owner and lifecycle.
/// Open during startup and close on the thread that first sends or streams.
struct HttpClient
{
    private ClientState state;

    /// Provision transfer slots and select TLS and redirect policy.
    Error open(ClientOptions options)
    {
        if (state !is null)
            return Error(Status.conflict, "HTTP client already open");
        if (options.maxConnections == 0 || options.maxConnections > 128 || options.maxConnectionsPerOrigin == 0
                || options.maxConnectionsPerOrigin > options.maxConnections || options.maxResponseBytes == 0
                || options.maxHeaderBytes == 0 || options.connectTimeoutNanos <= 0
                || !options.verifyPeer || (options.followRedirects && options.destinationPolicy is null))
            return Error(Status.invalidArgument, "invalid HTTP limits, TLS or redirect configuration");

        auto opened = new ClientState;
        const capacity = options.maxConnections * 6 + 16;
        opened.snapshot = new NativeWatch[capacity];
        opened.applied = new NativeWatch[capacity];
        opened.policy = options.destinationPolicy;
        opened.readyCallback = &opened.ready;
        const status = opened.bridge.open(options);
        if (status.code == Status.ok)
            state = opened;
        return status;
    }

nothrow @nogc:

    /// Buffer the final response in the caller's arena.
    Result!HttpResponse send(scope const ref HttpRequest request, ref scope RequestArena arena, ref Context context)
    {
        return sendComposed(request.url, request.method, request.headers, request.body, arena, context);
    }

    /// Deliver decoded bytes on the calling fiber or thread and return the final status.
    Result!ushort stream(scope const ref HttpRequest request, ref scope RequestArena arena,
            ref Context context, scope ChunkConsumer consume)
    {
        if (consume is null)
            return Result!ushort(0, Error(Status.invalidArgument, "missing HTTP chunk consumer"));
        const response = exchange(request.url, request.method, request.headers, request.body, arena, context, consume);
        return Result!ushort(response.value.status, response.error);
    }

    /// Borrow a replay-stable upload through response completion or cancellation.
    Result!HttpResponse sendView(scope const ref HttpRequestView request, ref scope RequestArena arena,
            ref Context context)
    {
        return exchangeView(request, arena, context, null);
    }

    /// Stream responses from a scoped request and report its final HTTP status.
    Result!ushort streamView(scope const ref HttpRequestView request, ref scope RequestArena arena,
            ref Context context, scope ChunkConsumer consume)
    {
        if (consume is null)
            return Result!ushort(0, Error(Status.invalidArgument, "missing HTTP chunk consumer"));
        const response = exchangeView(request, arena, context, consume);
        return Result!ushort(response.value.status, response.error);
    }

    /// Begin an incremental transfer. The client owns the provider until the stream closes.
    Result!HttpStream openStream(scope const ref HttpStreamOptions options, ref scope const Context context)
    {
        auto client = state;
        if (client is null)
            return Result!HttpStream(HttpStream.init, Error(Status.conflict, "HTTP client is closed"));
        const current = client.streamOwner(context);
        if (current.code != Status.ok)
            return Result!HttpStream(HttpStream.init, current);

        const opened = client.bridge.beginStream(options);
        if (!opened.ok())
            return Result!HttpStream(HttpStream.init, opened.error);
        const id = opened.value;
        bool published;
        scope (exit)
        {
            if (!published)
                client.bridge.retireStream(id);
        }
        foreach (ref field; options.headers)
        {
            const added = client.bridge.header(id, field.name, field.value);
            if (added.code != Status.ok)
                return Result!HttpStream(HttpStream.init, added);
        }
        if (options.finalField.name.length)
        {
            const added = client.bridge.header(id, options.finalField.name, options.finalField.value);
            if (added.code != Status.ok)
                return Result!HttpStream(HttpStream.init, added);
        }
        const allowed = client.bridge.allow(id, client.policy, false);
        if (allowed.code != Status.ok)
            return Result!HttpStream(HttpStream.init, allowed);
        const started = client.bridge.activate(id);
        if (started.code != Status.ok)
            return Result!HttpStream(HttpStream.init, started);
        published = true;
        ++client.inFlight;
        return Result!HttpStream(HttpStream(client, id, context));
    }

    /// Release the pool after all in-flight requests settle, on its owner thread.
    Error close()
    {
        if (state is null)
            return Error.init;
        const owner = state.claim();
        if (owner.code != Status.ok)
            return owner;
        if (state.inFlight != 0)
            return Error(Status.conflict, "HTTP client still has live requests");
        if (state.bridge.isOpen())
        {
            state.clearWatches();
            state.bridge.close();
        }
        state = null;
        return Error.init;
    }

    package(flint.http) Result!HttpResponse sendComposed(scope const(char)[] url, HttpMethod method,
            scope const Header[] headers, Buffer body, ref scope RequestArena arena, ref Context context)
    {
        return exchange(url, method, headers, body, arena, context, null);
    }

    private Result!HttpResponse exchange(scope const(char)[] url, HttpMethod method,
            scope const Header[] headers, Buffer body, ref scope RequestArena arena, ref Context context,
            scope ChunkConsumer consume)
    {
        auto client = state;
        if (client is null)
            return failed(Error(Status.conflict, "HTTP client is closed"));
        const owner = client.claim();
        if (owner.code != Status.ok)
            return failed(owner);
        if (!client.bridge.isOpen())
            return failed(Error(Status.conflict, "HTTP client is closed"));

        auto reactor = Reactor.current();
        const onLoop = reactor.currentCore() != uint.max;
        if (onLoop && !reactor.currentTask().ok())
            return failed(Error(Status.conflict, "HTTP transfer on a reactor requires an active fiber"));

        const initial = context.check();
        if (initial.code != Status.ok)
            return failed(initial);
        auto started = client.bridge.begin(url, method, consume !is null);
        if (!started.ok())
            return failed(started.error);
        const id = started.value;

        ++client.inFlight;
        scope (exit)
        {
            client.bridge.retire(id);
            client.transferRetired();
        }

        const prepared = client.prepare(id, headers, body, arena, context);
        if (prepared.code != Status.ok)
            return failed(prepared);
        return client.run(id, arena, context, consume, onLoop ? 16 : uint.max);
    }

    private Result!HttpResponse exchangeView(scope const ref HttpRequestView request,
            ref scope RequestArena arena, ref Context context, scope ChunkConsumer consume)
    {
        auto client = state;
        if (client is null)
            return failed(Error(Status.conflict, "HTTP client is closed"));
        const ready = client.streamOwner(context);
        if (ready.code != Status.ok)
            return failed(ready);
        const onLoop = Reactor.current().currentCore() != uint.max;
        ++client.inFlight;
        scope (exit)
            client.transferRetired();
        return client.bridge.withRequest(request, consume !is null, (ulong id) @safe nothrow @nogc {
            foreach (ref field; request.headers)
            {
                const added = client.bridge.header(id, field.name, field.value);
                if (added.code != Status.ok)
                    return failed(added);
            }
            const prepared = client.activate(id, context);
            if (prepared.code != Status.ok)
                return failed(prepared);
            return client.run(id, arena, context, consume, onLoop ? 16 : uint.max);
        });
    }
}

/// An owner-confined incremental transfer with an opaque generation.
struct HttpStream
{
    private ClientState state;
    private ulong id;
    private Context lifetime;

    @disable this(this);

    private this(ClientState state, ulong id, Context lifetime) nothrow @nogc
    {
        this.state = state;
        this.id = id;
        this.lifetime = lifetime;
    }

nothrow @nogc:

    /// Return the final response head while its body remains live.
    Result!HttpResponse head(ref scope RequestArena arena, ref scope const Context context) scope
    {
        const ready = fields(false, context);
        if (!ready.ok())
            return failed(ready.error);
        const copied = state.bridge.copyStreamFields(id, false, arena);
        if (!copied.ok())
            return failed(copied.error);
        return Result!HttpResponse(HttpResponse(ready.value.status, copied.value, Buffer.init, ready.value.protocol));
    }

    /// Return the terminal fields after the provider finishes the response.
    Result!Buffer trailers(ref scope RequestArena arena, ref scope const Context context) scope
    {
        const ready = fields(true, context);
        if (!ready.ok())
            return Result!Buffer(Buffer.init, ready.error);
        return state.bridge.copyStreamFields(id, true, arena);
    }

    /// Copy out the next available response bytes. A successful zero count is peer EOF.
    Result!size_t receive(scope ubyte[] output, ref scope const Context context) scope
    {
        if (output.length == 0)
            return Result!size_t(0, Error(Status.invalidArgument, "HTTP stream receive buffer is empty"));
        for (;;)
        {
            const live = progress(context);
            if (live.code != Status.ok)
                return Result!size_t(0, live);
            const read = state.bridge.streamRead(id, output);
            if (read.error.code != Status.unavailable)
                return read;
            const waited = state.wait();
            if (waited.code != Status.ok)
                return Result!size_t(0, waited);
        }
    }

    /// Copy the entire input to curl-owned storage or resolve the operation with an error.
    Error send(scope const(ubyte)[] input, ref scope const Context context) scope
    {
        size_t first;
        do
        {
            const live = progress(context);
            if (live.code != Status.ok || first == input.length)
                return live;
            const sent = state.bridge.streamWrite(id, input[first .. $]);
            if (sent.ok())
            {
                if (sent.value == 0)
                    return Error(Status.ioError, "HTTP stream returned an empty write");
                first += sent.value;
            }
            else if (sent.error.code != Status.unavailable)
                return sent.error;
            if (first < input.length)
            {
                const waited = state.wait();
                if (waited.code != Status.ok)
                    return waited;
            }
        }
        while (first < input.length);
        return Error.init;
    }

    /// Signal HTTP/2 upload EOF while leaving the incoming response available.
    Error finishSend(ref scope const Context context) scope
    {
        const live = progress(context);
        return live.code == Status.ok ? state.bridge.finishStreamSend(id) : live;
    }

    /// Cancel an unfinished transfer or release a completed one on its owner.
    Error close() scope
    {
        if (state is null)
            return Error.init;
        const owner = state.claim();
        if (owner.code != Status.ok)
            return owner;
        if (!state.bridge.isOpen())
        {
            state = null;
            id = 0;
            lifetime = Context.init;
            return Error.init;
        }
        const retired = state.bridge.retireStream(id);
        if (retired.code != Status.ok && retired.code != Status.notFound)
            return retired;
        if (retired.code == Status.ok)
        {
            --state.inFlight;
            if (state.inFlight == 0)
                state.clearWatches();
            else
                state.refreshWatches();
        }
        state = null;
        id = 0;
        lifetime = Context.init;
        return Error.init;
    }

    private Error progress(ref scope const Context context) scope
    {
        if (state is null)
            return Error(Status.conflict, "HTTP stream is closed");
        const active = lifetime.check();
        if (active.code != Status.ok)
            return active;
        const owned = state.streamOwner(context);
        if (owned.code != Status.ok)
            return owned;
        const driven = state.drive(context);
        return driven.code == Status.ok ? state.bridge.streamView(id).error : driven;
    }

    private Result!StreamView fields(bool terminal, ref scope const Context context) scope
    {
        for (;;)
        {
            const live = progress(context);
            if (live.code != Status.ok)
                return Result!StreamView(StreamView.init, live);
            const snapshot = state.bridge.streamView(id);
            if (terminal ? snapshot.complete : snapshot.headReady)
                return Result!StreamView(snapshot);
            if (snapshot.complete)
                return Result!StreamView(StreamView.init, Error(Status.unavailable,
                        "HTTP peer omitted the response head"));
            const waited = state.wait();
            if (waited.code != Status.ok)
                return Result!StreamView(StreamView.init, waited);
        }
    }
}

private shared ulong threadSerial;
private ulong threadGeneration;

private final class ClientState
{
    private shared ulong owner;
    Bridge bridge;
    DestinationPolicy policy;
    NativeReadyFn readyCallback;
    NativeWatch[] snapshot;
    NativeWatch[] applied;
    size_t appliedCount;
    ulong watchRevision;
    uint inFlight;
    Error driverFault;

nothrow @nogc:

    Error claim() scope
    {
        if (threadGeneration == 0)
            threadGeneration = atomicOp!"+="(threadSerial, 1UL);
        const observed = atomicLoad(owner);
        if (threadGeneration == 0 || (observed != threadGeneration && !cas(&owner, 0UL, threadGeneration)))
            return Error(Status.conflict, "HTTP transport belongs to another owner thread");
        return Error.init;
    }

    Error streamOwner(ref scope const Context context) scope
    {
        const owned = claim();
        if (owned.code != Status.ok)
            return owned;
        if (!bridge.isOpen())
            return Error(Status.conflict, "HTTP client is closed");
        const reactor = Reactor.current();
        if (reactor.currentCore() != uint.max && !reactor.currentTask().ok())
            return Error(Status.conflict, "HTTP transfer on a reactor requires an active fiber");
        return context.check();
    }

    Error prepare(ulong id, scope const Header[] fields, Buffer body, ref scope RequestArena arena, ref Context ctx)
    {
        foreach (ref field; fields)
        {
            const added = bridge.header(id, field);
            if (added.code != Status.ok)
                return added;
        }
        if (body != Buffer.init)
        {
            Error copied;
            const viewed = arena.read(body, (scope const(ubyte)[] bytes) {
                copied = bridge.upload(id, bytes);
            });
            if (viewed != Status.ok)
                return Error(viewed, "invalid HTTP request body arena handle");
            if (copied.code != Status.ok)
                return copied;
        }
        return activate(id, ctx);
    }

    Error activate(ulong id, ref const Context ctx) scope
    {
        const allowed = bridge.allow(id, policy, false);
        if (allowed.code != Status.ok)
            return allowed;
        const live = ctx.check();
        return live.code == Status.ok ? bridge.activate(id) : live;
    }

    void transferRetired() scope
    {
        --inFlight;
        if (inFlight == 0)
            clearWatches();
        else
            refreshWatches();
    }

    Result!HttpResponse run(ulong id, ref scope RequestArena arena, ref Context context,
            scope ChunkConsumer consume, uint chunkBudget)
    {
        uint sentChunks;
        while (true)
        {
            const progress = drive(context);
            if (progress.code != Status.ok)
                return failed(progress);
            const transfer = bridge.view(id);
            if (transfer.error.code != Status.ok)
                return failed(transfer.error);
            if (transfer.chunkReady)
            {
                const delivery = deliver(id, context, consume);
                if (delivery.code != Status.ok)
                    return failed(delivery);
                if (++sentChunks < chunkBudget)
                    continue;
                sentChunks = 0;
            }
            else if (transfer.complete)
            {
                if (!transfer.redirectReady)
                    return consume is null ? bridge.copyResponse(id, arena) : Result!HttpResponse(
                            HttpResponse(transfer.status, Buffer.init, Buffer.init, transfer.protocol));
                const redirected = follow(id, context);
                if (redirected.code != Status.ok)
                    return failed(redirected);
                continue;
            }

            const waited = wait();
            if (waited.code != Status.ok)
                return failed(waited);
        }
    }

    Error drive(ref scope const Context context) scope
    {
        const valid = context.check();
        if (valid.code != Status.ok)
            return valid;
        if (driverFault.code != Status.ok)
            return driverFault;
        const due = bridge.due();
        if (due.code != Status.ok)
            return due;
        refreshWatches();
        return driverFault;
    }

    private Error deliver(ulong id, ref Context context, scope ChunkConsumer consume)
    {
        const delivered = bridge.deliver(id, consume);
        if (delivered.code != Status.ok)
            return delivered;
        const live = context.check();
        return live.code == Status.ok ? bridge.consumeChunk(id) : live;
    }

    private Error follow(ulong id, ref Context context)
    {
        const allowed = bridge.allow(id, policy, true);
        if (allowed.code != Status.ok)
            return allowed;
        const live = context.check();
        return live.code == Status.ok ? bridge.follow(id) : live;
    }

    Error wait() scope
    {
        auto reactor = Reactor.current();
        if (reactor.currentCore() == uint.max)
            return bridge.poll(5);
        const slept = reactor.yieldUntil(Deadline.afterMillis(1));
        if (slept.code == Status.unavailable)
            return Error(Status.cancelled, "HTTP transfer cancelled by reactor shutdown");
        return slept;
    }

    void refreshWatches() scope
    {
        auto reactor = Reactor.current();
        if (reactor.currentCore() == uint.max || driverFault.code != Status.ok)
            return;
        const watches = bridge.watches(snapshot, watchRevision);
        if (!watches.ok())
        {
            driverFault = watches.error;
            return;
        }
        if (watches.value == size_t.max)
            return;
        const incoming = snapshot[0 .. watches.value];
        size_t index;
        while (index < appliedCount)
        {
            const prior = applied[index];
            if (findWatch(incoming, prior) == size_t.max)
            {
                const removed = reactor.unwatchNative(cast(int) prior.fd);
                if (removed.code != Status.ok && removed.code != Status.notFound)
                {
                    driverFault = removed;
                    return;
                }
                applied[index] = applied[--appliedCount];
            }
            else
                ++index;
        }
        foreach (item; incoming)
        {
            const old = findWatch(applied[0 .. appliedCount], item);
            if (old != size_t.max && applied[old].events == item.events)
                continue;
            const installed = reactor.watchNative(cast(int) item.fd, cast(NativeInterest) item.events, readyCallback);
            if (installed.code != Status.ok)
            {
                driverFault = installed;
                return;
            }
            if (old == size_t.max)
                applied[appliedCount++] = item;
            else
                applied[old] = item;
        }
    }

    private void ready(int fd, NativeInterest events)
    {
        if (driverFault.code == Status.ok)
            driverFault = bridge.ready(fd, cast(uint) events);
        refreshWatches();
    }

    void clearWatches() scope
    {
        auto reactor = Reactor.current();
        foreach (item; applied[0 .. appliedCount])
            reactor.unwatchNative(cast(int) item.fd);
        appliedCount = 0;
        watchRevision = 0;
    }
}

private size_t findWatch(scope const NativeWatch[] watches, NativeWatch target) pure nothrow @nogc
{
    foreach (index, entry; watches)
        if (entry.fd == target.fd && entry.generation == target.generation)
            return index;
    return size_t.max;
}

private Result!HttpResponse failed(Error outcome) pure nothrow @nogc
{
    return Result!HttpResponse(HttpResponse.init, outcome);
}
