/// Explicit, signed and bounded S3-compatible object transfers.
module flint.engine.storage;

import flint.arena : Buffer, Error, Arena = RequestArena, Result, Status;
import flint.conc : Context;
import flint.engine.http : ChunkConsumer, HttpMethod;
import flint.engine.storage.endpoint : Endpoint, configure, regionValid;
import flint.engine.storage.multipart : Owner;
import flint.engine.storage.parts : minimumNonfinal;
import flint.engine.storage.response : readHead;
import flint.engine.storage.wire : Request, responseStatus;

public import flint.engine.storage.multipart : Upload;
public import flint.engine.storage.types : CredentialProvider, Credentials, DownloadOptions,
    ObjectInfo, StorageOptions;

@safe:

/// Operations share a connection pool and a generation-checked upload table.
struct ObjectStorage
{
    private Owner state;

    /// Prepare the explicit endpoint, credential worker and owned multipart buffers.
    Error open(StorageOptions options, CredentialProvider credentials)
    {
        if (state !is null && state.opened)
            return Error(Status.conflict, "S3 storage client already open");
        if (credentials is null || !validOptions(options))
            return Error(Status.invalidArgument, "invalid S3 credentials provider or resource limits");
        Endpoint endpoint;
        const selected = configure(options, endpoint);
        if (selected.code != Status.ok)
            return selected;
        auto created = new Owner(endpoint, options, credentials);
        const started = created.start(options);
        if (started.code == Status.ok)
            state = created;
        return started;
    }

    /// Read metadata from a signed HEAD request.
    Result!ObjectInfo head(string bucket, string key, ref scope Arena arena, ref Context context) nothrow @nogc
    {
        const active = ready();
        if (active.code != Status.ok)
            return Result!ObjectInfo(ObjectInfo.init, active);
        const request = Request(HttpMethod.head, bucket, key);
        const result = state.transport.send(request, null, arena, context);
        const handled = result.ok ? responseStatus(result.value.status) : result.error;
        return handled.code == Status.ok ? readHead(result.value.headers,
                arena) : Result!ObjectInfo(ObjectInfo.init, handled);
    }

    /// Read verified bytes into a synchronous, scoped application callback.
    Error get(string bucket, string key, scope ChunkConsumer consume, ref Context context) nothrow @nogc
    {
        return get(bucket, key, DownloadOptions.init, consume, context);
    }

    /// Apply an optional range, ETag precondition, and explicit object version.
    // dfmt off
    Error get(string bucket, string key, DownloadOptions options, scope ChunkConsumer consume,
            ref Context context) nothrow @nogc
    {
        const active = ready();
        if (active.code != Status.ok)
            return active;
        if (consume is null || options.versionId.length > 1_024)
            return Error(Status.invalidArgument, "invalid S3 download consumer or object version");
        const request = Request(HttpMethod.get, bucket, key, options);
        return state.transport.stream(request, consume, context);
    }
    // dfmt on

    /// Reserve an upload. The first nonempty write starts multipart negotiation.
    Result!Upload beginUpload(string bucket, string key, string contentType, ref Context context) nothrow @nogc
    {
        if (state is null)
            return Result!Upload(Upload.init, closed());
        return state.begin(bucket, key, contentType, context);
    }

    /// Delete the selected object from the configured destination.
    Error remove(string bucket, string key, ref Context context) nothrow @nogc
    {
        const active = ready();
        if (active.code != Status.ok)
            return active;
        ubyte[8_192] storage;
        auto arena = Arena(storage[]);
        const request = Request(HttpMethod.delete_, bucket, key);
        const result = state.transport.send(request, null, arena, context);
        return result.ok ? responseStatus(result.value.status) : result.error;
    }

    /// Return a private download URL whose lifetime is bounded by the credential.
    // dfmt off
    Result!Buffer presignGet(string bucket, string key, uint expiresSeconds,
            long nowUnixSeconds, ref scope Arena arena) nothrow @nogc
    {
        const active = ready();
        if (active.code != Status.ok)
            return Result!Buffer(Buffer.init, active);
        return state.transport.presign(bucket, key, expiresSeconds, nowUnixSeconds, arena);
    }
    // dfmt on

    /// Close the transport and retire the management threads on the owner.
    Error close() nothrow @nogc
    {
        if (state is null)
            return Error.init;
        const retired = state.close();
        if (retired.code == Status.ok)
            state = null;
        return retired;
    }

    private Error ready() nothrow @nogc
    {
        return state is null ? closed() : state.ready();
    }
}

private Error closed() pure nothrow @nogc
{
    return Error(Status.conflict, "S3 storage client is closed");
}

private bool validOptions(scope const ref StorageOptions options) pure nothrow @nogc
{
    if (options.concurrentParts == 0 || options.concurrentParts > 4 || options.maxUploads == 0
            || options.maxUploads > options.concurrentParts)
        return false;
    if (options.partBytes < minimumNonfinal || options.partBytes > 5UL * 1024 * 1024 * 1024
            || options.partBytes > options.maxBufferedBytes / options.concurrentParts)
        return false;
    return options.clockSkewSeconds >= -900 && options.clockSkewSeconds <= 900
        && options.maxDownloadBytes != 0 && regionValid(options.region);
}
