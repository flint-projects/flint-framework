/// Fixed upload buffers with independently owned HTTP worker connections.
module flint.storage.parts;

import core.atomic : atomicLoad, atomicStore;
import core.lifetime : move;
import core.thread : Thread;
import core.time : msecs;
import flint.arena : Buffer, Error, RequestArena, Status;
import flint.conc : Background, CancelSource, Context, Deadline, startBackground;
import flint.http : HttpMethod;
import flint.storage.credentials : CredentialStore;
import flint.storage.endpoint : Endpoint;
import flint.storage.response : field, maximumEtag;
import flint.storage.types : StorageOptions;
import flint.storage.wire : Operation, Request, Transport, responseStatus;

@safe:

package(flint.storage) enum maximumUploadId = 2_048;
package(flint.storage) enum maximumParts = 10_000;
package(flint.storage) enum minimumNonfinal = 5 * 1024 * 1024;

package(flint.storage) struct PartReceipt
{
    char[maximumEtag] etag;
    size_t length;
}

package(flint.storage) enum PartPhase : ubyte
{
    vacant,
    filling,
    queued,
    completed
}

package(flint.storage) final class Part
{
    private shared PartPhase phase;
    private shared bool stopping;
    private shared bool retired;
    private bool launched;
    private Background thread;
    private Transport transport;
    private ubyte[] scratch;
    private Request request;
    private Context context;
    private CancelSource cancellation;
    private char[maximumUploadId] remoteId;
    private PartReceipt receipt;
    private Error result;
    ubyte[] bytes;
    ulong owner;
    size_t used;
    uint number;

    this(Endpoint endpoint, StorageOptions options, CredentialStore credentials)
    {
        transport = new Transport(endpoint, options, credentials, 1);
        bytes = new ubyte[options.partBytes];
        scratch = new ubyte[72 * 1024];
    }

    Error start(StorageOptions options)
    {
        const opened = transport.open(options);
        if (opened.code != Status.ok)
            return opened;
        const started = startBackground(&worker, thread);
        launched = started.code == Status.ok;
        if (!launched)
            transport.close();
        return started;
    }

    PartPhase state() scope nothrow @nogc
    {
        return atomicLoad(phase);
    }

    void acquire(ulong tag) scope nothrow @nogc
    {
        assert(state() == PartPhase.vacant);
        owner = tag;
        used = 0;
        number = 0;
        atomicStore(phase, PartPhase.filling);
    }

    Error queue(string bucket, string key, scope const(char)[] uploadId, uint index, ref Context parent) nothrow @nogc
    {
        assert(state() == PartPhase.filling && used != 0);
        if (uploadId.length == 0 || uploadId.length > remoteId.length || index == 0 || index > maximumParts)
            return Error(Status.invalidArgument, "invalid S3 multipart identity");
        auto cancel = CancelSource.create(parent, Deadline.none());
        if (!cancel.ok)
            return cancel.error;
        move(cancel.value, cancellation);
        context = cancellation.context();
        remoteId[0 .. uploadId.length] = uploadId;
        request = Request(HttpMethod.put, bucket, key, typeof(Request.download).init, null,
                Operation.part, index, remoteId[0 .. uploadId.length]);
        number = index;
        receipt.length = 0;
        atomicStore(phase, PartPhase.queued);
        return Error.init;
    }

    void cancel() scope nothrow @nogc
    {
        if (state() == PartPhase.queued)
            cancellation.cancel();
    }

    Error consume(out PartReceipt saved) scope nothrow @nogc
    {
        assert(state() == PartPhase.completed);
        saved = receipt;
        const outcome = result;
        cancellation.close();
        context = Context.init;
        request = Request.init;
        release();
        return Error(outcome.code, outcome.message, outcome.offset);
    }

    void release() scope nothrow @nogc
    {
        assert(state() != PartPhase.queued);
        owner = 0;
        used = 0;
        atomicStore(phase, PartPhase.vacant);
    }

    bool close() scope nothrow @nogc
    {
        atomicStore(stopping, true);
        if (launched && !atomicLoad(retired))
            return false;
        thread.join();
        return true;
    }

    private void worker() nothrow @nogc
    {
        while (!atomicLoad(stopping))
        {
            if (state() != PartPhase.queued)
            {
                Thread.sleep(4.msecs);
                continue;
            }
            result = transfer();
            atomicStore(phase, PartPhase.completed);
        }
        transport.close();
        atomicStore(retired, true);
    }

    private Error transfer() scope nothrow @nogc
    {
        auto arena = RequestArena(scratch);
        for (uint attempt; attempt < 3; ++attempt)
        {
            const available = context.check();
            if (available.code != Status.ok)
                return available;
            const reset = arena.reset();
            if (reset != Status.ok)
                return Error(reset, "S3 part response arena is still borrowed");
            const received = transport.send(request, bytes[0 .. used], arena, context);
            const mapped = received.ok ? responseStatus(received.value.status) : received.error;
            if (mapped.code == Status.ok)
                return capture(received.value.headers, arena);
            if (attempt == 2 || !transient(mapped.code))
                return mapped;
            Thread.sleep(10.msecs);
        }
        return Error(Status.unavailable, "S3 part did not complete");
    }

    private Error capture(Buffer headers, ref scope RequestArena arena) scope nothrow @nogc
    {
        const captured = field(headers, "etag", arena, (scope const(char)[] value) @safe nothrow @nogc {
            if (value.length <= receipt.etag.length)
            {
                receipt.etag[0 .. value.length] = value;
                receipt.length = value.length;
            }
        }, true);
        if (captured.code != Status.ok)
            return captured;
        return receipt.length != 0 ? Error.init : Error(Status.resourceExhausted, "S3 part ETag exceeds its limit");
    }
}

private bool transient(Status status) pure nothrow @nogc
{
    return status == Status.unavailable || status == Status.ioError;
}
