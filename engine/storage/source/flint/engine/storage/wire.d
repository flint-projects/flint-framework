/// Scoped HTTP exchange and SigV4 request assembly.
module flint.engine.storage.wire;

import flint.arena : Buffer, Error, Arena = RequestArena, Result, Status;
import flint.conc : Context;
import flint.engine.http : ChunkConsumer, ClientOptions, HttpClient, HttpMethod, HttpRequestView,
    HttpResponse, HttpStreamField;
import flint.engine.security : eraseSecret;
import flint.engine.storage.credentials : CredentialStore, unixSeconds;
import flint.engine.storage.encoding : Writer, safeField;
import flint.engine.storage.endpoint : Endpoint, maximumUrl, objectValid, writeHost, writePath;
import flint.engine.storage.sigv4 : CredentialView, Message, SigningScratch, authorize, formatDate,
    maximumExpiry, payloadHash, sign, unsignedPayload, writePresignedQuery;
import flint.engine.storage.types : DownloadOptions, StorageOptions;

@safe:

package(flint.engine.storage) enum Operation : ubyte
{
    object,
    begin,
    part,
    finish,
    abortUpload
}

package(flint.engine.storage) struct Request
{
    HttpMethod method;
    string bucket;
    string key;
    DownloadOptions download;
    string contentType;
    Operation operation;
    uint part;
    const(char)[] uploadId;
}

package(flint.engine.storage) final class Transport
{
    private HttpClient client;
    private Endpoint endpoint;
    private string region;
    private int clockSkew;
    private CredentialStore credentials;
    private Frame[] frames;

    this(Endpoint endpoint, StorageOptions options, CredentialStore credentials, uint concurrency)
    {
        this.endpoint = endpoint;
        this.credentials = credentials;
        region = options.region;
        clockSkew = options.clockSkewSeconds;
        frames = new Frame[concurrency];
        foreach (ref frame; frames)
            frame = new Frame;
    }

    Error open(StorageOptions options)
    {
        ClientOptions config;
        config.caBundle = options.caBundle;
        config.maxConnections = cast(uint) frames.length;
        config.maxConnectionsPerOrigin = config.maxConnections;
        config.maxResponseBytes = options.maxDownloadBytes;
        return client.open(config);
    }

    Error close() scope nothrow @nogc
    {
        return client.close();
    }

    Result!HttpResponse send(scope const ref Request input, scope const(ubyte)[] payload,
            ref scope Arena arena, ref Context context) scope nothrow @nogc
    {
        auto frame = acquire();
        if (frame is null)
            return Result!HttpResponse(HttpResponse.init, full());
        scope (exit)
            frame.clear();
        const prepared = prepare(frame, input, payload);
        if (prepared.code != Status.ok)
            return Result!HttpResponse(HttpResponse.init, prepared);
        scope view = frame.view(input.method, payload);
        return client.sendView(view, arena, context);
    }

    Error stream(scope const ref Request input, scope ChunkConsumer consume, ref Context context) scope nothrow @nogc
    {
        auto frame = acquire();
        if (frame is null)
            return full();
        scope (exit)
            frame.clear();
        const prepared = prepare(frame, input, null);
        if (prepared.code != Status.ok)
            return prepared;
        scope view = frame.view(input.method, null);
        view.successBodyOnly = true;
        // Streaming exposes no retained response fields.
        ubyte[1] space;
        auto arena = Arena(space[]);
        const received = client.streamView(view, arena, context, consume);
        return received.ok ? responseStatus(received.value) : received.error;
    }

    Result!Buffer presign(string bucket, string key, uint expires, long now, ref scope Arena arena) scope nothrow @nogc
    {
        if (!objectValid(bucket, key) || expires == 0 || expires > maximumExpiry || now < 0)
            return Result!Buffer(Buffer.init, Error(Status.invalidArgument, "invalid presign object or expiry"));
        const credential = credentials.take(unixSeconds());
        if (!credential.ok)
            return Result!Buffer(Buffer.init, credential.error);
        scope identity = credential.value.view();
        if (!lifetimeAllows(identity.expiry, expires, now))
            return Result!Buffer(Buffer.init, Error(Status.permissionDenied, "presign exceeds credential lifetime"));
        auto frame = acquire();
        if (frame is null)
            return Result!Buffer(Buffer.init, full());
        scope (exit)
            frame.clear();
        const origin = frame.objectTarget(endpoint, bucket, key);
        if (origin.code != Status.ok)
            return Result!Buffer(Buffer.init, origin);
        if (!formatDate(now, frame.date))
            return Result!Buffer(Buffer.init, Error(Status.invalidArgument, "invalid presign time"));
        const formed = writePresign(frame, identity, expires);
        if (formed.code != Status.ok)
            return Result!Buffer(Buffer.init, formed);
        return arena.copyIn(cast(const(ubyte)[]) frame.url[0 .. frame.urlLength]);
    }

    private Error writePresign(Frame frame, scope const ref CredentialView identity, uint expires) scope nothrow @nogc
    {
        scope query = Writer(frame.query[]);
        writePresignedQuery(query, identity, frame.date[], region, expires);
        if (!query.valid)
            return full();
        auto message = frame.message(HttpMethod.get, region, query.length, unsignedPayload);
        frame.canonical[0] = HttpStreamField("host", frame.host[0 .. frame.hostLength]);
        char[64] signature;
        const signed = sign(identity, message, frame.canonical[0 .. 1], frame.signing, signature);
        if (signed.code != Status.ok)
            return signed;
        query.append("&X-Amz-Signature=");
        query.append(signature[]);
        if (!query.valid || !frame.writeUrl(endpoint.secure, query.length))
            return full();
        return Error.init;
    }

    private Error prepare(Frame frame, scope const ref Request input, scope const(ubyte)[] payload) scope nothrow @nogc
    {
        if (!objectValid(input.bucket, input.key))
            return Error(Status.invalidArgument, "invalid S3 bucket or object key");
        const now = unixSeconds();
        const credential = credentials.take(now);
        if (!credential.ok)
            return credential.error;
        const origin = frame.objectTarget(endpoint, input.bucket, input.key);
        if (origin.code != Status.ok)
            return origin;
        if (!formatDate(now + clockSkew, frame.date))
            return Error(Status.unavailable, "cannot form an S3 signing timestamp");
        const hashed = payloadHash(payload, frame.hash);
        if (hashed.code != Status.ok)
            return hashed;
        scope query = Writer(frame.query[]);
        const parameters = writeQuery(query, input);
        if (parameters.code != Status.ok)
            return parameters;
        if (!frame.writeUrl(endpoint.secure, query.length))
            return full();
        const signedHeaders = frame.headers(input, credential.value.value.sessionToken);
        if (signedHeaders.code != Status.ok)
            return signedHeaders;
        const message = frame.message(input.method, region, query.length, frame.hash[]);
        scope identity = credential.value.view();
        return authorize(identity, message, frame.canonical[0 .. frame.signatureCount], frame.signing);
    }

    private Frame acquire() scope nothrow @nogc
    {
        foreach (frame; frames)
            if (!frame.busy)
            {
                frame.busy = true;
                return frame;
            }
        return null;
    }
}

private final class Frame
{
    bool busy;
    char[328] host;
    char[4_096] path;
    char[8_192] query;
    char[maximumUrl] url;
    char[16] date;
    char[64] hash;
    char[64] range;
    char[256] mediaType;
    char[512] condition;
    size_t hostLength, pathLength, urlLength;
    HttpStreamField[8] canonical;
    HttpStreamField[8] wire;
    size_t signatureCount, fieldCount;
    SigningScratch signing;

    void clear() scope nothrow @nogc
    {
        canonical[] = HttpStreamField.init;
        wire[] = HttpStreamField.init;
        eraseSecret(cast(ubyte[]) signing.authorization[]);
        eraseSecret(cast(ubyte[]) signing.canonical[]);
        busy = false;
    }

    // dfmt off
    Error objectTarget(scope const ref Endpoint endpoint, scope const(char)[] bucket,
            scope const(char)[] key) scope nothrow @nogc
    {
        scope authority = Writer(host[]);
        scope object = Writer(path[]);
        writeHost(authority, endpoint, bucket);
        writePath(object, endpoint.pathStyle, bucket, key);
        hostLength = authority.length;
        pathLength = object.length;
        return authority.valid && object.valid ? Error.init : full();
    }
    // dfmt on

    bool writeUrl(bool secure, size_t queryLength) scope nothrow @nogc
    {
        scope target = Writer(url[]);
        target.append(secure ? "https://" : "http://");
        target.append(host[0 .. hostLength]);
        target.append(path[0 .. pathLength]);
        if (queryLength != 0)
        {
            target.put('?');
            target.append(query[0 .. queryLength]);
        }
        urlLength = target.length;
        return target.valid;
    }

    // dfmt off
    Message message(HttpMethod method, string region, size_t queryLength,
            return scope const(char)[] hashValue) return scope nothrow @nogc
    {
        static immutable string[7] names = [
            "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"
        ];
        return Message(names[method], path[0 .. pathLength], query[0 .. queryLength], date[], region, hashValue);
    }
    // dfmt on

    Error headers(scope const ref Request request, string token) nothrow @nogc
    {
        signatureCount = 0;
        fieldCount = 0;
        if (!safeField(request.contentType, 256) || !safeField(request.download.ifMatch, 512))
            return Error(Status.invalidArgument, "invalid S3 content type or ETag condition");
        if (request.contentType.length)
        {
            const size = request.contentType.length;
            mediaType[0 .. size] = request.contentType;
            append("content-type", mediaType[0 .. size]);
        }
        canonical[signatureCount++] = HttpStreamField("host", host[0 .. hostLength]);
        if (request.download.ifMatch.length)
        {
            const size = request.download.ifMatch.length;
            condition[0 .. size] = request.download.ifMatch;
            append("if-match", condition[0 .. size]);
        }
        if (request.download.hasRange)
        {
            if (request.download.first > request.download.last)
                return Error(Status.invalidArgument, "invalid S3 byte range");
            scope writer = Writer(range[]);
            writer.append("bytes=");
            writer.decimal(request.download.first);
            writer.put('-');
            writer.decimal(request.download.last);
            append("range", range[0 .. writer.length]);
        }
        append("x-amz-content-sha256", hash[]);
        append("x-amz-date", date[]);
        if (token.length)
            append("x-amz-security-token", token);
        return Error.init;
    }

    private void append(string name, const(char)[] value) scope nothrow @nogc
    {
        canonical[signatureCount++] = HttpStreamField(name, value);
        wire[fieldCount++] = HttpStreamField(name, value);
    }

    HttpRequestView view(HttpMethod method, return scope const(ubyte)[] payload) return scope nothrow @nogc
    {
        auto request = HttpRequestView(method, url[0 .. urlLength], wire[0 .. fieldCount], payload, true);
        request.finalField = HttpStreamField("Authorization", signing.authorization[0 .. signing.authLength]);
        return request;
    }
}

private Error writeQuery(ref scope Writer query, scope const ref Request request) pure nothrow @nogc
{
    final switch (request.operation)
    {
    case Operation.object:
        if (request.download.versionId.length)
        {
            query.append("versionId=");
            query.percent(request.download.versionId);
        }
        break;
    case Operation.begin:
        query.append("uploads=");
        break;
    case Operation.part, Operation.finish, Operation.abortUpload:
        if (request.operation == Operation.part)
        {
            query.append("partNumber=");
            query.decimal(request.part);
            query.put('&');
        }
        query.append("uploadId=");
        query.percent(request.uploadId);
        break;
    }
    return query.valid ? Error.init : full();
}

package(flint.engine.storage) Error responseStatus(ushort status) pure nothrow @nogc
{
    if (status >= 200 && status < 300)
        return Error.init;
    switch (status)
    {
    case 400:
        return Error(Status.invalidArgument, "S3 rejected the request");
    case 401, 403:
        return Error(Status.permissionDenied, "S3 rejected the credentials or object access");
    case 404:
        return Error(Status.notFound, "S3 object or multipart upload was not found");
    case 409, 412:
        return Error(Status.conflict, "S3 object condition was not satisfied");
    case 416:
        return Error(Status.invalidArgument, "S3 byte range was unsatisfiable");
    default:
        return Error(Status.unavailable, "S3 service returned an unexpected response");
    }
}

private Error full() pure nothrow @nogc
{
    return Error(Status.resourceExhausted, "S3 request workspace exceeded its capacity");
}

private bool lifetimeAllows(long expiry, uint expires, long now) pure nothrow @nogc
{
    return expiry == 0 || (now < expiry && expires <= expiry - now);
}
