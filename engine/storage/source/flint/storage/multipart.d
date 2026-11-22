/// Multipart upload ownership and generation-based retirement.
module flint.storage.multipart;

import core.atomic : atomicLoad, atomicOp, cas;
import flint.arena : Buffer, Error, Arena = RequestArena, Result, Status;
import flint.conc : Context, Deadline;
import flint.conc.wait : waitUntil;
import flint.http : HttpMethod, HttpResponse;
import flint.storage.credentials : CredentialStore;
import flint.storage.encoding : Writer, safeField;
import flint.storage.endpoint : Endpoint, objectValid;
import flint.storage.parts : Part, PartPhase, PartReceipt, maximumParts, maximumUploadId;
import flint.storage.response : field, maximumEtag, readIdentity;
import flint.storage.types : CredentialProvider, ObjectInfo, StorageOptions;
import flint.storage.wire : Operation, Request, Transport, responseStatus;
import flint.storage.xml : Envelope, EnvelopeKind, copyXmlText, readEnvelope;
import std.array : uninitializedArray;

@safe:

private shared ulong threadSerial;
private ulong threadGeneration;
private enum maxXml = 1024 * 1024;
private alias Reply = Result!ObjectInfo;

/// A generation-checked multipart upload on its storage client owner thread.
struct Upload
{
    private Owner owner;
    private uint index;
    private ulong generation;

    private this(Owner owner, uint index, ulong generation) nothrow @nogc
    {
        this.owner = owner;
        this.index = index;
        this.generation = generation;
    }

    /// Copy as much input as buffers permit and wait cooperatively for space.
    Error write(scope const(ubyte)[] chunk, ref Context context) nothrow @nogc
    {
        Session session;
        const active = enter(session);
        if (active.code != Status.ok)
            return active;
        scope (exit)
            session.busy = false;
        if (session.cleaning)
            return cleanupRequired();
        if (!chunk.length)
            return context.check();
        const written = owner.write(session, chunk, context);
        return written.code == Status.ok ? written : owner.failed(session, written);
    }

    /// Finish pending parts, validate the completion envelope, and return the new object identity.
    Reply complete(ref scope Arena arena, ref Context context) nothrow @nogc
    {
        Session session;
        const active = enter(session);
        if (active.code != Status.ok)
            return Reply(ObjectInfo.init, active);
        scope (exit)
            session.busy = false;
        if (session.cleaning)
            return Reply(ObjectInfo.init, cleanupRequired());
        return owner.complete(session, arena, context);
    }

    /// Stop local transfers and remove the remote multipart upload.
    Error abort(ref Context context) nothrow @nogc
    {
        Session session;
        const active = enter(session);
        if (active.code == Status.notFound)
            return Error.init;
        if (active.code != Status.ok)
            return active;
        scope (exit)
            session.busy = false;
        return owner.abort(session, context);
    }

    /// Copy a pending remote cleanup identity into a caller-owned arena.
    Result!Buffer copyUploadId(ref scope Arena arena) nothrow @nogc
    {
        Session session;
        const active = enter(session);
        if (active.code != Status.ok)
            return Result!Buffer(Buffer.init, active);
        scope (exit)
            session.busy = false;
        if (!session.remoteLength)
            return Result!Buffer(Buffer.init, Error(Status.notFound, "S3 multipart identity is not available"));
        return arena.copyIn(cast(const(ubyte)[]) session.remote[0 .. session.remoteLength]);
    }

    private Error enter(out Session session) nothrow @nogc
    {
        if (owner is null)
            return ended();
        const owned = owner.claim();
        if (owned.code != Status.ok)
            return owned;
        session = owner.sessions[index];
        if (!session.active || session.generation != generation)
            return ended();
        if (session.busy)
            return Error(Status.conflict, "S3 upload already has an active operation");
        session.busy = true;
        return Error.init;
    }
}

private final class Session
{
    bool active, busy, cleaning;
    ulong generation;
    ulong size;
    string bucket, key, contentType;
    Part filling;
    uint submitted, inFlight;
    Error partFailure;
    PartReceipt[] receipts;
    char[maximumUploadId] remote;
    size_t remoteLength;
    ubyte[] scratch;
    char[] xml;

    this()
    {
        // Worst-case completion buffers are read only after being written (receipts up to
        // `submitted`, the document up to its encoded length), so leave their pages untouched
        // until an upload actually reaches them instead of zero-filling ~19 MiB per session.
        receipts = uninitializedArray!(PartReceipt[])(maximumParts);
        scratch = new ubyte[maxXml + 65_536];
        xml = uninitializedArray!(char[])(maximumParts * (6 * maximumEtag + 100) + 128);
    }

    void begin(ulong generation, string bucket, string key, string contentType) scope nothrow @nogc
    {
        active = true;
        cleaning = false;
        this.generation = generation;
        this.bucket = bucket;
        this.key = key;
        this.contentType = contentType;
        submitted = 0;
        inFlight = 0;
        partFailure = Error.init;
        size = 0;
        remoteLength = 0;
        filling = null;
    }

    void retire() scope nothrow @nogc
    {
        assert(inFlight == 0 && filling is null);
        active = false;
        bucket = null;
        key = null;
        contentType = null;
        remoteLength = 0;
    }
}

package(flint.storage) final class Owner
{
    private shared ulong owner;
    bool opened, closing;
    private ulong nextUpload;
    Transport transport;
    private CredentialStore credentials;
    private Part[] parts;
    private Session[] sessions;

    this(Endpoint endpoint, StorageOptions options, CredentialProvider provide)
    {
        credentials = new CredentialStore(provide);
        transport = new Transport(endpoint, options, credentials, 8);
        parts = new Part[options.concurrentParts];
        foreach (ref part; parts)
            part = new Part(endpoint, options, credentials);
        sessions = new Session[options.maxUploads];
        foreach (ref session; sessions)
            session = new Session;
    }

    Error start(StorageOptions options)
    {
        const authenticated = credentials.start();
        if (authenticated.code != Status.ok)
            return authenticated;
        const openedTransport = transport.open(options);
        if (openedTransport.code != Status.ok)
        {
            credentials.close();
            return openedTransport;
        }
        foreach (part; parts)
        {
            const started = part.start(options);
            if (started.code != Status.ok)
            {
                foreach (prior; parts)
                    prior.close();
                credentials.close();
                transport.close();
                return started;
            }
        }
        opened = true;
        return Error.init;
    }

    Error claim() scope nothrow @nogc
    {
        if (threadGeneration == 0)
            threadGeneration = atomicOp!"+="(threadSerial, 1UL);
        const observed = atomicLoad(owner);
        if (threadGeneration == 0 || (observed != threadGeneration && !cas(&owner, 0UL, threadGeneration)))
            return Error(Status.conflict, "S3 transport belongs to another owner thread");
        return Error.init;
    }

    Error ready() scope nothrow @nogc
    {
        const owned = claim();
        if (owned.code != Status.ok)
            return owned;
        return opened && !closing ? Error.init : Error(Status.conflict, "S3 storage client is closed");
    }

    Result!Upload begin(string bucket, string key, string contentType, ref Context context) nothrow @nogc
    {
        const owned = ready();
        if (owned.code != Status.ok)
            return Result!Upload(Upload.init, owned);
        const live = context.check();
        if (live.code != Status.ok)
            return Result!Upload(Upload.init, live);
        if (!objectValid(bucket, key) || !safeField(contentType, 256))
            return Result!Upload(Upload.init, Error(Status.invalidArgument, "invalid S3 object or content type"));
        foreach (index, session; sessions)
        {
            if (session.active)
                continue;
            if (nextUpload == ulong.max)
                break;
            session.begin(++nextUpload, bucket, key, contentType);
            return Result!Upload(Upload(this, cast(uint) index, session.generation));
        }
        return Result!Upload(Upload.init, Error(Status.resourceExhausted, "S3 upload capacity reached"));
    }

    Error close() scope nothrow @nogc
    {
        const owned = claim();
        if (owned.code != Status.ok)
            return owned;
        if (!opened)
            return Error.init;
        foreach (session; sessions)
            if (session.active)
                return Error(Status.conflict, "complete or abort active S3 uploads before closing");
        const closed = transport.close();
        if (closed.code != Status.ok)
            return closed;
        closing = true;
        const until = Deadline.afterMillis(500);
        for (;;)
        {
            bool finished = credentials.close().code == Status.ok;
            foreach (part; parts)
                finished &= part.close();
            if (finished)
            {
                opened = false;
                return Error.init;
            }
            if (Deadline.afterMillis(0).monotonicNanoseconds >= until.monotonicNanoseconds)
                return Error(Status.unavailable, "S3 management workers are still retiring");
            const waited = waitUntil(Deadline.afterMillis(5));
            if (waited.code != Status.ok)
                return waited;
        }
    }

    private Error write(Session session, scope const(ubyte)[] chunk, ref Context context) nothrow @nogc
    {
        if (session.remoteLength == 0)
        {
            const begun = activate(session, context);
            if (begun.code != Status.ok)
                return begun;
        }
        while (chunk.length != 0)
        {
            const available = buffer(session, context);
            if (available.code != Status.ok)
                return available;
            auto filling = session.filling;
            const remaining = filling.bytes.length - filling.used;
            const count = chunk.length < remaining ? chunk.length : remaining;
            filling.bytes[filling.used .. filling.used + count] = chunk[0 .. count];
            filling.used += count;
            session.size += count;
            chunk = chunk[count .. $];
            if (filling.used == filling.bytes.length)
            {
                const queued = submit(session, context);
                if (queued.code != Status.ok)
                    return queued;
            }
        }
        return Error.init;
    }

    private Error activate(Session session, ref Context context) nothrow @nogc
    {
        auto arena = Arena(session.scratch);
        Request request = Request(HttpMethod.post, session.bucket, session.key);
        request.contentType = session.contentType;
        request.operation = Operation.begin;
        const received = transport.send(request, null, arena, context);
        const accepted = received.ok ? responseStatus(received.value.status) : received.error;
        if (accepted.code != Status.ok)
            return accepted;
        Error parsed;
        const read = arena.read(received.value.body, (scope const(ubyte)[] payload) @safe nothrow @nogc {
            Envelope document;
            const raw = cast(const(char)[]) payload;
            parsed = readEnvelope(raw, document);
            if (parsed.code != Status.ok)
                return;
            if (document.kind != EnvelopeKind.initiated)
                parsed = Error(Status.ioError, "S3 refused to initiate multipart upload");
            else
                parsed = copyXmlText(raw, document.uploadId, session.remote[], session.remoteLength);
        });
        return read == Status.ok ? parsed : Error(Status.ioError, "S3 omitted the multipart initiation response");
    }

    private Error buffer(Session session, ref Context context) scope nothrow @nogc
    {
        for (;;)
        {
            const live = context.check();
            if (live.code != Status.ok)
                return live;
            const settled = collect(session);
            if (settled.code != Status.ok || session.filling !is null)
                return settled;
            if (session.submitted == maximumParts)
                return Error(Status.resourceExhausted, "S3 multipart part count exceeded");
            foreach (part; parts)
                if (part.state == PartPhase.vacant)
                {
                    part.acquire(session.generation);
                    session.filling = part;
                    return Error.init;
                }
            const resumed = waitForWorker(context);
            if (resumed.code != Status.ok)
                return resumed;
        }
    }

    private Error submit(Session session, ref Context context) scope nothrow @nogc
    {
        auto part = session.filling;
        assert(part !is null && part.used > 0);
        if (session.submitted == maximumParts)
            return Error(Status.resourceExhausted, "S3 multipart part count exceeded");
        const admitted = part.queue(session.bucket, session.key,
                session.remote[0 .. session.remoteLength], session.submitted + 1, context);
        if (admitted.code == Status.ok)
        {
            ++session.submitted;
            ++session.inFlight;
            session.filling = null;
        }
        return admitted;
    }

    private Error collect(Session session) scope nothrow @nogc
    {
        foreach (part; parts)
        {
            if (part.state != PartPhase.completed)
                continue;
            foreach (receiver; sessions)
            {
                if (!receiver.active || receiver.generation != part.owner)
                    continue;
                const number = part.number;
                const finished = part.consume(receiver.receipts[number - 1]);
                --receiver.inFlight;
                if (receiver.partFailure.code == Status.ok && finished.code != Status.ok)
                    receiver.partFailure = finished;
                break;
            }
        }
        return session.partFailure;
    }

    private Error waitParts(Session session, ref Context context, bool cancelling) scope nothrow @nogc
    {
        while (session.inFlight != 0)
        {
            const observed = collect(session);
            if (!cancelling && observed.code != Status.ok)
                return observed;
            if (session.inFlight != 0)
            {
                const waited = waitForWorker(context);
                if (waited.code != Status.ok)
                    return waited;
            }
        }
        return context.check();
    }

    private Reply complete(Session session, ref scope Arena caller, ref Context context) nothrow @nogc
    {
        const live = context.check();
        if (live.code != Status.ok)
            return Reply(ObjectInfo.init, failed(session, live));
        if (session.remoteLength == 0)
            return putEmpty(session, caller, context);
        if (session.filling !is null)
        {
            const last = submit(session, context);
            if (last.code != Status.ok)
                return Reply(ObjectInfo.init, failed(session, last));
        }
        const drained = waitParts(session, context, false);
        if (drained.code != Status.ok)
            return Reply(ObjectInfo.init, failed(session, drained));
        scope document = Writer(session.xml);
        const built = encodeReceipts(session.receipts[0 .. session.submitted], document);
        if (built.code != Status.ok)
            return Reply(ObjectInfo.init, failed(session, built));
        return commitParts(session, document.length, caller, context);
    }

    private Reply putEmpty(Session session, ref scope Arena caller, ref Context context) nothrow @nogc
    {
        Request request = Request(HttpMethod.put, session.bucket, session.key);
        request.contentType = session.contentType;
        auto arena = Arena(session.scratch);
        const received = transport.send(request, null, arena, context);
        const accepted = received.ok ? responseStatus(received.value.status) : received.error;
        if (accepted.code != Status.ok)
            return Reply(ObjectInfo.init, failed(session, accepted));
        auto metadata = readIdentity(received.value.headers, 0, arena);
        session.retire();
        if (!metadata.ok)
            return metadata;
        return copyIdentity(metadata.value, arena, caller);
    }

    // dfmt off
    private Reply commitParts(Session session, size_t xmlLength, ref scope Arena caller,
            ref Context context) nothrow @nogc
    {
        Request request = Request(HttpMethod.post, session.bucket, session.key);
        request.contentType = "application/xml";
        request.operation = Operation.finish;
        request.uploadId = session.remote[0 .. session.remoteLength];
        auto arena = Arena(session.scratch);
        const received = transport.send(request, cast(const(ubyte)[]) session.xml[0 .. xmlLength], arena, context);
        const accepted = received.ok ? responseStatus(received.value.status) : received.error;
        if (accepted.code != Status.ok)
            return Reply(ObjectInfo.init, failed(session, accepted));

        char[maximumEtag] etag;
        size_t used;
        const parsed = completion(received.value, arena, etag[], used);
        if (parsed.code != Status.ok)
            return Reply(ObjectInfo.init, failed(session, parsed));
        const size = session.size;
        session.retire();
        return publishCompletion(received.value.headers, size, etag[0 .. used], arena, caller);
    }
    // dfmt on

    private Error failed(Session session, Error primary) nothrow @nogc
    {
        auto cleanup = Context.init.withDeadline(Deadline.afterMillis(2_000));
        const released = abort(session, cleanup);
        return released.code == Status.ok ? primary : cleanupRequired();
    }

    private Error abort(Session session, ref Context context) nothrow @nogc
    {
        session.cleaning = true;
        if (session.filling !is null)
        {
            session.filling.release();
            session.filling = null;
        }
        foreach (part; parts)
            if (part.owner == session.generation)
                part.cancel();
        if (session.inFlight != 0)
        {
            const drained = waitParts(session, context, true);
            if (drained.code != Status.ok)
                return drained;
        }
        if (session.remoteLength == 0)
        {
            session.retire();
            return Error.init;
        }
        auto arena = Arena(session.scratch);
        Request request = Request(HttpMethod.delete_, session.bucket, session.key);
        request.operation = Operation.abortUpload;
        request.uploadId = session.remote[0 .. session.remoteLength];
        const received = transport.send(request, null, arena, context);
        const removed = received.ok ? responseStatus(received.value.status) : received.error;
        if (removed.code != Status.ok && removed.code != Status.notFound)
            return cleanupRequired();
        session.retire();
        return Error.init;
    }
}

private Error waitForWorker(ref Context context) nothrow @nogc
{
    const limit = context.deadline().monotonicNanoseconds;
    const poll = Deadline.afterMillis(2).monotonicNanoseconds;
    const result = waitUntil(Deadline(limit < poll ? limit : poll));
    return result.code == Status.ok ? context.check() : result;
}

private Error encodeReceipts(scope const(PartReceipt)[] parts, ref scope Writer xml) pure nothrow @nogc
{
    if (parts.length == 0 || parts.length > maximumParts)
        return Error(Status.invalidArgument, "invalid S3 multipart part list");
    xml.append("<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
    foreach (index, ref receipt; parts)
    {
        if (!receipt.length || receipt.length > maximumEtag)
            return Error(Status.invalidArgument, "missing S3 multipart part receipt");
        xml.append("<Part><PartNumber>");
        xml.decimal(index + 1);
        xml.append("</PartNumber><ETag>");
        escapeXml(xml, receipt.etag[0 .. receipt.length]);
        xml.append("</ETag></Part>");
    }
    xml.append("</CompleteMultipartUpload>");
    return xml.valid ? Error.init : Error(Status.resourceExhausted, "S3 multipart document exceeds capacity");
}

private void escapeXml(ref scope Writer target, scope const(char)[] value) pure nothrow @nogc
{
    foreach (character; value)
    {
        switch (character)
        {
        case '&':
            target.append("&amp;");
            break;
        case '<':
            target.append("&lt;");
            break;
        case '>':
            target.append("&gt;");
            break;
        case '"':
            target.append("&quot;");
            break;
        case '\'':
            target.append("&apos;");
            break;
        default:
            target.put(character);
            break;
        }
    }
}

// dfmt off
private Error completion(scope const ref HttpResponse response, ref scope Arena arena,
        scope char[] etag, out size_t used) nothrow @nogc
{
    Error outcome;
    const read = arena.read(response.body, (scope const(ubyte)[] payload) @safe nothrow @nogc {
        Envelope envelope;
        const raw = cast(const(char)[]) payload;
        outcome = readEnvelope(raw, envelope);
        if (outcome.code != Status.ok)
            return;
        if (envelope.kind != EnvelopeKind.completed)
            outcome = Error(Status.ioError, "S3 reported a multipart completion failure");
        else
            outcome = copyXmlText(raw, envelope.etag, etag, used);
    });
    return read == Status.ok ? outcome : Error(Status.ioError, "S3 omitted the multipart completion document");
}
// dfmt on

private Reply publishCompletion(Buffer headers, ulong size, scope const(char)[] etag,
        ref scope Arena source, ref scope Arena caller) nothrow @nogc
{
    auto name = caller.copyIn(cast(const(ubyte)[]) etag);
    if (!name.ok)
        return Reply(ObjectInfo.init, name.error);
    Result!Buffer revision;
    const received = field(headers, "x-amz-version-id", source, (scope const(char)[] value) {
        if (value.length > 1_024)
            revision.error = Error(Status.resourceExhausted, "S3 version ID exceeds its limit");
        else
            revision = caller.copyIn(cast(const(ubyte)[]) value);
    });
    if (received.code != Status.ok || !revision.ok)
        return Reply(ObjectInfo.init, received.code != Status.ok ? received : revision.error);
    return Reply(ObjectInfo(size, name.value, revision.value));
}

private Reply copyIdentity(ObjectInfo object, ref scope Arena source, ref scope Arena caller) nothrow @nogc
{
    Result!Buffer name;
    Result!Buffer revision;
    const copied = source.read(object.etag, (scope const(ubyte)[] bytes) {
        name = caller.copyIn(bytes);
    });
    if (copied != Status.ok || !name.ok)
        return Reply(ObjectInfo.init, copied != Status.ok ? Error(copied) : name.error);
    if (object.versionId != Buffer.init)
    {
        const read = source.read(object.versionId, (scope const(ubyte)[] bytes) {
            revision = caller.copyIn(bytes);
        });
        if (read != Status.ok || !revision.ok)
            return Reply(ObjectInfo.init, read != Status.ok ? Error(read) : revision.error);
    }
    return Reply(ObjectInfo(object.size, name.value, revision.value));
}

private Error ended() pure nothrow @nogc
{
    return Error(Status.notFound, "S3 multipart upload generation has retired");
}

private Error cleanupRequired() pure nothrow @nogc
{
    return Error(Status.unavailable, "S3 multipart cleanup is pending; retry abort with a live context");
}
