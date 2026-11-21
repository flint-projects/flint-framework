/// Native desktop windows, bounded draw lists and scoped application events.
module flint.desktop;

import flint.arena : Error;
import flint.conc : Context, WorkFn;
import flint.desktop.ffi.platform : Identity;
import flint.desktop.runtime : closeWindow, openWindow, post, runWindow, sendWork;

public import flint.desktop.types : DesktopBackend, DesktopEvent, DesktopHandler, EventKind, WindowOptions;

@safe:

/// Generation-checked reference to a desktop owner session.
struct Window
{
    private Identity identity;

    /// Create the selected backend on the process UI thread.
    Error open(WindowOptions options)
    {
        return openWindow(identity, options);
    }

    /// Dispatch owner-thread events until close, cancellation or a handler error.
    Error run(scope DesktopHandler handler, ref Context context) nothrow @nogc
    {
        return runWindow(identity, handler, context);
    }

    /// Validate and copy an entire draw list into the SDL window's bounded queue.
    Error submit(scope const(ubyte)[] commandBuffer) nothrow @nogc
    {
        return post(identity, commandBuffer, true);
    }

    /// Copy an application message from any thread into the bounded window queue.
    Error postMessage(scope const(ubyte)[] bytes) nothrow @nogc
    {
        return post(identity, bytes, false);
    }

    /// Copy input into a window-owned Conc work ticket. A successful result becomes a message.
    Error submitWork(scope const(ubyte)[] input, WorkFn job) nothrow @nogc
    {
        return sendWork(identity, input, job);
    }

    /// Retire the generation, cancel and join work, then release native resources on the UI thread.
    Error close() nothrow @nogc
    {
        return closeWindow(identity);
    }
}
