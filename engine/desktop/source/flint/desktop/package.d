/// Native desktop windows with a system webview frontend, typed commands, events and capabilities.
module flint.desktop;

import flint.arena : Buffer, Error, RequestArena;
import flint.conc : Context, WorkFn;
import flint.desktop.ffi.platform : Identity;
import flint.desktop.ipc : IpcKind, IpcRouter;
import flint.desktop.runtime : closeWindow, emitValue, openWindow, post, runWindow, sendWork;

public import flint.desktop.ipc : Command, DesktopCommands, InvokeContext, Listen;
public import flint.desktop.types : Asset, Capability, DesktopBackend, DesktopEvent, DesktopHandler,
    EventKind, WindowOptions;

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
    /// Frontend invokes are rejected because no command router is installed.
    Error run(scope DesktopHandler handler, ref Context context) nothrow @nogc
    {
        return runWindow(identity, handler, null, context);
    }

    /// Run the window, routing permitted frontend calls to the `@DesktopCommands` fields of `app`.
    /// Window events go to `handler` when one is supplied.
    Error serve(App)(ref App app, ref Context context, scope DesktopHandler handler = null) nothrow @nogc
    {
        import flint.desktop.internal.router : route;

        scope IpcRouter router = (IpcKind kind, scope const(char)[] name, scope const(ubyte)[] body,
                ref scope InvokeContext invocation, ref Buffer result) @safe nothrow @nogc {
            return route(app, kind, name, body, invocation, result);
        };
        scope DesktopHandler ignore = (ref DesktopEvent event, ref scope RequestArena arena) @safe nothrow @nogc {
            return Error.init;
        };
        return runWindow(identity, handler is null ? ignore : handler, router, context);
    }

    /// Send a typed event to this window's frontend listeners from the UI thread.
    Error emit(T)(scope const(char)[] event, scope auto ref const T payload) nothrow @nogc
    {
        return emitValue(identity, event, payload);
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

    package(flint.desktop) Identity handle() const nothrow @nogc
    {
        return identity;
    }
}
