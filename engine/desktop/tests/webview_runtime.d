module flint.desktop.webview_runtime_tests;

import core.stdc.stdlib : getenv;
import core.thread : Thread;
import flint.arena : Buffer, Error, RequestArena, Result, Status, Text;
import flint.conc : Context, Deadline;
import flint.desktop : Asset, Capability, Command, DesktopBackend, DesktopCommands, DesktopEvent,
    EventKind, InvokeContext, Listen, Window, WindowOptions;
import flint.desktop.runtime : nativeAddress, nativeRequestClose, nativeResize;

version (FlintNativeWebkitgtk) import flint.desktop.ffi.webkit : displayBackend;

@safe:

private WindowOptions page(string title, immutable(Asset)[] files, immutable(Capability)[] grants = null)
{
    WindowOptions options;
    options.title = title;
    options.width = 360;
    options.height = 240;
    options.backend = DesktopBackend.systemWebView;
    options.assets = files;
    options.capabilities = grants;
    return options;
}

@("Webview options are validated before any native call")
unittest
{
    static immutable Asset[] files = [Asset("index.html", "<p>x")];
    Window window;
    auto missing = page("Flint", null);
    assert(window.open(missing).code == Status.invalidArgument);
    auto label = page("Flint", files);
    label.label = "bad label";
    assert(window.open(label).code == Status.invalidArgument);
    auto traversal = page("Flint", [Asset("../index.html", "x")]);
    assert(window.open(traversal).code == Status.invalidArgument);
    auto command = page("Flint", files, [Capability("c", ["main"], ["no spaces"])]);
    assert(window.open(command).code == Status.invalidArgument);
    auto origin = page("Flint", files, [
        Capability("c", ["main"], ["x"], null, ["http://example.com"])
    ]);
    assert(window.open(origin).code == Status.invalidArgument);
}

version (FlintNativeWebkitgtk)
{
    private ref Context deadline(return ref Context context) @safe
    {
        context = Context.init.withDeadline(Deadline.afterMillis(15_000));
        return context;
    }

    /// Requests a resize after the copied message, then closes as a window manager would.
    private struct Lifecycle
    {
        Window window;
        bool message, resized, closed;
        int width, height;

        Error visit(ref DesktopEvent event, ref scope RequestArena arena) @safe nothrow @nogc
        {
            if (event.kind == EventKind.message)
            {
                message = arena.read(event.message, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
                    assert(bytes == cast(const(ubyte)[]) "owned");
                }) == Status.ok;
                const resize = nativeResize(window.handle(), 420, 300);
                return resized ? nativeRequestClose(window.handle()) : resize;
            }
            if (event.kind == EventKind.resize && event.x > 0 && event.y > 0)
                return resizedTo(event.x, event.y);
            closed = closed || event.kind == EventKind.close;
            return Error.init;
        }

        private Error resizedTo(int x, int y) @safe nothrow @nogc
        {
            const first = !resized;
            resized = true;
            width = x;
            height = y;
            return message && first ? nativeRequestClose(window.handle()) : Error.init;
        }
    }

    @("Webview window: owner-thread lifecycle, copied cross-thread messages, resize and window-manager close")
    @system unittest
    {
        static immutable Asset[] files = [
            Asset("index.html", "<!doctype html><title>lifecycle</title><p>lifecycle")
        ];
        Window window;
        assert(window.open(page("Flint lifecycle", files)).code == Status.ok);
        scope (exit)
            window.close();
        assert(window.open(page("again", files)).code == Status.conflict);
        if (getenv("WAYLAND_DISPLAY") !is null)
            assert(displayBackend() == "GdkWaylandDisplay", "GTK must use its native Wayland backend");

        auto alias_ = window;
        Status openCode, closeCode, emitCode, postCode;
        auto worker = new Thread(() {
            Window wrongThread;
            openCode = wrongThread.open(page("worker", files)).code;
            closeCode = alias_.close().code;
            emitCode = alias_.emit("tick", 1).code;
            ubyte[5] owned = ['o', 'w', 'n', 'e', 'd'];
            postCode = alias_.postMessage(owned[]).code;
            owned[] = 0;
        });
        worker.start();
        worker.join();
        assert(openCode == Status.permissionDenied && closeCode == Status.permissionDenied);
        assert(emitCode == Status.permissionDenied && postCode == Status.ok);

        auto observer = Lifecycle(window);
        Context context;
        const run = window.run(&observer.visit, deadline(context));
        assert(run.code == Status.ok, run.message);
        assert(observer.message && observer.resized && observer.closed);
        assert(observer.width > 0 && observer.height > 0);
        assert(alias_.postMessage([]).code == Status.invalidArgument);
        assert(window.emit("tick", 1).code == Status.invalidArgument);

        assert(window.open(page("Flint reopened", files)).code == Status.ok);
        assert(window.close().code == Status.ok);
        assert(window.close().code == Status.ok, "closing a closed window is idempotent");
    }

    private struct AddArgs
    {
        long a;
        long b;
    }

    private struct Sum
    {
        long value;
    }

    private struct Greet
    {
        Text name;
        uint times;
    }

    private struct Greeting
    {
        Text text;
    }

    private struct Click
    {
        long count;
    }

    private struct Report
    {
        long sum;
        Text greeting;
        Text denied;
        Text unknown;
        Text missing;
        Text invalid;
        long tick;
        Text href;
        Text error;
        bool styled;
    }

    private struct Copy
    {
        char[96] bytes;
        size_t length;

        void set(ref scope RequestArena arena, Text value) nothrow @nogc
        {
            arena.read(value.bytes, (scope const(ubyte)[] source) @safe nothrow @nogc {
                length = source.length < bytes.length ? source.length : bytes.length;
                bytes[0 .. length] = cast(const(char)[]) source[0 .. length];
            });
        }

        const(char)[] text() const return
        {
            return bytes[0 .. length];
        }
    }

    @DesktopCommands private struct Probe
    {
        long adds;
        long clicks;
        bool secretRan;
        bool forbiddenRan;
        bool finished;
        long sum;
        long tick;
        ulong refusals;
        bool styled;
        Copy greeting, denied, unknown, missing, invalid, href, error, origin;

        @Command("add")
        Result!Sum add(scope const ref AddArgs args, ref scope InvokeContext context) nothrow @nogc
        {
            ++adds;
            return Result!Sum(Sum(args.a + args.b));
        }

        @Command("greet")
        Result!Greeting greet(scope const ref Greet request, ref scope InvokeContext context) nothrow @nogc
        {
            ubyte[96] text;
            size_t used;
            void append(scope const(ubyte)[] part) @safe nothrow @nogc
            {
                const length = part.length < text.length - used ? part.length : text.length - used;
                text[used .. used + length] = part[0 .. length];
                used += length;
            }

            const status = context.arena.read(request.name.bytes, (scope const(ubyte)[] name) @safe nothrow @nogc {
                foreach (_; 0 .. request.times)
                {
                    append(cast(const(ubyte)[]) "Hello, ");
                    append(name);
                    append(cast(const(ubyte)[]) "! ");
                }
            });
            if (status != Status.ok)
                return Result!Greeting(Greeting.init, Error(status));
            auto copied = context.arena.copyIn(text[0 .. used ? used - 1 : 0]);
            if (!copied.ok())
                return Result!Greeting(Greeting.init, copied.error);
            return Result!Greeting(Greeting(Text(copied.value)));
        }

        @Command("secret")
        Error secret(ref scope InvokeContext context) nothrow @nogc
        {
            secretRan = true;
            return Error.init;
        }

        @Listen("clicked")
        Error clicked(scope const ref Click click, ref scope InvokeContext context) nothrow @nogc
        {
            clicks = click.count;
            return context.emit("tick", Click(click.count + 1));
        }

        @Listen("forbidden")
        Error forbidden(scope const ref Click click, ref scope InvokeContext context) nothrow @nogc
        {
            forbiddenRan = true;
            return Error.init;
        }

        @Command("finish")
        Error finish(scope const ref Report report, ref scope InvokeContext context) nothrow @nogc
        {
            finished = true;
            sum = report.sum;
            tick = report.tick;
            styled = report.styled;
            greeting.set(context.arena, report.greeting);
            denied.set(context.arena, report.denied);
            unknown.set(context.arena, report.unknown);
            missing.set(context.arena, report.missing);
            invalid.set(context.arena, report.invalid);
            href.set(context.arena, report.href);
            error.set(context.arena, report.error);
            origin.length = context.origin.length;
            origin.bytes[0 .. origin.length] = context.origin[];
            char[256] location;
            nativeAddress(context.identity, location[], refusals);
            return context.close();
        }
    }

    private struct Application
    {
        Probe probe;
    }

    private enum scenarioPage = `<!doctype html><meta charset="utf-8"><title>commands</title>
<link rel="stylesheet" href="style.css"><script src="scenario.js"></script>`;

    private enum scenarioScript = `const code = async (call) => {
  try { await call(); return "none"; } catch (error) { return String(error.code); }
};
(async () => {
  const sum = await flint.invoke("add", { a: 2, b: 40 });
  const greeting = await flint.invoke("greet", { name: "Ada", times: 2 });
  const denied = await code(() => flint.invoke("secret"));
  const unknown = await code(() => flint.invoke("nope", { x: 1 }));
  const missing = await code(() => flint.invoke("missing"));
  const invalid = await code(() => flint.invoke("add", { a: "two", b: 40 }));
  const ticked = new Promise((resolve) => flint.listen("tick", resolve));
  flint.emit("forbidden", { count: 9 });
  flint.emit("clicked", { count: 3 });
  const tick = await ticked;
  location.href = "https://example.com/";
  window.open("https://example.com/popup");
  await new Promise((resolve) => setTimeout(resolve, 100));
  await flint.invoke("finish", { sum: sum.value, greeting: greeting.text, denied, unknown, missing, invalid,
    tick: tick.count, href: location.href, error: "",
    styled: getComputedStyle(document.body).marginTop === "7px" });
})().catch((error) => flint.invoke("finish", { sum: 0, greeting: "", denied: "", unknown: "", missing: "",
  invalid: "", tick: 0, href: "", error: String(error && error.message || error), styled: false }));
`;

    @("Typed JS→D commands, D→JS and JS→D events, capability and navigation denial")
    @system unittest
    {
        static immutable Asset[] files = [
            Asset("index.html", scenarioPage), Asset("scenario.js", scenarioScript),
            Asset("style.css", "body { margin-top: 7px; }"),
        ];
        static immutable Capability[] grants = [
            Capability("main", ["main"], ["add", "greet", "missing", "finish"], ["clicked"]),
        ];
        Window window;
        assert(window.open(page("Flint commands", files, grants)).code == Status.ok);
        scope (exit)
            window.close();
        Application app;
        Context context;
        const served = window.serve(app, deadline(context));
        assert(served.code == Status.ok, served.message);
        with (app.probe)
        {
            assert(finished, "frontend scenario did not finish");
            assert(error.text == "", error.text);
            assert(sum == 42 && adds == 1, "the malformed add must be rejected before the command runs");
            assert(greeting.text == "Hello, Ada! Hello, Ada!", greeting.text);
            assert(denied.text == "permissionDenied" && unknown.text == "permissionDenied", denied.text);
            assert(missing.text == "notFound" && invalid.text == "invalidArgument", invalid.text);
            assert(!secretRan && !forbiddenRan && clicks == 3 && tick == 4);
            assert(href.text == "flint://localhost/index.html", href.text);
            assert(origin.text == "flint://localhost", origin.text);
            assert(refusals >= 1, "the cross-origin navigation must be refused");
            assert(styled, "external stylesheet must be served with a CSS media type");
        }
    }

    private enum burst = `<!doctype html><meta charset="utf-8"><title>burst</title><script>
(async () => {
  const calls = [];
  for (let index = 0; index < 200; ++index) calls.push(flint.invoke("add", { a: index, b: 1 }));
  const outcomes = await Promise.allSettled(calls);
  const ok = outcomes.filter((entry) => entry.status === "fulfilled").length;
  const full = outcomes.filter((entry) => entry.status === "rejected"
    && entry.reason.code === "resourceExhausted").length;
  for (let index = 0; index < 50; ++index) flint.invoke("add", { a: 1, b: 1 }).catch(() => {});
  flint.invoke("finish", { sum: ok, tick: full, greeting: "", denied: "", unknown: "", missing: "", invalid: "",
    href: "", error: "" });
  for (let index = 0; index < 50; ++index) flint.invoke("add", { a: 1, b: 1 }).catch(() => {});
})();
</script>`;

    private Error idle(scope const(ubyte)[], scope ubyte[], out size_t written) @safe nothrow @nogc
    {
        written = 0;
        return Error.init;
    }

    @("Shutdown with in-flight frames, queued messages and worker tickets touches no closed window")
    @system unittest
    {
        static immutable Asset[] files = [Asset("index.html", burst)];
        static immutable Capability[] grants = [Capability("main", ["*"], ["add", "finish"])];
        Window window;
        assert(window.open(page("Flint burst", files, grants)).code == Status.ok);
        scope (exit)
            window.close();
        foreach (_; 0 .. 32)
            assert(window.postMessage(cast(const(ubyte)[]) "queued").code == Status.ok);
        foreach (_; 0 .. 8)
            assert(window.submitWork(cast(const(ubyte)[]) "input", &idle).code == Status.ok);

        Application app;
        Context context;
        const served = window.serve(app, deadline(context));
        assert(served.code == Status.ok, served.message);
        assert(app.probe.finished && app.probe.sum + app.probe.tick == 200);
        assert(app.probe.adds >= app.probe.sum && app.probe.adds <= app.probe.sum + 50);
        assert(window.postMessage([]).code == Status.invalidArgument);

        assert(window.open(page("Flint burst reopened", files, grants)).code == Status.ok);
        assert(window.close().code == Status.ok);
    }
}
