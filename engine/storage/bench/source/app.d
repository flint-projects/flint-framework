module app;

import core.memory : GC;
import core.time : MonoTime;
import flint.arena : Error, RequestArena, Result, Status;
import flint.conc : Context, Deadline;
import flint.engine.storage : Credentials, ObjectStorage, StorageOptions;
import storage_workload : Checksum, access, address, bucket, key, objectBytes, objectType,
    parallelParts, partBytes, parts, report, require, secret, stripe, stripeBytes, token;

@safe:

private Result!Credentials credentials(ref Context context) nothrow
{
    const active = context.check();
    if (active.code != Status.ok)
        return Result!Credentials(Credentials.init, active);
    return Result!Credentials(Credentials(access, secret, token, 4_102_444_800));
}

void main()
{
    StorageOptions options;
    options.endpoint = address();
    options.pathStyle = true;
    options.allowLoopbackCleartext = true;
    options.partBytes = partBytes;
    options.concurrentParts = parallelParts;
    options.maxBufferedBytes = parallelParts * partBytes;
    options.maxDownloadBytes = objectBytes;

    ObjectStorage storage;
    const provider = delegate(ref Context context) @safe nothrow{ return credentials(context); };
    require(storage.open(options, provider).code == Status.ok, "cannot open Storage");
    scope (exit)
        require(storage.close().code == Status.ok, "cannot close Storage");

    auto context = Context.init.withDeadline(Deadline.afterMillis(120_000));
    ubyte[65_536] scratch;
    scope arena = RequestArena(scratch[]);
    Checksum downloaded;
    downloaded.open();
    auto receive = (scope const(ubyte)[] data) @safe nothrow @nogc {
        downloaded.add(data);
        return Error.init;
    };
    const allocated = GC.stats().allocatedInCurrentThread;
    const start = MonoTime.currTime;
    auto transfer = storage.beginUpload(bucket, key, objectType, context);
    require(transfer.ok, transfer.error.message);
    scope (failure)
        transfer.value.abort(context);

    ubyte[stripeBytes] payload;
    foreach (part; 1 .. parts + 1)
    {
        stripe(part, payload[]);
        foreach (_; 0 .. partBytes / stripeBytes)
        {
            const sent = transfer.value.write(payload[], context);
            require(sent.code == Status.ok, sent.message);
        }
    }
    const complete = transfer.value.complete(arena, context);
    require(complete.ok && complete.value.size == objectBytes && complete.value.etag.length != 0,
            complete.error.message);
    const uploaded = MonoTime.currTime;
    const downloadedStatus = storage.get(bucket, key, receive, context);
    const finished = MonoTime.currTime;
    require(downloadedStatus.code == Status.ok, downloadedStatus.message);
    require(storage.remove(bucket, key, context).code == Status.ok, "cannot delete fixture object");
    report(downloaded, start, uploaded, finished, allocated);
}
