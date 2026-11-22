module flint.desktop.sdl_runtime_tests;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread.osthread : Thread;
import core.time : dur;
import flint.arena : Buffer, Error, RequestArena, Status;
import flint.conc : Context, Deadline;
import flint.conc.wait : replaceWaitHook;
import flint.desktop : Asset, DesktopBackend, DesktopEvent, EventKind, Window, WindowOptions;

@safe:

version (FlintNativeSdl3)
{
    @("SDL owner-only creation and teardown, with worker-posted copied payloads")
    @system unittest
    {
        Window window;
        assert(window.open(WindowOptions("Flint thread fixture", 144, 90)).code == Status.ok);
        scope (exit)
            window.close();

        auto alias_ = window;
        Status openCode, closeCode, postCode;
        auto worker = new Thread(() {
            Window wrongThread;
            openCode = wrongThread.open(WindowOptions.init).code;
            closeCode = alias_.close().code;
            ubyte[5] owned = ['o', 'w', 'n', 'e', 'd'];
            postCode = alias_.postMessage(owned[]).code;
            owned[] = 0;
        });
        worker.start();
        worker.join();
        assert(openCode == Status.permissionDenied && closeCode == Status.permissionDenied && postCode == Status.ok);

        bool seen;
        auto context = Context.init.withDeadline(Deadline.afterMillis(4000));
        const run = window.run((ref DesktopEvent event, ref scope RequestArena arena) @safe nothrow @nogc {
            if (event.kind != EventKind.message)
                return Error.init;
            seen = arena.read(event.message, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
                assert(bytes == cast(const(ubyte)[]) "owned");
            }) == Status.ok;
            return window.close();
        }, context);
        assert(run.code == Status.ok && seen);
        assert(alias_.postMessage([]).code == Status.invalidArgument);
    }

    @("SDL draw and packet admission limits, viewport resize and graceful reactor close")
    @system unittest
    {
        Window window;
        assert(window.open(WindowOptions("Flint draw fixture", 144, 90)).code == Status.ok);
        scope (exit)
            window.close();
        assert(window.submit([1, 2, 3]).code == Status.invalidArgument);
        assert(window.submit(frame).code == Status.ok);

        auto native = activeWindow();
        assert(native !is null && sdlSetWindowSize(native, 160, 100));
        assert(sdlSyncWindow(native));
        foreach (_; 0 .. 255)
            assert(window.postMessage([]).code == Status.ok);
        assert(window.postMessage([]).code == Status.resourceExhausted);

        ulong events;
        bool resize;
        auto context = Context.init.withDeadline(Deadline.afterMillis(4000));
        const run = window.run((ref DesktopEvent event, ref scope RequestArena arena) @safe nothrow @nogc {
            if (event.kind == EventKind.resize)
                resize = resize || (event.x == 160 && event.y == 100);
            if (event.kind == EventKind.message && ++events == 255)
                return window.close();
            assert(arena.stats().used == 0);
            return Error.init;
        }, context);
        assert(run.code == Status.ok && resize && events == 255);
    }

    @("Owned Conc work becomes a message and its arena handle expires")
    unittest
    {
        Window window;
        assert(window.open(WindowOptions.init).code == Status.ok);
        scope (exit)
            window.close();
        assert(window.submitWork(cast(const(ubyte)[]) "work", &echo).code == Status.ok);
        Buffer stale;
        int seen;
        auto context = Context.init.withDeadline(Deadline.afterMillis(4000));
        const run = window.run((ref DesktopEvent event, ref scope RequestArena arena) @safe nothrow @nogc {
            if (event.kind != EventKind.message)
                return Error.init;
            if (++seen == 1)
            {
                stale = event.message;
                assert(arena.read(stale, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
                        assert(bytes == cast(const(ubyte)[]) "work");
                    }) == Status.ok);
                return window.postMessage([]);
            }
            assert(arena.read(stale, (scope const(ubyte)[]) @safe nothrow @nogc {}) == Status.invalidArgument);
            return window.close();
        }, context);
        assert(run.code == Status.ok && seen == 2);
    }

    @("A cooperative close owns retirement until every worker joins")
    unittest
    {
        Window window;
        assert(window.open(WindowOptions.init).code == Status.ok);
        scope (exit)
            window.close();
        atomicStore(releaseWorkers, false);
        atomicStore(startedWorkers, 0);
        scope (exit)
            atomicStore(releaseWorkers, true);
        foreach (_; 0 .. 4)
            assert(window.submitWork([], &waitForClose).code == Status.ok);
        waitForStarted();

        closingAlias = window;
        reentrantClose = Status.ok;
        const previous = replaceWaitHook(&tryCloseFromWait);
        scope (exit)
            replaceWaitHook(previous);
        assert(window.close().code == Status.ok);
        assert(reentrantClose == Status.conflict);
        assert(closingAlias.postMessage([]).code == Status.invalidArgument);
    }

    @("Motion flood, joining 256 tickets, and generation retirement")
    @system unittest
    {
        Window window;
        assert(window.open(WindowOptions("Flint shutdown fixture", 168, 120)).code == Status.ok);
        scope (exit)
            window.close();
        atomicStore(releaseWorkers, false);
        atomicStore(startedWorkers, 0);
        scope (exit)
            atomicStore(releaseWorkers, true);

        foreach (_; 0 .. 256)
            assert(window.submitWork(cast(const(ubyte)[]) "late", &waitForClose).code == Status.ok);
        assert(window.submitWork([], &waitForClose).code == Status.resourceExhausted);
        waitForStarted();
        pushMotionAndClose(activeWindow());

        auto stale = window;
        ulong pointerEvents, closeEvents, workMessages;
        auto context = Context.init.withDeadline(Deadline.afterMillis(4000));
        const run = window.run((ref DesktopEvent event, ref scope RequestArena arena) @safe nothrow @nogc {
            if (event.kind == EventKind.close)
            {
                atomicStore(releaseWorkers, true);
                ++closeEvents;
                assert(window.postMessage([]).code == Status.invalidArgument);
                event.kind = EventKind.message;
            }
            else if (event.kind == EventKind.pointer)
                ++pointerEvents;
            else if (event.kind == EventKind.message)
                ++workMessages;
            assert(arena.stats().used == 0);
            return Error.init;
        }, context);
        assert(run.code == Status.ok && closeEvents == 1 && pointerEvents < 40 && workMessages == 0);
        assert(window.open(WindowOptions.init).code == Status.ok);
        assert(stale.postMessage([]).code == Status.invalidArgument);
        assert(stale.close().code == Status.ok);
        assert(window.postMessage([]).code == Status.ok);
        assert(window.close().code == Status.ok);
    }
}

version (FlintNativeWebkitgtk)
{
}
else
{
    @("A profile without the WebKitGTK provider leaves the webview unavailable")
    unittest
    {
        static immutable Asset[] files = [Asset("index.html", "<p>x")];
        Window window;
        auto options = WindowOptions.init;
        options.backend = DesktopBackend.systemWebView;
        options.assets = files;
        assert(window.open(options).code == Status.unsupported);
    }
}

version (FlintNativeSdl3)
{
    private immutable ubyte[] frame = [0x46, 0x44, 0x4c, 1, 1, 0, 0, 0, 1, 0, 4, 0, 17, 49, 83, 255];
    private Window closingAlias;
    private Status reentrantClose;

    private Error tryCloseFromWait(Deadline) nothrow @nogc
    {
        reentrantClose = closingAlias.close().code;
        atomicStore(releaseWorkers, true);
        Thread.sleep(1.dur!"msecs");
        return Error.init;
    }

    private shared bool releaseWorkers;
    private shared uint startedWorkers;

    private Error echo(scope const(ubyte)[] input, scope ubyte[] output, out size_t written) nothrow @nogc
    {
        output[0 .. input.length] = input[];
        written = input.length;
        return Error.init;
    }

    private Error waitForClose(scope const(ubyte)[] input, scope ubyte[] output, out size_t written) nothrow @nogc
    {
        atomicOp!"+="(startedWorkers, 1U);
        const expiry = Context.init.withDeadline(Deadline.afterMillis(3000));
        while (!atomicLoad(releaseWorkers))
        {
            if (expiry.cancelled())
                return Error(Status.timedOut, "close fixture worker timed out");
            Thread.sleep(1.dur!"msecs");
        }
        output[0 .. input.length] = input[];
        written = input.length;
        return Error.init;
    }

    private void waitForStarted() nothrow @nogc
    {
        const expiry = Context.init.withDeadline(Deadline.afterMillis(1000));
        while (atomicLoad(startedWorkers) != 4 && !expiry.cancelled())
            Thread.sleep(1.dur!"msecs");
        assert(atomicLoad(startedWorkers) == 4);
    }

    private struct SdlWindow;

    private struct SdlMotion
    {
        uint type;
        uint reserved;
        ulong timestamp;
        uint window;
        uint device;
        uint buttons;
        float x, y, xRelative, yRelative;
    }

    private union SdlEvent
    {
        SdlMotion motion;
        ubyte[128] padding;
    }

    static assert(SdlEvent.sizeof == 128);

    extern (C) private @system nothrow @nogc
    {
        pragma(mangle, "SDL_GetWindows") SdlWindow** sdlWindows(int*);
        pragma(mangle, "SDL_GetWindowID") uint sdlWindowId(SdlWindow*);
        pragma(mangle, "SDL_SetWindowSize") bool sdlSetWindowSize(SdlWindow*, int, int);
        pragma(mangle, "SDL_SyncWindow") bool sdlSyncWindow(SdlWindow*);
        pragma(mangle, "SDL_PushEvent") bool sdlPushEvent(SdlEvent*);
        pragma(mangle, "SDL_free") void sdlFree(void*);
    }

    private SdlWindow* activeWindow() @system nothrow @nogc
    {
        int count;
        auto windows = sdlWindows(&count);
        assert(windows !is null && count == 1);
        auto window = windows[0];
        sdlFree(windows);
        return window;
    }

    private void pushMotionAndClose(SdlWindow* window) @system nothrow @nogc
    {
        SdlEvent event;
        event.motion.type = 0x400;
        event.motion.window = sdlWindowId(window);
        foreach (index; 0 .. 8192)
        {
            event.motion.x = cast(float)(index % 168);
            assert(sdlPushEvent(&event));
        }
        event = SdlEvent.init;
        event.motion.type = 0x100;
        assert(sdlPushEvent(&event));
    }
}
