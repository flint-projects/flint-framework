/// Desktop main-thread registry, scoped events and owned worker completions.
module flint.engine.desktop.runtime;

import core.lifetime : move;
import core.thread.osthread : Thread;
import core.time : dur;
import flint.arena : Buffer, Error, RequestArena, Status;
import flint.conc : CancelSource, Context, Deadline, WorkFn, WorkTicket, WorkerOptions, WorkerPool;
import flint.conc.wait : waitUntil;
import flint.engine.desktop.commands : validateDrawList;
import flint.engine.desktop.ffi.platform : Identity, NativeWindow, PacketKind, backendAvailable,
    desktopError, mainThread, packetCapacity, queueClose, queueOpen, queuePop, queuePost, windowCapacity;
import flint.engine.desktop.ipc : InvokeContext, IpcKind, IpcRouter, dispatchScript, frameLimit,
    parseFrame, permitted, rejectScript, resolveScript, validName;
import flint.engine.desktop.types : Capability, DesktopBackend, DesktopEvent, DesktopHandler,
    EventKind, WindowOptions;
import flint.serde : encodeJson;
import std.utf : UTFException, validate;

@safe:

private enum denied = Error(Status.permissionDenied, "desktop operation requires the process UI thread");
private enum expired = Error(Status.invalidArgument, "desktop window is closed");
private enum workCapacity = 256;
private enum invokeCapacity = 32_768;
private enum forbidden = Error(Status.permissionDenied, "desktop capability does not grant this call");
private enum unrouted = Error(Status.notFound, "desktop window has no command router");

private struct Slot
{
    ulong generation;
    // Retained so the native webview may borrow asset and capability slices until close.
    WindowOptions options;
    NativeWindow platform;
    ulong malformed;
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
    return options.backend == DesktopBackend.sdl || webview(options);
}

private bool webview(WindowOptions options)
{
    if (!asset(options.entryAsset) || !text(options.html, 1024 * 1024) || !text(options.httpsOrigin,
            512) || !validName(options.label) || options.assets.length > 1024 || options.capabilities.length > 64)
        return false;
    foreach (ref grant; options.capabilities)
    {
        if (!granted(grant))
            return false;
    }
    bool entry = options.html.length != 0;
    foreach (ref file; options.assets)
    {
        if (!asset(file.path) || !text(file.mime, 127) || file.content.length > 64 * 1024 * 1024)
            return false;
        entry = entry || file.path == options.entryAsset;
    }
    return entry;
}

private bool granted(ref const Capability grant)
{
    if (!names(grant.windows, true) || !names(grant.commands, false) || !names(grant.events, false))
        return false;
    foreach (origin; grant.origins)
    {
        if (!text(origin, 255) || origin.length < 9 || origin[0 .. 8] != "https://")
            return false;
    }
    return true;
}

private bool names(scope const(string)[] values, bool wildcard) pure nothrow @nogc
{
    foreach (value; values)
    {
        if (!validName(value) && !(wildcard && value == "*"))
            return false;
    }
    return true;
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

package(flint.engine.desktop) Error openWindow(ref Identity id, WindowOptions options)
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
    slot.options = options;
    const opened = slot.platform.open(slot.options);
    if (opened.code != Status.ok)
    {
        slot.options = WindowOptions.init;
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

package(flint.engine.desktop) Error sendWork(Identity id, scope const(ubyte)[] input, WorkFn callback) nothrow @nogc
{
    if (!mainThread())
        return denied;
    return live(id) ? windows[id.slot].work(input, callback) : expired;
}

package(flint.engine.desktop) Error closeWindow(ref Identity id) nothrow @nogc
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
        slot.options = WindowOptions.init;
        slot.generation = 0;
        slot.running = false;
        slot.closing = false;
        slot.retiring = false;
    }
    id = Identity.init;
    return Error.init;
}

package(flint.engine.desktop) Error post(Identity id, scope const(ubyte)[] bytes, bool draw) nothrow @nogc
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

/// Native test and automation hooks acting as the window manager would.
package(flint.engine.desktop) Error nativeRequestClose(Identity id) nothrow @nogc
{
    if (!mainThread() || !live(id))
        return desktopError(Status.invalidArgument);
    windows[id.slot].platform.requestClose();
    return Error.init;
}

/// ditto
package(flint.engine.desktop) Error nativeResize(Identity id, int width, int height) nothrow @nogc
{
    if (!mainThread() || !live(id))
        return desktopError(Status.invalidArgument);
    windows[id.slot].platform.resize(width, height);
    return Error.init;
}

/// Current page address and policy refusals of a live window.
package(flint.engine.desktop) nothrow @nogc const(char)[] nativeAddress(Identity id,
        return scope char[] to, out ulong refused)
{
    if (!mainThread() || !live(id))
        return null;
    refused = windows[id.slot].platform.refusals();
    return windows[id.slot].platform.location(to);
}

/// Close from inside a command; the owner loop observes the retired generation.
package(flint.engine.desktop) Error requestClose(Identity id) nothrow @nogc
{
    auto ticket = id;
    return closeWindow(ticket);
}

/// Encode a typed payload and dispatch it to the window's frontend listeners.
package(flint.engine.desktop) nothrow @nogc Error emitValue(T)(Identity id, scope const(char)[] name,
        scope const ref T value)
{
    if (!mainThread())
        return denied;
    if (!live(id))
        return expired;
    if (!validName(name))
        return desktopError(Status.invalidArgument);
    ubyte[frameLimit] storage;
    scope arena = RequestArena(storage[]);
    auto json = encodeJson(value, arena);
    if (!json.ok())
        return json.error;
    Error outcome;
    const status = arena.read(json.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        outcome = emitJson(id, name, bytes);
    });
    return status == Status.ok ? outcome : desktopError(status);
}

private Error emitJson(Identity id, scope const(char)[] event, scope const(ubyte)[] json) nothrow @nogc
{
    char[frameLimit + 256] storage;
    const script = dispatchScript(storage[], event, json);
    return script is null ? desktopError(Status.resourceExhausted) : windows[id.slot].platform.evaluate(script);
}

private void reply(Identity id, ulong request, Error failure, scope const(ubyte)[] json) nothrow @nogc
{
    char[invokeCapacity + 256] storage;
    auto script = failure.code == Status.ok ? resolveScript(storage[], request,
            json) : rejectScript(storage[], request, failure);
    if (script is null)
        script = rejectScript(storage[], request, desktopError(Status.resourceExhausted));
    if (live(id))
        windows[id.slot].platform.evaluate(script);
}

private void answer(Identity id, scope const(ubyte)[] bytes, scope const(char)[] origin,
        scope IpcRouter router, ref Context context) nothrow @nogc
{
    Error malformed;
    const frame = parseFrame(bytes, malformed);
    if (malformed.code != Status.ok)
    {
        ++windows[id.slot].malformed;
        return;
    }
    const grants = windows[id.slot].options.capabilities;
    const label = windows[id.slot].options.label;
    ubyte[invokeCapacity] storage;
    scope invocation = InvokeContext(RequestArena(storage[]), context, label, origin, id);
    Buffer result;
    Error failure = forbidden;
    if (permitted(grants, label, origin, frame.kind, frame.name))
        failure = router is null ? unrouted : router(frame.kind, frame.name, frame.body, invocation, result);
    if (frame.kind == IpcKind.emit)
        return;
    if (failure.code != Status.ok || !result.length)
        return reply(id, frame.id, failure, null);
    const status = invocation.arena.read(result, (scope const(ubyte)[] json) @safe nothrow @nogc {
        reply(id, frame.id, Error.init, json);
    });
    if (status != Status.ok)
        reply(id, frame.id, desktopError(status), null);
}

private bool frames(Identity id, scope IpcRouter router, ref Context context) nothrow @nogc
{
    ubyte[frameLimit] bytes;
    char[255] origin;
    bool handled;
    foreach (_; 0 .. 64)
    {
        size_t length, originLength;
        if (!live(id) || !windows[id.slot].platform.takeFrame(bytes[], length, origin[], originLength))
            break;
        answer(id, bytes[0 .. length], origin[0 .. originLength], router, context);
        handled = true;
    }
    return handled;
}

private struct Step
{
    Error error;
    bool idle;
    bool finished;
}

/// Dispatch one native window event; `finished` reports a close, a failure or a retired window.
private Step event(Identity id, scope DesktopHandler visit, ref scope RequestArena arena) nothrow @nogc
{
    ref Slot slot = windows[id.slot];
    auto input = slot.platform.poll();
    if (!input.ok())
    {
        const failed = input.error.code != Status.notFound;
        return Step(failed ? input.error : Error.init, true, failed);
    }
    const closing = input.value.kind == EventKind.close;
    if (closing)
        slot.stop(id);
    const outcome = dispatch(input.value, null, visit, arena);
    return Step(outcome, false, outcome.code != Status.ok || closing || !live(id));
}

private Error pump(Identity id, scope DesktopHandler visit, scope IpcRouter router, ref Context context) nothrow @nogc
{
    ubyte[packetCapacity] scratch;
    ubyte[packetCapacity] eventBytes;
    scope arena = RequestArena(eventBytes[]);
    while (live(id))
    {
        const expiredContext = context.check();
        if (expiredContext.code != Status.ok)
            return expiredContext;
        const native = event(id, visit, arena);
        if (native.finished)
            return native.error;
        const answered = frames(id, router, context);
        if (!live(id))
            return Error.init;
        const outcome = deliver(id, windows[id.slot], scratch[], visit, arena);
        if (outcome.code == Status.notFound && native.idle && !answered)
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

package(flint.engine.desktop) Error runWindow(Identity id, scope DesktopHandler visit,
        scope IpcRouter router, ref Context context) nothrow @nogc
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
    return pump(id, visit, router, context);
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
