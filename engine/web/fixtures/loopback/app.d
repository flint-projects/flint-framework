/// Exercises request bindings, response drainage and owner-fiber cancellation over real sockets.
module app;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread.osthread : Thread;
import core.time : dur;
import flint.arena : Error, Result, Status, Text;
import flint.conc : Context, Deadline;
import flint.engine.reactor : Reactor;
import flint.validate : NotBlank, Valid;
import flint.engine.web : ControllerAdvice, enableHttp2, enableTls, Get, PathVariable, Post, QueryParam,
    RequestBody, RequestContext, Response, RestController, Server, ServerOptions, WorkerController,
    registerAdvice, registerController;
import std.conv : to;

@safe:

private shared bool stop;
private shared uint admitted;
private shared uint canceled;
private shared uint workStarted;
private shared uint workFinished;
private shared uint workCanceled;
private shared bool allowWork;

private struct Bounds
{
    long id;
    ulong size;
}

private struct Payload
{
    @NotBlank
    Text name;
}

private struct Observation
{
    uint admitted;
    uint canceled;
}

private struct WorkerValue
{
    uint id;
    size_t bytes;
}

@WorkerController
@RestController("/worker")
private struct WorkerFixture
{
    @Get("/:id")
    Result!WorkerValue allocate(@PathVariable("id") uint id, @QueryParam("slow") bool slow,
            ref scope RequestContext context)
    {
        atomicOp!"+="(workStarted, 1U);
        scope (exit)
            atomicOp!"+="(workFinished, 1U);
        if (slow)
        {
            bool noted;
            const end = Deadline.afterMillis(4_000);
            while (!atomicLoad(allowWork) && Deadline.afterMillis(0).monotonicNanoseconds < end.monotonicNanoseconds)
            {
                if (!noted && context.cancellation.cancelled())
                {
                    atomicOp!"+="(workCanceled, 1U);
                    noted = true;
                }
                Thread.sleep(dur!"msecs"(1));
            }
        }
        auto bytes = new ubyte[7 + id % 32];
        return Result!WorkerValue(WorkerValue(id, bytes.length));
    }
}

@ControllerAdvice
private struct FixtureAdvice
{
    Response handle(Error failure, ref scope RequestContext context) nothrow @nogc
    {
        if (failure.code != Status.conflict)
            return Response.init;
        if (failure.message != "request failed" || failure.offset != size_t.max)
            return Response.init;
        auto output = context.arena.copyIn(cast(const(ubyte)[]) "{\"error\":\"already exists\"}");
        return output.ok() ? Response(202, "application/json", output.value) : Response.init;
    }
}

@RestController("")
private struct Fixture
{
    @Get("/")
    Result!Response root(ref scope RequestContext context) nothrow @nogc
    {
        return large(context);
    }

    @Post("/")
    Result!Response rootPost(ref scope RequestContext context) nothrow @nogc
    {
        return large(context);
    }

    @Get("/typed/:id")
    Result!Bounds typed(@PathVariable("id") long id, @QueryParam("size", true) ulong size)nothrow @nogc
    {
        return Result!Bounds(Bounds(id, size));
    }

    @Post("/post")
    Result!Payload submit(@RequestBody @Valid scope const ref Payload payload) nothrow @nogc
    {
        return Result!Payload(payload);
    }

    @Get("/large")
    Result!Response large(ref scope RequestContext context) nothrow @nogc
    {
        auto bytes = context.arena.allocate(128 * 1024);
        if (!bytes.ok())
            return Result!Response(Response.init, bytes.error);
        const status = context.arena.write(bytes.value, (scope ubyte[] data) @safe nothrow @nogc {
            foreach (index, ref value; data)
                value = cast(ubyte)('a' + index % 23);
        });
        if (status != Status.ok)
            return Result!Response(Response.init, Error(status));
        return Result!Response(Response(200, "application/octet-stream", bytes.value));
    }

    @Get("/hold")
    Error hold(ref scope RequestContext context) nothrow @nogc
    {
        atomicOp!"+="(admitted, 1U);
        auto loop = Reactor.current();
        const slept = loop.yieldUntil(Deadline.afterMillis(30_000));
        const result = context.cancellation.check();
        if (result.code == Status.cancelled)
            atomicOp!"+="(canceled, 1U);
        return result.code != Status.ok ? result : slept;
    }

    @Get("/observations")
    Result!Observation observations() nothrow @nogc
    {
        return Result!Observation(Observation(atomicLoad(admitted), atomicLoad(canceled)));
    }

    @Get("/worker-observations")
    Result!Observation workerObservations() nothrow @nogc
    {
        return Result!Observation(Observation(atomicLoad(workStarted), atomicLoad(workFinished)));
    }

    @Get("/worker-canceled")
    Result!uint workerCanceled() nothrow @nogc
    {
        return Result!uint(atomicLoad(workCanceled));
    }

    @Get("/release-worker")
    Error releaseWorker() nothrow @nogc
    {
        atomicStore(allowWork, true);
        return Error.init;
    }

    @Get("/shutdown")
    Error shutdown() nothrow @nogc
    {
        atomicStore(stop, true);
        return Error.init;
    }

    @Get("/conflict")
    Error conflict() nothrow @nogc
    {
        return Error(Status.conflict, "private fixture diagnostic", 23);
    }
}

/// Launch an explicit H1 or cleartext H2 fixture with an ephemeral caller-selected port.
int main(string[] arguments)
{
    if (arguments.length < 3)
        return 2;
    const tls = arguments[2] == "tls";
    if (arguments.length != (tls ? 5 : 3))
        return 2;
    const stress = arguments[2] == "stress";
    const port = to!ushort(arguments[1]);
    if (tls)
        enableTls();
    // h2 prior knowledge, and TLS whose ALPN offers h2.
    if (tls || arguments[2] == "h2")
        enableHttp2();
    const options = tls ? fixtureOptions(port, arguments[2], arguments[3], arguments[4]) : fixtureOptions(port,
            arguments[2], null, null);
    return serve(options, stress);
}

private int serve(ServerOptions options, bool stress)
{
    Server server;
    const started = server.start(options);
    if (started.code != Status.ok)
        return 3;
    scope (exit)
        server.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds);
    Fixture fixture;
    if (registerController(server, fixture).code != Status.ok)
        return 4;
    FixtureAdvice advice;
    if (registerAdvice(server, advice).code != Status.ok)
        return 4;
    WorkerFixture worker;
    if (registerController(server, worker).code != Status.ok)
        return 4;
    Context context;
    while (!atomicLoad(stop))
    {
        if (server.poll(context).code != Status.ok)
            return 5;
    }
    if (server.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds).code != Status.ok)
        return 6;
    if (stress && (atomicLoad(admitted) != 1_024 || atomicLoad(canceled) != 1_024))
        return 7;
    return 0;
}

private ServerOptions fixtureOptions(ushort port, string mode, string certificate, string key)
{
    ServerOptions options;
    options.port = port;
    options.http2PriorKnowledge = mode == "h2";
    if (mode == "tls")
    {
        options.tlsCertificateFile = certificate;
        options.tlsPrivateKeyFile = key;
    }
    options.maxConnectionsPerCore = mode == "stress" ? 1_026 : 32;
    options.maxStreamsPerConnection = 4;
    return options;
}
