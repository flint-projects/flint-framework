/// Desktop main-thread registry, scoped events and owned worker completions.
module flint.desktop.runtime;

import core.lifetime : move;
import core.thread : Thread;
import core.time : dur;
import flint.arena : Error, RequestArena, Status;
import flint.conc : CancelSource, Context, Deadline, WorkFn, WorkTicket, WorkerOptions, WorkerPool;
import flint.conc.wait : waitUntil;
import flint.desktop.commands : validateDrawList;
import flint.desktop.ffi.platform : Identity, NativeWindow, PacketKind, backendAvailable, desktopError,
    mainThread, packetCapacity, queueClose, queueOpen, queuePop, queuePost, windowCapacity;
import flint.desktop.types : DesktopBackend, DesktopEvent, DesktopHandler, EventKind, WindowOptions;
import std.utf : UTFException, validate;

@safe:

private enum denied = Error(Status.permissionDenied, "desktop operation requires the process UI thread");
private enum expired = Error(Status.invalidArgument, "desktop window is closed");
private enum workCapacity = 256;

private struct Slot
{
    ulong generation;
    NativeWindow platform;
    CancelSource cancellation;
    WorkTicket[workCapacity] tickets;
    size_t count;
    bool running;
    bool closing;
    bool retiring;

    void stop(Identity identity) nothrow @nogc
    {
        if (closing)
            return;
        closing = true;
        queueClose(identity);
        cancellation.cancel();
    }

    Error work(scope const(ubyte)[] input, WorkFn job) nothrow @nogc
    {
        if (closing)
            return desktopError(Status.cancelled);
        if (count == tickets.length)
            return desktopError(Status.resourceExhausted);
        const accepted = workers.submit(cancellation.context(), input, job);
        if (!accepted.ok())
            return accepted.error;
        tickets[count++] = accepted.value;
        return Error.init;
    }

    void drain() nothrow @nogc
    {
        ubyte[4096] ignored;
        while (count)
        {
            const before = count;
            size_t unused;
            collect(ignored[], unused);
            if (before == count && waitUntil(Deadline.afterMillis(1)).code != Status.ok)
                Thread.sleep(1.dur!"msecs");
        }
    }

    Error collect(scope ubyte[] bytes, ref size_t written) nothrow @nogc
    {
        for (size_t index; index < count;)
        {
            size_t length;
            const outcome = workers.join(tickets[index], bytes, length);
            if (outcome.code == Status.unavailable)
            {
                ++index;
                continue;
            }
            tickets[index] = tickets[--count];
            if (outcome.code == Status.ok)
            {
                written = length;
                return Error.init;
            }
        }
        assert(count <= workCapacity);
        return desktopError(Status.notFound);
    }
}

private Slot[windowCapacity] windows;
private ulong generation;
private WorkerPool workers;
private bool workersReady;

private bool text(scope const(char)[] value, size_t limit)
{
    if (value.length > limit)
        return false;
    foreach (byte_; value)
    {
        if (byte_ == 0)
            return false;
    }
    try
        validate(value);
    catch (UTFException)
        return false;
    return true;
}

private bool asset(scope const(char)[] value) pure nothrow @nogc
{
    if (!value.length || value.length > 128 || value[0] == '/' || value[$ - 1] == '/')
        return false;
    size_t begin;
    foreach (index, character; value)
    {
        if (character == '/')
        {
            if (!component(value[begin .. index]))
                return false;
            begin = index + 1;
            continue;
        }
        if (!assetByte(character))
            return false;
    }
    return component(value[begin .. $]);
}

private bool assetByte(char value) pure nothrow @nogc
{
    return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || (value >= '0'
            && value <= '9') || value == '.' || value == '-' || value == '_';
}

private bool component(scope const(char)[] value) pure nothrow @nogc
{
    return value.length && value != "." && value != "..";
}

private bool wellFormed(WindowOptions options)
{
    if (!options.width || options.width > 16_384 || !options.height || options.height > 16_384
            || options.backend > DesktopBackend.max || !text(options.title, 256))
        return false;
    return options.backend == DesktopBackend.sdl || (asset(options.entryAsset) && text(options.html,
            1024 * 1024) && text(options.httpsOrigin, 512));
}

private bool live(Identity id) nothrow @nogc
{
    return id.generation && id.slot < windows.length && windows[id.slot].generation == id.generation;
}

private Error prepareWorkers()
{
    if (workersReady)
        return Error.init;
    auto prepared = WorkerPool.create(WorkerOptions(4, workCapacity));
    if (!prepared.ok())
        return prepared.error;
    workers = move(prepared.value);
    workersReady = true;
    return Error.init;
}

package(flint.desktop) Error openWindow(ref Identity id, WindowOptions options)
{
    if (!mainThread())
        return denied;
    if (live(id))
        return desktopError(Status.conflict);
    if (!wellFormed(options))
        return desktopError(Status.invalidArgument);
    if (!backendAvailable(options.backend))
        return desktopError(Status.unsupported);
    if (generation == ulong.max)
        return desktopError(Status.resourceExhausted);

    foreach (index, ref entry; windows)
    {
        if (entry.generation)
            continue;
        const identity = Identity(cast(uint) index, ++generation);
        const failure = initialize(entry, identity, options);
        if (failure.code == Status.ok)
            id = identity;
        return failure;
    }
    return desktopError(Status.resourceExhausted);
}

private Error initialize(ref Slot slot, Identity id, WindowOptions options)
{
    auto cancellation = CancelSource.create(Context.init, Deadline.none());
    if (!cancellation.ok())
        return cancellation.error;
    const queued = queueOpen(id, options.backend == DesktopBackend.sdl);
    if (queued.code != Status.ok)
        return queued;
    const opened = slot.platform.open(id, options);
    if (opened.code != Status.ok)
    {
        queueClose(id);
        return opened;
    }

    const prepared = prepareWorkers();
    if (prepared.code != Status.ok)
    {
        slot.platform.close();
        queueClose(id);
        return prepared;
    }
    slot.cancellation = move(cancellation.value);
    slot.generation = id.generation;
    return Error.init;
}

package(flint.desktop) Error sendWork(Identity id, scope const(ubyte)[] input, WorkFn callback) nothrow @nogc
{
    if (!mainThread())
        return denied;
    return live(id) ? windows[id.slot].work(input, callback) : expired;
}

package(flint.desktop) Error closeWindow(ref Identity id) nothrow @nogc
{
    if (!id.generation)
        return Error.init;
    if (!mainThread())
        return denied;
    if (live(id))
    {
        ref Slot slot = windows[id.slot];
        if (slot.retiring)
            return desktopError(Status.conflict);
        slot.retiring = true;
        slot.stop(id);
        slot.drain();
        slot.platform.close();
        slot.cancellation.close();
        slot.generation = 0;
        slot.running = false;
        slot.closing = false;
        slot.retiring = false;
    }
    id = Identity.init;
    return Error.init;
}

package(flint.desktop) Error post(Identity id, scope const(ubyte)[] bytes, bool draw) nothrow @nogc
{
    if (!id.generation)
        return expired;
    if (draw)
    {
        const validation = validateDrawList(bytes);
        if (validation.code != Status.ok)
            return validation;
    }
    return queuePost(id, draw ? PacketKind.draw : PacketKind.message, bytes);
}

private Error dispatch(ref DesktopEvent event, scope const(ubyte)[] bytes, scope DesktopHandler visit,
        ref scope RequestArena arena) nothrow @nogc
{
    if (event.kind == EventKind.message)
    {
        const copied = arena.copyIn(bytes);
        if (!copied.ok())
            return copied.error;
        event.message = copied.value;
    }
    const result = visit(event, arena);
    const reset = arena.reset();
    return result.code == Status.ok ? desktopError(reset) : result;
}

private Error deliver(Identity id, ref Slot slot, scope ubyte[] scratch, scope DesktopHandler visit,
        ref scope RequestArena arena) nothrow @nogc
{
    const queued = queuePop(id, scratch);
    if (queued.ok())
    {
        const bytes = scratch[0 .. queued.value.bytes];
        if (queued.value.kind == PacketKind.draw)
            return slot.platform.present(bytes);
        DesktopEvent event = DesktopEvent(EventKind.message);
        return dispatch(event, bytes, visit, arena);
    }
    if (queued.error.code != Status.notFound)
        return queued.error;

    size_t ready;
    const worker = slot.collect(scratch, ready);
    if (worker.code != Status.ok)
        return worker;
    DesktopEvent event = DesktopEvent(EventKind.message);
    return dispatch(event, scratch[0 .. ready], visit, arena);
}

private Error pump(Identity id, scope DesktopHandler visit, ref Context context) nothrow @nogc
{
    ubyte[packetCapacity] scratch;
    ubyte[packetCapacity] eventBytes;
    scope arena = RequestArena(eventBytes[]);
    while (live(id))
    {
        const expiredContext = context.check();
        if (expiredContext.code != Status.ok)
            return expiredContext;
        ref Slot slot = windows[id.slot];
        auto input = slot.platform.poll();
        if (input.ok())
        {
            const closing = input.value.kind == EventKind.close;
            if (closing)
                slot.stop(id);
            const outcome = dispatch(input.value, null, visit, arena);
            if (outcome.code != Status.ok || closing || !live(id))
                return outcome;
        }
        else if (input.error.code != Status.notFound)
            return input.error;

        const outcome = deliver(id, slot, scratch[], visit, arena);
        if (outcome.code == Status.notFound && !input.ok())
        {
            const delayed = waitUntil(Deadline.afterMillis(1));
            if (delayed.code != Status.ok)
                return delayed;
        }
        else if (outcome.code != Status.ok && outcome.code != Status.notFound)
            return outcome;
    }
    return Error.init;
}

package(flint.desktop) Error runWindow(Identity id, scope DesktopHandler visit, ref Context context) nothrow @nogc
{
    if (!mainThread())
        return denied;
    if (!live(id) || visit is null)
        return expired;
    if (windows[id.slot].running || windows[id.slot].closing)
        return desktopError(Status.conflict);
    windows[id.slot].running = true;
    scope (exit)
        closeWindow(id);
    return pump(id, visit, context);
}

static ~this() nothrow
{
    if (!mainThread())
        return;
    foreach (index, ref slot; windows)
    {
        if (slot.generation)
        {
            auto ticket = Identity(cast(uint) index, slot.generation);
            closeWindow(ticket);
        }
    }
    if (workersReady)
        workers.shutdown();
}
