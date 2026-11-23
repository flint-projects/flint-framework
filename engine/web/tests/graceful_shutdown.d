/// Graceful shutdown over real sockets (ADR-028 section 10): the drain closes the listener, closes idle
/// keep-alive connections, lets an admitted request finish, and cancels it once the grace period expires.
/// The tests that start threads are `@system`, as druntime's `Thread` is.
module flint.engine.web.graceful_shutdown_behavior;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread.osthread : Thread;
import core.time : MonoTime, dur;
import flint.arena : Error, Result, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.engine.reactor : Reactor;
import flint.engine.web.internal.controllers : runApplication, serve;
import flint.engine.web.runtime : Server;
import flint.engine.web.types : Get, Method, QueryParam, Request, RequestContext, Response,
    RestController, ServerOptions, ShutdownExit, ShutdownMode;
import std.socket : InternetAddress, Socket, SocketOSException, SocketOption, SocketOptionLevel, TcpSocket;

@safe:

private shared uint entered;
private shared uint cancelled;
private shared bool release;

private void reset()
{
    atomicStore(entered, 0U);
    atomicStore(cancelled, 0U);
    atomicStore(release, false);
}

/// Wait on the owner fiber until the test releases the request or the server cancels it.
private Error hold(ref scope RequestContext context) nothrow @nogc
{
    atomicOp!"+="(entered, 1U);
    auto loop = Reactor.current();
    while (!atomicLoad(release))
    {
        cast(void) loop.yieldUntil(Deadline.afterMillis(5), context.cancellation);
        if (context.cancellation.cancelled())
        {
            atomicOp!"+="(cancelled, 1U);
            return context.cancellation.check();
        }
    }
    return Error.init;
}

private final class Routes
{
    Result!Response slow(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        const held = hold(context);
        if (held.code != Status.ok)
            return Result!Response(Response.init, held);
        return text(context, "done");
    }

    Result!Response fast(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        return text(context, "ok");
    }
}

private Result!Response text(ref scope RequestContext context, string value) nothrow @nogc
{
    auto copied = context.arena.copyIn(cast(const(ubyte)[]) value);
    if (!copied.ok())
        return Result!Response(Response.init, copied.error);
    return Result!Response(Response(200, "text/plain", copied.value));
}

@RestController("")
private struct Application
{
    @Get("/slow") Result!Response slow(ref scope RequestContext context) nothrow @nogc
    {
        const held = hold(context);
        if (held.code != Status.ok)
            return Result!Response(Response.init, held);
        return text(context, "done");
    }
}

private ServerOptions options()
{
    ServerOptions options;
    options.port = 0;
    options.cores = 2;
    options.maxConnectionsPerCore = 16;
    options.http2 = false;
    return options;
}

private ushort freePort()
{
    auto probe = new TcpSocket;
    scope (exit)
        probe.close();
    probe.bind(new InternetAddress("127.0.0.1", 0));
    return (cast(InternetAddress) probe.localAddress).port;
}

private Socket connect(ushort port)
{
    auto socket = new TcpSocket(new InternetAddress("127.0.0.1", port));
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(5_000));
    return socket;
}

private bool refused(ushort port)
{
    try
        connect(port).close();
    catch (SocketOSException)
        return true;
    return false;
}

private bool interrupted() @trusted
{
    import core.stdc.errno : EINTR, errno;

    return errno == EINTR;
}

/// Everything the peer sends until it closes, retrying a GC signal's interruption.
private string readAll(Socket socket)
{
    char[] answer;
    char[1024] buffer;
    for (;;)
    {
        const count = socket.receive(buffer[]);
        if (count == Socket.ERROR && interrupted())
            continue;
        if (count <= 0)
            return answer.idup;
        answer ~= buffer[0 .. count];
    }
}

private string exchange(Socket socket, string target)
{
    const request = "GET " ~ target ~ " HTTP/1.1\r\nHost: localhost\r\n\r\n";
    assert(socket.send(request) == request.length);
    char[1024] buffer;
    char[] answer;
    // A keep-alive response: read until its two-byte body has arrived.
    while (answer.length < 4 || answer[$ - 2 .. $] != "ok")
    {
        const count = socket.receive(buffer[]);
        if (count == Socket.ERROR && interrupted())
            continue;
        assert(count > 0, "the server closed a keep-alive connection");
        answer ~= buffer[0 .. count];
    }
    return answer.idup;
}

private void waitFor(scope bool delegate() @safe condition, string what)
{
    const end = MonoTime.currTime + dur!"msecs"(5_000);
    while (!condition())
    {
        assert(MonoTime.currTime < end, what);
        Thread.sleep(dur!"msecs"(1));
    }
}

private struct Running
{
    Server server;
    ushort port;

    void open()
    {
        assert(server.start(options()).code == Status.ok);
        auto routes = new Routes;
        assert(server.route(Method.get, "/slow", &routes.slow).code == Status.ok);
        assert(server.route(Method.get, "/fast", &routes.fast).code == Status.ok);
        port = server.listenPort();
        Context context;
        assert(server.poll(context).code == Status.ok);
    }
}

/// Run `drain` on another thread, as the signal-watching main thread would.
private Thread drainLater(Server* server, long graceMillis, CancelSource* force, Error* result) @system
{
    return new Thread({
        *result = server.drain(Deadline.afterMillis(graceMillis).monotonicNanoseconds, force is null
            ? Context.init : force.context());
    }).start();
}

@("a graceful drain refuses new connections, closes idle keep-alive ones and lets an admitted request finish")
@system unittest
{
    reset();
    auto running = new Running;
    running.open();
    auto idle = connect(running.port);
    scope (exit)
        idle.close();
    assert(exchange(idle, "/fast").length != 0);
    auto busy = connect(running.port);
    scope (exit)
        busy.close();
    assert(busy.send("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n") > 0);
    waitFor(() => atomicLoad(entered) == 1, "the slow request never started");

    auto drained = new Error(Status.unavailable);
    auto drainer = drainLater(&running.server, 5_000, null, drained);
    waitFor(() => refused(running.port), "the listener stayed open while draining");
    assert(readAll(idle) == "", "an idle keep-alive connection was not closed");

    atomicStore(release, true);
    const answer = readAll(busy);
    assert(answer.length > 12 && answer[0 .. 12] == "HTTP/1.1 200", answer);
    assert(answer[$ - 4 .. $] == "done" && atomicLoad(cancelled) == 0, answer);
    drainer.join();
    assert(drained.code == Status.ok, drained.message);
    assert(running.server.stopped());
}

@("an admitted request that outlives the grace period is cancelled and the drain reports timedOut")
@system unittest
{
    reset();
    auto running = new Running;
    running.open();
    auto busy = connect(running.port);
    scope (exit)
        busy.close();
    assert(busy.send("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n") > 0);
    waitFor(() => atomicLoad(entered) == 1, "the slow request never started");

    const began = MonoTime.currTime;
    const drained = running.server.drain(Deadline.afterMillis(200).monotonicNanoseconds);
    const took = MonoTime.currTime - began;
    assert(drained.code == Status.timedOut, drained.message);
    assert(took >= dur!"msecs"(200) && took < dur!"msecs"(2_500));
    assert(atomicLoad(cancelled) == 1 && running.server.stopped());
    assert(readAll(busy) == "", "a cancelled request still answered");
}

@("cancelling the forced context cuts a graceful drain short")
@system unittest
{
    reset();
    auto running = new Running;
    running.open();
    auto busy = connect(running.port);
    scope (exit)
        busy.close();
    assert(busy.send("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n") > 0);
    waitFor(() => atomicLoad(entered) == 1, "the slow request never started");

    auto force = CancelSource.create(Context.init, Deadline.none());
    assert(force.ok());
    auto drained = new Error(Status.unavailable);
    auto drainer = drainLater(&running.server, 30_000, &force.value, drained);
    waitFor(() => refused(running.port), "the listener stayed open while draining");
    force.value.cancel();
    drainer.join();
    assert(drained.code == Status.cancelled, drained.message);
    assert(atomicLoad(cancelled) == 1 && running.server.stopped());
    force.value.close();
}

@("runApplication drains on its shutdown context and exits 0, 124 after the grace period, or 130 when forced")
@system unittest
{
    foreach (expected; [0, ShutdownExit.graceExpired, ShutdownExit.forced])
    {
        reset();
        auto shutdown = CancelSource.create(Context.init, Deadline.none());
        auto forced = CancelSource.create(Context.init, Deadline.none());
        assert(shutdown.ok() && forced.ok());
        auto settings = options();
        settings.port = freePort();
        settings.shutdownTimeoutNanos = expected == ShutdownExit.graceExpired ? 200_000_000L : 30_000_000_000L;

        Application application;
        shared int code = -1;
        auto stopping = &shutdown.value;
        auto forcing = &forced.value;
        auto runner = new Thread({
            atomicStore(code, runApplication(application, settings, null, stopping.context(), forcing.context()));
        });
        runner.start();
        waitFor(() => !refused(settings.port), "the application never listened");
        auto busy = connect(settings.port);
        scope (exit)
            busy.close();
        assert(busy.send("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n") > 0);
        waitFor(() => atomicLoad(entered) == 1, "the slow request never started");

        shutdown.value.cancel();
        waitFor(() => refused(settings.port), "the listener stayed open while draining");
        if (expected == 0)
            atomicStore(release, true);
        else if (expected == ShutdownExit.forced)
            forced.value.cancel();
        runner.join();
        assert(atomicLoad(code) == expected);
        assert(atomicLoad(cancelled) == (expected == 0 ? 0 : 1));
        shutdown.value.close();
        forced.value.close();
    }
}

@("ShutdownMode.immediate cancels the admitted request instead of draining")
@system unittest
{
    reset();
    auto shutdown = CancelSource.create(Context.init, Deadline.none());
    assert(shutdown.ok());
    auto settings = options();
    settings.port = freePort();
    settings.shutdown = ShutdownMode.immediate;

    Application application;
    Error served = Error(Status.unavailable);
    auto stopping = &shutdown.value;
    auto runner = new Thread({ served = serve(application, settings, null, stopping.context()); });
    runner.start();
    waitFor(() => !refused(settings.port), "the application never listened");
    auto busy = connect(settings.port);
    scope (exit)
        busy.close();
    assert(busy.send("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n") > 0);
    waitFor(() => atomicLoad(entered) == 1, "the slow request never started");
    shutdown.value.cancel();
    runner.join();
    assert(served.code == Status.cancelled, served.message);
    assert(atomicLoad(cancelled) == 1);
    shutdown.value.close();
}
