/// An application composed the way Flint Boot will compose it: flint:os turns SIGTERM and SIGINT into the
/// graceful and forced contexts that flint:engine-web's runApplication drains on (ADR-028 section 10).
/// Usage: flint-graceful-shutdown-fixture <port> <grace milliseconds>
module app;

import core.thread.osthread : Thread;
import core.time : dur;
import flint.arena : Error, Result, Status;
import flint.conc : Deadline;
import flint.os : watchShutdownSignals;
import flint.engine.reactor : Reactor;
import flint.engine.web : Get, QueryParam, RequestContext, RestController, ServerOptions, WorkerController, runApplication;
import std.conv : to;
import std.stdio : writeln;

@safe:

@RestController("")
private struct Endpoints
{
    @Get("/ping") Result!uint ping() nothrow @nogc
    {
        return Result!uint(1);
    }

    /// Answers after `ms` milliseconds on the owner fiber, unless the server cancels the request first.
    @Get("/slow") Result!uint slow(@QueryParam("ms", true) uint ms, ref scope RequestContext context)nothrow @nogc
    {
        const end = Deadline.afterMillis(ms);
        auto loop = Reactor.current();
        while (Deadline.afterMillis(0).monotonicNanoseconds < end.monotonicNanoseconds)
        {
            cast(void) loop.yieldUntil(end, context.cancellation);
            const checked = context.cancellation.check();
            if (checked.code != Status.ok)
                return Result!uint(0, checked);
        }
        return Result!uint(ms);
    }
}

/// A worker-thread handler that ignores cancellation, so a forced stop cannot join it.
@WorkerController @RestController("/worker")
private struct Stuck
{
    @Get("/stuck") Result!uint stuck()
    {
        Thread.sleep(dur!"seconds"(30));
        return Result!uint(30);
    }
}

private struct Application
{
    Endpoints endpoints;
    Stuck stuck;
}

int main(string[] arguments)
{
    if (arguments.length != 3)
        return 2;
    ServerOptions options;
    options.port = to!ushort(arguments[1]);
    options.shutdownTimeoutNanos = to!long(arguments[2]) * 1_000_000;
    auto signals = watchShutdownSignals();
    if (!signals.ok)
    {
        writeln("signals: ", signals.error.message);
        return 2;
    }
    Application application;
    const code = runApplication(application, options, null, signals.value.graceful(), signals.value.forced());
    writeln("exit ", code, " after ", signals.value.received(), " signal(s)");
    return code;
}
