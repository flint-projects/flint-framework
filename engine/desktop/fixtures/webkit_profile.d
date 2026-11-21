module webkit_profile;

import flint.arena : Error, RequestArena, Status;
import flint.conc : Context, Deadline;
import flint.desktop : DesktopBackend, DesktopEvent, EventKind, Window, WindowOptions;
import std.stdio : writeln;
import std.string : toStringz;

@safe:

extern (C) private int flint_test_trust_loopback(const(char)* pem) @system;

// SAFETY: This fixture passes a scoped NUL-terminated path to a synchronous test-only SDK call.
private bool trust(string path) @trusted
{
    return flint_test_trust_loopback(path.toStringz) != 0;
}

private enum localHtml = `<!doctype html><meta charset="utf-8"><title>Flint IPC fixture</title>
<script>
setTimeout(() => {
  window.webkit.messageHandlers.flint.postMessage([2, 1, 1, 0, 69]);
  window.webkit.messageHandlers.flint.postMessage([1, 2, 1, 0, 69]);
  window.webkit.messageHandlers.flint.postMessage([1, 1, 10, 0, 69]);
  const popupBlocked = window.open("https://unapproved.invalid/") === null;
  window.location = "https://unapproved.invalid/";
  setTimeout(() => {
    const body = popupBlocked ? [111, 107] : [110, 111];
    window.webkit.messageHandlers.flint.postMessage([1, 1, 2, 0, ...body]);
  }, 150);
}, 150);
</script>`;

private void local()
{
    Window window;
    auto options = WindowOptions.init;
    options.backend = DesktopBackend.systemWebView;
    options.html = localHtml;
    const opened = window.open(options);
    assert(opened.code == Status.ok, opened.message);
    assert(window.submit([0x46, 0x44, 0x4c, 1, 0, 0, 0, 0]).code == Status.unsupported);
    bool seen;
    auto context = Context.init.withDeadline(Deadline.afterMillis(12_000));
    const outcome = window.run((ref DesktopEvent event, ref scope RequestArena arena) @safe nothrow @nogc {
        if (event.kind != EventKind.message)
            return Error.init;
        assert(arena.read(event.message, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
                assert(bytes == cast(const(ubyte)[]) "ok");
            }) == Status.ok);
        seen = true;
        return window.close();
    }, context);
    assert(outcome.code == Status.ok && seen, outcome.message);
    writeln("Private app IPC accepted; malformed IPC, popup and unapproved HTTPS navigation denied");
}

private void remote(string origin, string pem)
{
    Window window;
    auto options = WindowOptions.init;
    options.backend = DesktopBackend.systemWebView;
    options.httpsOrigin = origin;
    options.html = `<!doctype html><script>setTimeout(() => location.href = "` ~ origin ~ `/", 100);</script>`;
    const opened = window.open(options);
    assert(opened.code == Status.ok && trust(pem), opened.message);
    size_t delivered;
    auto context = Context.init.withDeadline(Deadline.afterMillis(4500));
    const outcome = window.run((ref DesktopEvent event, ref scope RequestArena arena) @safe nothrow @nogc {
        if (event.kind == EventKind.message)
            ++delivered;
        assert(arena.stats().used == 0);
        return Error.init;
    }, context);
    assert(outcome.code == Status.timedOut && delivered == 0, outcome.message);
    writeln("Allowlisted HTTPS page acquired zero host IPC deliveries");
}

void main(string[] args)
{
    if (args.length == 1)
        local();
    else
    {
        assert(args.length == 3);
        remote(args[1], args[2]);
    }
}
