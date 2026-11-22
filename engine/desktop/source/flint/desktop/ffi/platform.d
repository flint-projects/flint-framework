/// Scoped native platform calls, owner-thread events and cross-thread copied packets.
module flint.desktop.ffi.platform;

import flint.arena : Error, Result, Status;
import flint.desktop.types : DesktopBackend, DesktopEvent, EventKind, WindowOptions;

@safe:

version (FlintNativeWebkitgtk) import flint.desktop.ffi.webkit : Webview, WebviewEvent, webviewClose, webviewEvaluate,
    webviewEvent, webviewOpen, webviewPump, webviewRequestClose, webviewResize, webviewTake, webviewUri;

nothrow @nogc:

private struct SdlWindow;

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
}

version (linux)
{
    version (FlintNativeSdl3)
        version = FlintDesktopQueues;
    else version (FlintNativeWebkitgtk)
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
        version (FlintNativeWebkitgtk)
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
    version (FlintNativeWebkitgtk) private Webview* webview;

    // SAFETY: The owner thread has validated the bounded inputs. C copies the title during this
    // call. The webview borrows option slices that the owner slot retains until close.
    Error open(ref const WindowOptions options) @trusted nothrow @nogc
    {
        char[257] title = 0;
        title[0 .. options.title.length] = options.title[];
        if (options.backend == DesktopBackend.sdl)
        {
            version (FlintNativeSdl3)
                sdl = flint_window_new(title.ptr, options.width, options.height, options.resizable);
            return sdl is null ? desktopError(Status.unavailable) : Error.init;
        }
        version (FlintNativeWebkitgtk)
        {
            webview = webviewOpen(title[0 .. options.title.length + 1], options);
            return webview is null ? desktopError(Status.unavailable) : Error.init;
        }
        else
            return desktopError(Status.unsupported);
    }

    // SAFETY: The live owner-thread pointer is held until the poll returns. C writes one POD
    // event and retains no D storage. Webview callbacks only fill the pinned native state.
    Result!DesktopEvent poll() @trusted nothrow @nogc
    {
        NativeEvent event;
        int code;
        version (FlintNativeSdl3)
        {
            if (sdl !is null)
                code = flint_window_poll(sdl, &event);
        }
        version (FlintNativeWebkitgtk)
        {
            if (webview !is null)
                return pollWebview();
        }
        if (code < 0)
            return Result!DesktopEvent(DesktopEvent.init, desktopError((code >= -Status.max) ? -code : Status.ioError));
        if (code == 0)
            return Result!DesktopEvent(DesktopEvent.init, desktopError(Status.notFound));
        return Result!DesktopEvent(DesktopEvent(cast(EventKind) event.kind, event.x, event.y, event.keyCode));
    }

    version (FlintNativeWebkitgtk)
    {
        private Result!DesktopEvent pollWebview()
        {
            webviewPump();
            int width, height;
            final switch (webviewEvent(webview, width, height))
            {
            case WebviewEvent.none:
                return Result!DesktopEvent(DesktopEvent.init, desktopError(Status.notFound));
            case WebviewEvent.close:
                return Result!DesktopEvent(DesktopEvent(EventKind.close));
            case WebviewEvent.resize:
                return Result!DesktopEvent(DesktopEvent(EventKind.resize, width, height));
            case WebviewEvent.crashed:
                return Result!DesktopEvent(DesktopEvent.init,
                        Error(Status.ioError, "webview process terminated"));
            }
        }
    }

    /// Copy the next frontend frame and its page origin, if any.
    bool takeFrame(scope ubyte[] bytes, out size_t length, scope char[] origin, out size_t originLength)
    {
        version (FlintNativeWebkitgtk)
        {
            if (webview !is null)
                return webviewTake(webview, bytes, length, origin, originLength);
        }
        return false;
    }

    /// Evaluate trusted Flint bridge source in the page.
    Error evaluate(scope const(char)[] script)
    {
        version (FlintNativeWebkitgtk)
        {
            if (webview !is null)
            {
                webviewEvaluate(webview, script);
                return Error.init;
            }
        }
        return desktopError(Status.unsupported);
    }

    /// Ask the native window to resize, as a window manager would.
    void resize(int width, int height)
    {
        version (FlintNativeWebkitgtk)
        {
            if (webview !is null)
                webviewResize(webview, width, height);
        }
    }

    /// Ask the native window to close, as a window manager would.
    void requestClose()
    {
        version (FlintNativeWebkitgtk)
        {
            if (webview !is null)
                webviewRequestClose(webview);
        }
    }

    /// Current page address copied into the caller's span.
    const(char)[] location(return scope char[] storage)
    {
        version (FlintNativeWebkitgtk)
        {
            if (webview !is null)
                return webviewUri(webview, storage);
        }
        return null;
    }

    /// Navigations and frames refused by the webview policy.
    ulong refusals()
    {
        version (FlintNativeWebkitgtk)
        {
            if (webview !is null)
                return webview.deniedNavigations + webview.droppedFrames;
        }
        return 0;
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
        version (FlintNativeWebkitgtk)
        {
            auto web = webview;
            webview = null;
            webviewClose(web);
        }
    }
}
