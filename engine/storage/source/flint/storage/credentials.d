/// Publish credential snapshots from a management thread.
module flint.storage.credentials;

import core.atomic : atomicLoad, atomicStore;
import core.thread.osthread : Thread;
import core.time : msecs;
import flint.arena : Error, Result, Status;
import flint.conc : Background, CancelSource, Context, Deadline, startManagedBackground;
import flint.storage.sigv4 : CredentialView, validCredentials;
import flint.storage.types : CredentialProvider, Credentials;

@safe:

// std.datetime is imported here rather than at module scope so that applications importing flint.storage do not
// instantiate its (and std.uni's) module-level templates.
package(flint.storage) long unixSeconds() nothrow @nogc
{
    import std.datetime.systime : Clock, stdTimeToUnixTime;

    return stdTimeToUnixTime(Clock.currStdTime);
}

package(flint.storage) struct CredentialSnapshot
{
    immutable(Credentials)* value;

    CredentialView view() return scope const nothrow @nogc
    {
        return CredentialView(value.accessKeyId, value.secretAccessKey, value.sessionToken,
                value.expiresAtUnixSeconds);
    }
}

package(flint.storage) final class CredentialStore
{
    private CredentialProvider fetch;
    private CancelSource stop;
    private Background worker;
    private Context lifetime;
    private shared immutable(Credentials)* current;
    private shared bool initial;
    private shared bool finished;

    this(CredentialProvider provider)
    {
        fetch = provider;
    }

    Error start()
    {
        auto source = CancelSource.create(Context.init, Deadline.none());
        if (!source.ok)
            return source.error;
        import core.lifetime : move;

        move(source.value, stop);
        lifetime = stop.context();
        const ready = startManagedBackground(&refreshLoop, worker);
        if (ready.code != Status.ok)
        {
            stop.close();
            return ready;
        }
        const deadline = Deadline.afterMillis(5_000).monotonicNanoseconds;
        while (!atomicLoad(initial))
        {
            if (Deadline.afterMillis(0).monotonicNanoseconds >= deadline)
            {
                stop.cancel();
                return Error(Status.timedOut, "initial storage credentials timed out");
            }
            Thread.sleep(2.msecs);
        }
        const credentials = take(unixSeconds());
        if (!credentials.ok)
            stop.cancel();
        return credentials.error;
    }

    Result!CredentialSnapshot take(long now) nothrow @nogc
    {
        auto value = atomicLoad(current);
        if (value is null || (value.expiresAtUnixSeconds && value.expiresAtUnixSeconds <= now))
            return Result!CredentialSnapshot(CredentialSnapshot.init, Error(Status.unavailable,
                    "no valid S3 credentials are available"));
        return Result!CredentialSnapshot(CredentialSnapshot(value));
    }

    Error close() nothrow @nogc
    {
        stop.cancel();
        if (!atomicLoad(finished))
            return Error(Status.unavailable, "credential worker is still retiring");
        worker.join();
        stop.close();
        return Error.init;
    }

    private void refreshLoop() nothrow
    {
        scope (exit)
        {
            atomicStore(current, cast(immutable(Credentials)*) null);
            atomicStore(finished, true);
        }
        long refill;
        while (!lifetime.cancelled)
        {
            const now = unixSeconds();
            if (now >= refill)
                refill = nextRefresh(now);
            Thread.sleep(50.msecs);
        }
    }

    private long nextRefresh(long now) nothrow
    {
        auto request = lifetime.withDeadline(Deadline.afterMillis(4_000));
        const candidate = fetch(request);
        const value = candidate.value;
        const view = CredentialView(value.accessKeyId, value.secretAccessKey, value.sessionToken,
                value.expiresAtUnixSeconds);
        long next = now + 1;
        if (candidate.ok && request.check().code == Status.ok && validCredentials(view, unixSeconds()))
        {
            auto published = new immutable(Credentials)(value.accessKeyId, value.secretAccessKey,
                    value.sessionToken, value.expiresAtUnixSeconds);
            atomicStore(current, published);
            const remaining = value.expiresAtUnixSeconds - now;
            if (value.expiresAtUnixSeconds == 0)
                next = long.max;
            else if (remaining > 120)
                next = value.expiresAtUnixSeconds - 60;
            else if (remaining > 2)
                next = now + remaining / 2;
        }
        atomicStore(initial, true);
        return next;
    }
}
