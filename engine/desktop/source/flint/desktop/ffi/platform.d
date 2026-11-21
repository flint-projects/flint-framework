/// Scoped native platform calls, owner-thread events and cross-thread copied packets.
module flint.desktop.ffi.platform;

import flint.arena : Error, Result, Status;
import flint.desktop.types : DesktopBackend, DesktopEvent, EventKind, WindowOptions;

@safe:
nothrow @nogc:

private struct SdlWindow;
private struct WebkitWindow;

package(flint.desktop) struct Identity
{
    uint slot;
    ulong generation;
}

package(flint.desktop) enum windowCapacity = 16;
package(flint.desktop) enum packetCapacity = 16_384;
package(flint.desktop) enum PacketKind : uint
{
    draw = 1,
    message
}

package(flint.desktop) struct Packet
{
    PacketKind kind;
    size_t bytes;
}

private struct NativeEvent
{
    uint kind;
    int x;
    int y;
    uint keyCode;
}

extern (C) private @system
{
    int flint_desktop_main_thread();
    int flint_desktop_queue_open(uint, ulong, int);
    int flint_desktop_queue_post(uint, ulong, uint, const(ubyte)*, size_t);
    int flint_desktop_queue_pop(uint, ulong, uint*, ubyte*, size_t, size_t*);
    void flint_desktop_queue_close(uint, ulong);

    SdlWindow* flint_window_new(const(char)*, uint, uint, uint);
    int flint_window_poll(SdlWindow*, NativeEvent*);
    int flint_window_submit(SdlWindow*, const(ubyte)*, size_t);
    void flint_window_free(SdlWindow*);

    WebkitWindow* flint_webkit_window_new(const(char)*, uint, uint, uint, uint, ulong,
            const(char)*, const(ubyte)*, size_t, const(char)*);
    int flint_webkit_window_poll(WebkitWindow*, NativeEvent*);
    void flint_webkit_window_free(WebkitWindow*);
}

version (linux)
{
    version (FlintNativeSdl3)
        version = FlintDesktopQueues;
    else version (FlintDesktopWebkitGtk)
        version = FlintDesktopQueues;
}

/// Stable native status mapping.
package(flint.desktop) Error desktopError(int code)
{
    if (code == Status.ok)
        return Error.init;
    if (code < Status.min || code > Status.max)
        code = Status.ioError;
    static immutable string[] reasons = [
        null, "invalid desktop input or closed window", "desktop allocation failed",
        "window is closing", "desktop deadline elapsed", "no desktop event",
        "desktop operation conflicts with its state", "desktop platform operation failed",
        "desktop display is unavailable", "desktop backend is unavailable in this profile",
        "desktop operation requires the process UI thread", "desktop queue or payload budget exceeded",
    ];
    return Error(cast(Status) code, reasons[code]);
}

// SAFETY: This direct native query has no borrowed data, callbacks or exceptions.
package(flint.desktop) bool mainThread() @trusted nothrow @nogc
{
    version (FlintDesktopQueues)
        return flint_desktop_main_thread() != 0;
    else
        return true;
}

package(flint.desktop) bool backendAvailable(DesktopBackend backend)
{
    final switch (backend)
    {
    case DesktopBackend.sdl:
        version (FlintNativeSdl3)
            return true;
        else
            return false;
    case DesktopBackend.systemWebView:
        version (FlintDesktopWebkitGtk)
            return true;
        else
            return false;
    }
}

// SAFETY: The main-thread owner registers a nonzero scalar generation. The C mutex protects
// the registry. No D storage or callbacks are retained.
package(flint.desktop) Error queueOpen(Identity who, bool acceptsDraw) @trusted nothrow @nogc
{
    version (FlintDesktopQueues)
        return desktopError(flint_desktop_queue_open(who.slot, who.generation, acceptsDraw));
    else
        return desktopError(Status.unsupported);
}

// SAFETY: Native checks the generation under its registry mutex and copies the sized borrow
// before return. It has no D callbacks and workers never access native window pointers.
package(flint.desktop) Error queuePost(Identity who, PacketKind kind, scope const(ubyte)[] bytes) @trusted nothrow @nogc
{
    version (FlintDesktopQueues)
        return desktopError(flint_desktop_queue_post(who.slot, who.generation, kind, bytes.ptr, bytes.length));
    else
        return desktopError(Status.unsupported);
}

// SAFETY: Only the main thread can pop. C copies through the supplied in-range span while
// holding its registry mutex. It retains no D state and calls no handlers.
package(flint.desktop) Result!Packet queuePop(Identity who, scope ubyte[] bytes) @trusted nothrow @nogc
{
    uint kind;
    size_t length;
    version (FlintDesktopQueues)
    {
        const status = flint_desktop_queue_pop(who.slot, who.generation, &kind, bytes.ptr, bytes.length, &length);
        return Result!Packet(Packet(cast(PacketKind) kind, length), desktopError(status));
    }
    else
        return Result!Packet(Packet.init, desktopError(Status.unsupported));
}

// SAFETY: Queue retirement unpublishes the exact generation under the same mutex that guards
// worker copies. Any borrowers have returned when C frees its storage. There are no callbacks.
package(flint.desktop) void queueClose(Identity who) @trusted nothrow @nogc
{
    version (FlintDesktopQueues)
        flint_desktop_queue_close(who.slot, who.generation);
}

package(flint.desktop) struct NativeWindow
{
nothrow @nogc:

    private SdlWindow* sdl;
    private WebkitWindow* webkit;

    // SAFETY: The owner thread has validated the bounded inputs. C copies the strings and HTML
    // during this call. Native handlers remain internal and cannot unwind through this boundary.
    Error open(Identity who, WindowOptions options) @trusted nothrow @nogc
    {
        char[257] title = 0;
        title[0 .. options.title.length] = options.title[];
        if (options.backend == DesktopBackend.sdl)
        {
            version (FlintNativeSdl3)
                sdl = flint_window_new(title.ptr, options.width, options.height, options.resizable);
            return sdl is null ? desktopError(Status.unavailable) : Error.init;
        }
        version (FlintDesktopWebkitGtk)
            return openWebview(who, options, title);
        else
            return desktopError(Status.unsupported);
    }

    version (FlintDesktopWebkitGtk)
    {
        // SAFETY: All options are bounded by validation before the native call. Native owns
        // copies and internal callbacks. The owner main thread is the only pointer accessor.
        private Error openWebview(Identity who, WindowOptions options, scope const(char)[] title) @trusted nothrow @nogc
        {
            char[129] entry = 0;
            char[513] origin = 0;
            entry[0 .. options.entryAsset.length] = options.entryAsset[];
            origin[0 .. options.httpsOrigin.length] = options.httpsOrigin[];
            webkit = flint_webkit_window_new(title.ptr, options.width, options.height,
                    options.resizable, who.slot, who.generation, entry.ptr,
                    cast(const(ubyte)*) options.html.ptr, options.html.length, origin.ptr);
            return webkit is null ? desktopError(Status.unavailable) : Error.init;
        }
    }

    // SAFETY: The live owner-thread pointer is held until the poll returns. C writes one POD
    // event, retains no D storage, and may queue owned WebKit bytes through the C registry only.
    Result!DesktopEvent poll() @trusted nothrow @nogc
    {
        NativeEvent event;
        int code;
        version (FlintNativeSdl3)
        {
            if (sdl !is null)
                code = flint_window_poll(sdl, &event);
        }
        version (FlintDesktopWebkitGtk)
        {
            if (webkit !is null)
                code = flint_webkit_window_poll(webkit, &event);
        }
        if (code < 0)
            return Result!DesktopEvent(DesktopEvent.init, desktopError((code >= -Status.max) ? -code : Status.ioError));
        if (code == 0)
            return Result!DesktopEvent(DesktopEvent.init, desktopError(Status.notFound));
        return Result!DesktopEvent(DesktopEvent(cast(EventKind) event.kind, event.x, event.y, event.keyCode));
    }

    // SAFETY: The live SDL handle belongs to this thread. Its renderer validates and consumes
    // exactly this sized draw list before returning. No foreign callbacks access this slice.
    Error present(scope const(ubyte)[] bytes) @trusted nothrow @nogc
    {
        version (FlintNativeSdl3)
        {
            if (sdl !is null)
                return desktopError(flint_window_submit(sdl, bytes.ptr, bytes.length));
        }
        return desktopError(Status.unsupported);
    }

    // SAFETY: Only the owning main thread destroys the handle. Queue admission and worker
    // tickets have been retired before this call. Backend teardown disconnects C callbacks.
    void close() @trusted nothrow @nogc
    {
        version (FlintNativeSdl3)
        {
            auto owned = sdl;
            sdl = null;
            if (owned !is null)
                flint_window_free(owned);
        }
        version (FlintDesktopWebkitGtk)
        {
            auto web = webkit;
            webkit = null;
            if (web !is null)
                flint_webkit_window_free(web);
        }
    }
}
