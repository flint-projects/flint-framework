/// One ordered RESP3 connection with a dedicated Reactor owner.
module flint.cache.remote;

import core.atomic : atomicLoad, atomicStore;
import core.lifetime : move;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.cache.ffi.hiredis : Bridge, Kind;
import flint.cache.types : Bytes, CacheOptions;
import flint.conc : Background, Context, Deadline, startManagedBackground;
import flint.reactor : Backend, NativeInterest, NativeReadyFn, Reactor, ReactorOptions;

@safe:

package(flint.cache) struct RemoteStore
{
    private Driver control;

    static Result!RemoteStore open(CacheOptions options)
    {
        auto driver = new Driver;
        const initialized = driver.native.open(options);
        if (initialized.code != Status.ok)
            return Result!RemoteStore(RemoteStore.init, initialized);
        scope (failure)
            driver.native.destroy();

        ReactorOptions reactor;
        reactor.cores = 1;
        reactor.backend = Backend.epoll;
        reactor.fiberPoolSize = 1;
        reactor.maxConnectionsPerCore = 2;
        reactor.maxPendingIoPerCore = 2;
        reactor.ioBufferBytes = 64;
        reactor.mailboxCapacity = 2;
        reactor.maxTimersPerCore = 2;
        reactor.maxNativeWatchesPerCore = 2;

        auto loop = Reactor.create(reactor);
        if (!loop.ok())
        {
            driver.native.destroy();
            return Result!RemoteStore(RemoteStore.init, loop.error);
        }
        driver.loop = move(loop.value);
        driver.readySocket = &driver.socketReady;
        driver.readyMailbox = &driver.mailboxReady;
        const posted = driver.loop.postStartup(0, &driver.owner);
        if (posted.code != Status.ok)
        {
            driver.native.destroy();
            return Result!RemoteStore(RemoteStore.init, posted);
        }
        // The worker uses only its managed control object and the native state it owns.
        const started = startManagedBackground(&driver.run, driver.worker);
        if (started.code != Status.ok)
        {
            driver.native.destroy();
            return Result!RemoteStore(RemoteStore.init, started);
        }
        return Result!RemoteStore(RemoteStore(driver));
    }

    Error ready(ref Context context) nothrow @nogc
    {
        if (control is null)
            return closed();
        while (true)
        {
            const cancelled = context.check();
            if (cancelled.code != Status.ok)
                return cancelled;
            const status = control.native.ready();
            if (!status.pending)
                return status.error;
            const waited = control.pause();
            if (waited.code != Status.ok)
                return waited;
        }
    }

    Result!Buffer get(scope Bytes key, ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        const usable = ready(context);
        if (usable.code != Status.ok)
            return Result!Buffer(Buffer.init, usable);
        const ticket = control.native.issue(Kind.get, key, null, 0);
        return ticket.ok() ? control.collect(ticket.value, arena, true,
                context) : Result!Buffer(Buffer.init, ticket.error);
    }

    Result!ulong putCommand(scope Bytes key, scope Bytes bytes, long ttlNanos) nothrow @nogc
    {
        return control is null ? Result!ulong(0, closed()) : control.native.issue(Kind.set, key, bytes, ttlNanos);
    }

    Result!ulong evictCommand(scope Bytes key) nothrow @nogc
    {
        return control is null ? Result!ulong(0, closed()) : control.native.issue(Kind.evict, key, null, 0);
    }

    Result!ulong clearCommand() nothrow @nogc
    {
        return control is null ? Result!ulong(0, closed()) : control.native.issue(Kind.clear, null, null, 0);
    }

    Error complete(ulong ticket, ref Context context) nothrow @nogc
    {
        if (control is null)
            return closed();
        RequestArena unused;
        return control.collect(ticket, unused, false, context).error;
    }

    Error close() nothrow @nogc
    {
        if (control is null)
            return Error.init;
        control.native.requestStop();
        while (!atomicLoad(control.terminated))
        {
            const waited = control.pause();
            if (waited.code != Status.ok)
                return waited;
        }
        control.worker.join();
        return Error.init;
    }

    version (unittest) ulong testPushes() nothrow @nogc
    {
        return control is null ? 0 : control.native.pushes();
    }
}

private Error closed() pure nothrow @nogc
{
    return Error(Status.unavailable, "Redis cache is not open");
}

private final class Driver
{
    Bridge native;
    Reactor loop;
    Background worker;
    shared bool terminated;

    private Error outcome;
    private int socketFd = -1;
    private int mailboxFd = -1;
    private NativeInterest socketInterest;
    NativeReadyFn readySocket;
    NativeReadyFn readyMailbox;

    ~this() nothrow @nogc
    {
        native.destroy();
    }

    void run() nothrow
    {
        scope (exit)
            atomicStore(terminated, true);
        auto runner = move(loop);
        const resolved = native.resolve();
        if (resolved.code != Status.ok)
        {
            native.finish(resolved.code);
            return;
        }
        try
        {
            const ended = runner.run();
            native.finish(ended.code);
        }
        catch (Exception)
        {
            native.finish(Status.ioError);
        }
    }

    void owner() nothrow @nogc
    {
        auto reactor = Reactor.current();
        scope (exit)
        {
            if (socketInterest != NativeInterest.none)
                reactor.unwatchNative(socketFd);
            if (mailboxFd >= 0)
                reactor.unwatchNative(mailboxFd);
            native.finish(outcome.code);
            reactor.stop();
        }
        outcome = native.attach();
        if (outcome.code != Status.ok)
            return;
        const descriptors = native.watch();
        if (!descriptors.ok())
        {
            outcome = descriptors.error;
            return;
        }
        socketFd = descriptors.value.socketFd;
        outcome = reactor.watchNative(descriptors.value.wakeFd, NativeInterest.read, readyMailbox);
        if (outcome.code != Status.ok)
            return;
        mailboxFd = descriptors.value.wakeFd;
        refresh();

        while (outcome.code == Status.ok)
        {
            const waited = reactor.yieldUntil(Deadline.afterMillis(2));
            if (outcome.code != Status.ok)
                break;
            if (waited.code != Status.ok)
            {
                outcome = waited;
                break;
            }
            update(native.tick());
        }
    }

    private void refresh() nothrow @nogc
    {
        const current = native.watch();
        if (!current.ok())
        {
            outcome = current.error;
            return;
        }
        const interest = cast(NativeInterest) current.value.interest;
        if (interest == socketInterest)
            return;
        auto reactor = Reactor.current();
        outcome = interest == NativeInterest.none
            ? reactor.unwatchNative(socketFd) : reactor.watchNative(socketFd, interest, readySocket);
        if (outcome.code == Status.ok)
            socketInterest = interest;
    }

    private void update(Error status) nothrow @nogc
    {
        if (outcome.code != Status.ok)
            return;
        outcome = status;
        if (outcome.code == Status.ok)
            refresh();
    }

    void socketReady(int, NativeInterest events) nothrow @nogc
    {
        if (outcome.code != Status.ok)
            return;
        if (events & (NativeInterest.read | NativeInterest.error))
            update(native.readable());
        if (outcome.code == Status.ok && (events & (NativeInterest.write | NativeInterest.error)))
            update(native.writable());
    }

    void mailboxReady(int, NativeInterest) nothrow @nogc
    {
        if (outcome.code == Status.ok)
            update(native.wake());
    }

    Error pause() nothrow @nogc
    {
        auto reactor = Reactor.current();
        if (reactor.currentCore() == uint.max)
            return native.waitBriefly();
        if (!reactor.currentTask().ok())
            return Error(Status.conflict, "Redis operation must wait from a Reactor fiber");
        return reactor.yieldUntil(Deadline.afterMillis(1));
    }

    Result!Buffer collect(ulong ticket, ref scope RequestArena arena, bool copy, ref Context context) nothrow @nogc
    {
        while (true)
        {
            const cancelled = context.check();
            if (cancelled.code != Status.ok)
            {
                native.abandon(ticket);
                return Result!Buffer(Buffer.init, cancelled);
            }
            const outcome = native.take(ticket, arena, copy);
            if (!outcome.pending)
                return outcome.output;
            const paused = pause();
            if (paused.code != Status.ok)
            {
                native.abandon(ticket);
                return Result!Buffer(Buffer.init, paused);
            }
        }
    }
}
