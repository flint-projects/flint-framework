module app;

import flint.arena : Error, Result, Status, Text;
import flint.conc : Context, Deadline;
import flint.engine.desktop : Asset, Capability, Command, DesktopBackend, DesktopCommands,
    InvokeContext, Listen, Window, WindowOptions;
import std.stdio : writefln;

@safe:

/// Arguments of `flint.invoke("greet", { name })`.
struct GreetRequest
{
    /// Name typed into the form, valid for this invocation.
    Text name;
}

/// Greeting returned to the frontend.
struct Greeting
{
    /// Text built in the invocation arena.
    Text message;
}

/// Arguments of `flint.invoke("increment", { by })`.
struct Step
{
    /// Signed change, at most 1000 either way.
    long by;
}

/// Counter value returned by commands and carried by `count-changed` events.
struct Count
{
    /// Current value.
    long value;
}

/// Payload of the frontend's `ui-ready` event.
struct Ready
{
    /// Frontend script revision.
    uint revision;
}

/// What the scripted self-test observed in the page.
struct Report
{
    /// Counter value returned by the final increment.
    long count;
    /// Greeting text shown in the page.
    Text greeting;
    /// Number of `count-changed` events received.
    long ticks;
    /// Counter value rendered in the page.
    long shown;
    /// Whether an ungranted command was rejected with permissionDenied.
    bool denied;
    /// Whether a malformed argument was rejected with invalidArgument.
    bool rejected;
}

/// Counter commands; every change is pushed to the frontend as an event.
@DesktopCommands struct Counter
{
    /// Current value, owned by the UI thread.
    long value;

    /// Add a bounded step and broadcast the new value.
    @Command("increment")
    Result!Count increment(scope const ref Step step, ref scope InvokeContext context) nothrow @nogc
    {
        if (step.by < -1000 || step.by > 1000)
            return Result!Count(Count.init, Error(Status.invalidArgument, "step must be within ±1000"));
        value += step.by;
        const emitted = context.emit("count-changed", Count(value));
        return Result!Count(Count(value), emitted);
    }

    /// Return the counter to zero.
    @Command("reset")
    Error reset(ref scope InvokeContext context) nothrow @nogc
    {
        value = 0;
        return context.emit("count-changed", Count(value));
    }
}

/// Greeting command building its reply in the invocation arena.
@DesktopCommands struct Greeter
{
    /// Reply "Hello, <name>!" for a name of 1–64 bytes.
    @Command("greet")
    Result!Greeting greet(scope const ref GreetRequest request, ref scope InvokeContext context) nothrow @nogc
    {
        ubyte[80] text;
        text[0 .. 7] = cast(const(ubyte)[]) "Hello, ";
        size_t used = 7;
        const status = context.arena.read(request.name.bytes, (scope const(ubyte)[] name) @safe nothrow @nogc {
            if (!name.length || name.length > 64)
                return;
            text[used .. used + name.length] = name[];
            used += name.length;
            text[used++] = '!';
        });
        if (status != Status.ok || used == 7)
            return Result!Greeting(Greeting.init, Error(Status.invalidArgument, "name must be 1-64 bytes"));
        auto copied = context.arena.copyIn(text[0 .. used]);
        if (!copied.ok())
            return Result!Greeting(Greeting.init, copied.error);
        return Result!Greeting(Greeting(Text(copied.value)));
    }
}

/// Session lifecycle: frontend readiness and the self-test report.
@DesktopCommands struct Session
{
    /// The frontend loaded and installed its listeners.
    bool ready;
    /// The self-test report matched the expected observations.
    bool passed;
    /// Greeting reported by the page.
    char[80] greeting;
    /// Bytes used in `greeting`.
    size_t greetingLength;

    /// Record that the frontend is listening.
    @Listen("ui-ready")
    Error uiReady(scope const ref Ready event, ref scope InvokeContext context) nothrow @nogc
    {
        ready = true;
        return Error.init;
    }

    /// Check the scripted session and close the window.
    @Command("report")
    Error report(scope const ref Report observed, ref scope InvokeContext context) nothrow @nogc
    {
        context.arena.read(observed.greeting.bytes, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            greetingLength = bytes.length < greeting.length ? bytes.length : greeting.length;
            greeting[0 .. greetingLength] = cast(const(char)[]) bytes[0 .. greetingLength];
        });
        passed = ready && observed.count == 2 && observed.shown == 2 && observed.ticks == 5
            && observed.denied && observed.rejected && greeting[0 .. greetingLength] == "Hello, Ada!";
        return context.close();
    }
}

/// Explicit root of the generated command table.
struct Application
{
    /// Counter commands.
    Counter counter;
    /// Greeting command.
    Greeter greeter;
    /// Lifecycle commands and listeners.
    Session session;
}

/// Frontend files served from `flint://localhost/`.
static immutable Asset[] assets = [
    Asset("index.html", import("index.html")), Asset("selftest.html", import("selftest.html")),
    Asset("app.js", import("app.js")), Asset("style.css", import("style.css")),
];

/// Deny-by-default grants for the main window.
static immutable Capability[] capabilities = [
    Capability("main-window", ["main"], ["greet", "increment", "reset", "report"], ["ui-ready"]),
];

int main(string[] arguments)
{
    const selfTest = arguments.length == 2 && arguments[1] == "--self-test";
    if (arguments.length > 1 && !selfTest)
    {
        writefln("usage: %s [--self-test]", arguments[0]);
        return 2;
    }
    WindowOptions options;
    options.title = "Flint desktop";
    options.width = 480;
    options.height = 420;
    options.backend = DesktopBackend.systemWebView;
    options.entryAsset = selfTest ? "selftest.html" : "index.html";
    options.assets = assets;
    options.capabilities = capabilities;

    Window window;
    const opened = window.open(options);
    if (opened.code != Status.ok)
    {
        writefln("golden-desktop: cannot open window: %s", opened.message);
        return 1;
    }
    Application app;
    auto context = selfTest ? Context.init.withDeadline(Deadline.afterMillis(20_000)) : Context.init;
    const served = window.serve(app, context);
    if (served.code != Status.ok)
    {
        writefln("golden-desktop: %s", served.message);
        return 1;
    }
    if (selfTest)
    {
        writefln("golden-desktop self-test: %s (count=%d, greeting=%s)", app.session.passed
                ? "passed" : "FAILED", app.counter.value, app.session.greeting[0 .. app.session.greetingLength]);
        return app.session.passed ? 0 : 1;
    }
    return 0;
}
