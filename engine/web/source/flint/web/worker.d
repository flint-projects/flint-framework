/// Bounded offload for explicitly selected full-D controllers.
module flint.web.worker;

import core.atomic : atomicLoad, atomicStore, cas;
import core.lifetime : move;
import core.thread.osthread : Thread;
import core.time : dur;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Channel, Context, Deadline, QueueKind;
import flint.reactor : Reactor;
import flint.web.sys.ownership : joinDriver, launchDriver;
import flint.web.types : Capture, HeaderRecord, Method, Request, RequestContext, RequestMetadata,
    Response, maximumCaptures, maximumFields;
import flint.web.worker_packet : WorkerMedia, WorkerReply, WorkerRequest, workerMediaTypes, workerPacketBytes;

@safe:
package(flint.web):

private enum queuedPackets = 16;
/// The request arena of a worker-thread handler: its decoded request, its own allocations and its encoded
/// response. Reused for every request, since the worker runs one at a time.
private enum workerArenaBytes = 8 << 20;

/// Startup-owned worker lifetime, observed by the server before releasing its controller bindings.
struct WorkerLifecycle
{
    void delegate() @safe nothrow @nogc stop;
    Error delegate() @safe nothrow join;
}

/// Explicit static full-D hook. Only the worker uses the supplied owned controller.
alias FullWorkFn(C) = Result!Response function(ref C, ref scope Request, ref scope RequestContext) @safe;

private enum TicketState : ubyte
{
    vacant,
    reserved,
    queued,
    running,
    complete,
    abandoned
}

private struct Job(C)
{
    shared TicketState state;
    FullWorkFn!C action;
    Context cancellation;
    WorkerRequest request;
    WorkerReply reply;
}

/// Owns one dedicated worker and fixed packet slots. Keys crossing the queue are integers.
final class ControllerWorker(C)
{
    private C instance;
    private Job!C[] packets;
    private HeaderRecord[maximumFields] headers;
    private Channel!(uint, QueueKind.mpsc) pending;
    private shared bool stopping;
    private shared bool stopped = true;
    private Thread thread;
    private ubyte[] arenaStorage;

    this(C startup)
    {
        instance = startup;
        packets = new Job!C[queuedPackets];
        arenaStorage = new ubyte[workerArenaBytes];
    }

    Error start()
    {
        auto mailbox = Channel!(uint, QueueKind.mpsc).create(queuedPackets);
        if (!mailbox.ok())
            return mailbox.error;
        move(mailbox.value, pending);
        try
        {
            atomicStore(stopped, false);
            thread = launchDriver(&run);
        }
        catch (Exception)
        {
            atomicStore(stopped, true);
            return Error(Status.unavailable, "unable to start HTTP controller worker");
        }
        return Error.init;
    }

    WorkerLifecycle lifecycle() nothrow @nogc
    {
        return WorkerLifecycle(&requestStop, &join);
    }

    private void requestStop() nothrow @nogc
    {
        atomicStore(stopping, true);
        if (!atomicLoad(stopped))
            pending.close();
    }

    private Error join() nothrow
    {
        const result = joinDriver(thread);
        if (result.code == Status.ok)
            thread = null;
        return result;
    }

    nothrow @nogc
    {
        Result!Response submit(FullWorkFn!C action, ref scope Request request, ref scope RequestContext context)
        {
            if (atomicLoad(stopping) || context.cancellation.cancelled())
                return failure(Status.cancelled);
            foreach (index, ref job; packets)
            {
                if (!cas(&job.state, TicketState.vacant, TicketState.reserved))
                    continue;
                if (!request.makePacket(context, job.request))
                {
                    atomicStore(job.state, TicketState.vacant);
                    return Result!Response(Response(413, null, Buffer.init));
                }
                job.action = action;
                job.cancellation = context.cancellation;
                atomicStore(job.state, TicketState.queued);
                const admitted = pending.trySend(cast(uint) index);
                if (admitted != Status.ok)
                {
                    job.cancellation = Context.init;
                    atomicStore(job.state, TicketState.vacant);
                    return failure(admitted);
                }
                return wait(job, context);
            }
            return failure(Status.resourceExhausted);
        }
    }

    private Result!Response wait(ref Job!C job, ref scope RequestContext context) nothrow @nogc
    {
        auto owner = Reactor.current();
        bool cancelled;
        for (;;)
        {
            const current = atomicLoad(job.state);
            if (current == TicketState.complete)
            {
                scope (exit)
                    atomicStore(job.state, TicketState.vacant);
                if (cancelled || context.cancellation.cancelled())
                    return failure(Status.cancelled);
                return copyResponse(job.reply, context.arena);
            }
            if (cancelled || context.cancellation.cancelled())
            {
                if (cas(&job.state, current, TicketState.abandoned))
                    return failure(Status.cancelled);
                continue;
            }
            const result = owner.yieldUntil(Deadline.afterMillis(1));
            cancelled = result.code != Status.ok;
        }
    }

    private void run() nothrow
    {
        scope (exit)
            atomicStore(stopped, true);
        for (;;)
        {
            const next = pending.tryReceive();
            if (next.ok())
            {
                process(packets[next.value]);
                continue;
            }
            if (atomicLoad(stopping))
                return;
            Thread.sleep(dur!"msecs"(1));
        }
    }

    private void process(ref Job!C job) nothrow
    {
        if (!cas(&job.state, TicketState.queued, TicketState.running))
        {
            job.cancellation = Context.init;
            atomicStore(job.state, TicketState.vacant);
            return;
        }
        if (atomicLoad(stopping) || job.cancellation.cancelled())
            job.reply.error = Status.cancelled;
        else
        {
            try
                execute(job);
            catch (Exception)
                job.reply.error = Status.unavailable;
        }
        job.cancellation = Context.init;
        if (!cas(&job.state, TicketState.running, TicketState.complete))
            atomicStore(job.state, TicketState.vacant);
    }

    private void execute(ref Job!C job)
    {
        scope context = RequestContext(RequestArena(arenaStorage));
        context.requestId = job.request.identity;
        context.cancellation = job.cancellation;
        RequestMetadata metadata;
        metadata.headers = headers[];
        if (!unpack(&job.request, &metadata, context.arena))
        {
            job.reply.error = Status.outOfMemory;
            return;
        }
        scope request = Request.fromMetadata(&metadata);
        Capture[maximumCaptures] captures;
        foreach (index, ref entry; job.request.captures[0 .. job.request.captureCount])
        {
            const name = cast(const(char)[]) job.request.view(entry.name);
            captures[index] = Capture(name.idup, entry.first, entry.last);
        }
        request.setCaptures(captures[0 .. job.request.captureCount]);
        const result = job.action(instance, request, context);
        if (!result.ok())
        {
            job.reply.error = result.error.code;
            return;
        }
        encodeResponse(result.value, context.arena, job.reply);
    }
}

private bool unpack(scope const WorkerRequest* packet, scope RequestMetadata* metadata, ref scope RequestArena arena)
{
    metadata.method = cast(Method) packet.method;
    metadata.generation = 1;
    const path = arena.copyIn(packet.view(packet.path));
    const query = arena.copyIn(packet.view(packet.query));
    const payload = arena.copyIn(packet.view(packet.body));
    if (!path.ok() || !query.ok() || !payload.ok())
        return false;
    metadata.path = path.value;
    metadata.query = query.value;
    metadata.body = payload.value;

    metadata.names = new ubyte[packet.used];
    uint position;
    foreach (ref field; packet.headers[0 .. packet.fields])
    {
        scope const name = packet.view(field.name);
        const value = arena.copyIn(packet.view(field.value));
        if (!value.ok())
            return false;
        const end = position + cast(uint) name.length;
        metadata.names[position .. end] = name;
        ref destination = metadata.headers[metadata.fieldCount++];
        destination.start = position;
        destination.end = end;
        destination.value = value.value;
        position = end;
    }
    metadata.valid = true;
    return true;
}

private void encodeResponse(Response response, ref scope RequestArena arena, ref WorkerReply reply) nothrow
{
    reply.status = response.status;
    reply.length = 0;
    reply.large = null;
    reply.contentType = null;
    reply.media = WorkerMedia.none;
    bool listed;
    foreach (index, known; workerMediaTypes)
    {
        if (known == response.contentType)
        {
            reply.media = cast(WorkerMedia) index;
            listed = true;
            break;
        }
    }
    if (!listed)
        reply.contentType = response.contentType;
    reply.error = Status.ok;
    if (response.body != Buffer.init)
        reply.error = encodeBody(response.body, arena, reply);
}

private Status encodeBody(Buffer buffer, ref scope RequestArena arena, ref WorkerReply reply) nothrow
{
    if (buffer.length() <= workerPacketBytes)
        return arena.read(buffer, (scope const(ubyte)[] content) @safe nothrow @nogc {
            reply.body[0 .. content.length] = content;
            reply.length = cast(ushort) content.length;
        });
    auto copy = new ubyte[buffer.length()];
    const read = arena.read(buffer, (scope const(ubyte)[] content) @safe nothrow @nogc {
        copy[0 .. content.length] = content;
    });
    reply.large = copy;
    return read;
}

private Result!Response copyResponse(ref WorkerReply reply, ref scope RequestArena arena) nothrow @nogc
{
    if (reply.error != Status.ok)
        return failure(reply.error);
    const payload = arena.copyIn(reply.large.length ? reply.large : reply.body[0 .. reply.length]);
    const media = reply.contentType.length ? reply.contentType : workerMediaTypes[reply.media];
    reply.large = null;
    reply.contentType = null;
    if (!payload.ok())
        return Result!Response(Response.init, payload.error);
    return Result!Response(Response(reply.status, media, payload.value));
}

private Result!Response failure(Status status) nothrow @nogc
{
    return Result!Response(Response.init, Error(status, "HTTP controller worker could not complete request"));
}
