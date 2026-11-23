module flint.engine.storage.storage_behavior;

import core.atomic : atomicOp;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context, Deadline;
import flint.conc.wait : waitUntil;
import flint.engine.http : ClientOptions, HttpClient, HttpMethod, HttpRequestView, HttpStreamField;
import flint.engine.storage : CredentialProvider, Credentials, DownloadOptions, ObjectStorage, StorageOptions;
import flint.engine.storage.credentials : CredentialStore, unixSeconds;
import flint.engine.storage.sigv4 : CredentialView, Message, SigningScratch, formatDate, payloadHash, sign;
import flint.engine.storage.xml : Envelope, EnvelopeKind, copyXmlText, readEnvelope;
import std.process : environment;

@safe:

@("S3 XML accepts bounded envelopes and rejects active XML constructs and ambiguous fields")
unittest
{
    Envelope output;
    enum initiated = "<?xml version='1.0'?><InitiateMultipartUploadResult xmlns='urn:s3'>"
        ~ "<UploadId>a/b+&amp;z</UploadId></InitiateMultipartUploadResult>";
    assert(readEnvelope(initiated, output).code == Status.ok && output.kind == EnvelopeKind.initiated);
    char[32] decoded;
    size_t used;
    assert(copyXmlText(initiated, output.uploadId, decoded[], used).code == Status.ok);
    assert(decoded[0 .. used] == "a/b+&z");
    enum completed = "<CompleteMultipartUploadResult><ETag>&#34;&#x1f98a;&#34;</ETag></CompleteMultipartUploadResult>";
    assert(readEnvelope(completed, output).code == Status.ok);
    assert(copyXmlText(completed, output.etag, decoded[], used).code == Status.ok);
    assert(decoded[0 .. used] == "\"🦊\"");
    assert(readEnvelope(" \r\n<Error><Code>InternalError</Code></Error>\n", output).code == Status.ok);
    assert(output.kind == EnvelopeKind.serviceError);
    foreach (document; [
        "<!DOCTYPE x [<!ENTITY ext SYSTEM 'file:///tmp/fixture'>]><Error>&ext;</Error>",
        "<CompleteMultipartUploadResult><ETag>x</ETag><ETag>y</ETag></CompleteMultipartUploadResult>",
        "<CompleteMultipartUploadResult><ETag>x</bad></CompleteMultipartUploadResult>",
        "<Error/><Error/>", "<Error><Code>bad</Code>", "<Error>&#0;</Error>",
        "<Error>&#xd800;</Error>", "<Error>&#1114112;</Error>", "<Error>&#x;</Error>",
        "<Error>&undeclared;</Error>"
    ])
        assert(readEnvelope(document, output).code == Status.invalidArgument);
    char[16] date;
    assert(formatDate(0, date) && date[] == "19700101T000000Z");
    assert(formatDate(1_369_353_600, date) && date[] == "20130524T000000Z");
}

version (FlintNativeOpenssl)
{
    @("SigV4 matches the published S3 GET object Range signature")
    unittest
    {
        CredentialView credential = CredentialView("AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY");
        char[64] digest, signature;
        assert(payloadHash(null, digest).code == Status.ok);
        assert(digest[] == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        enum emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        const HttpStreamField[4] fields = [
            HttpStreamField("host", "examplebucket.s3.amazonaws.com"),
            HttpStreamField("range", "bytes=0-9"), HttpStreamField("x-amz-content-sha256",
                    emptyHash), HttpStreamField("x-amz-date", "20130524T000000Z")
        ];
        const message = Message("GET", "/test.txt", null, "20130524T000000Z", "us-east-1", digest[]);
        SigningScratch work;
        assert(sign(credential, message, fields[], work, signature).code == Status.ok);
        assert(signature[] == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41");
    }
}

@("credential refresh publishes one immutable snapshot and expires old identities")
unittest
{
    shared uint calls;
    auto credentials = new CredentialStore((ref Context) @safe nothrow{
        const seen = atomicOp!"+="(calls, 1u);
        if (seen == 1)
            return Result!Credentials(Credentials("first-access", "first-secret", "first-token", unixSeconds() + 2));
        return Result!Credentials(Credentials("next-access", "next-secret", "next-token", unixSeconds() + 60));
    });
    assert(credentials.start().code == Status.ok);
    const first = credentials.take(unixSeconds());
    assert(first.ok && first.value.value.accessKeyId == "first-access");
    const deadline = Deadline.afterMillis(4_000).monotonicNanoseconds;
    for (;;)
    {
        const snapshot = credentials.take(unixSeconds());
        if (snapshot.ok && snapshot.value.value.accessKeyId == "next-access")
        {
            assert(snapshot.value.value.secretAccessKey == "next-secret");
            assert(snapshot.value.value.sessionToken == "next-token");
            assert(credentials.take(snapshot.value.value.expiresAtUnixSeconds).error.code == Status.unavailable);
            break;
        }
        assert(Deadline.afterMillis(0).monotonicNanoseconds < deadline);
        assert(waitUntil(Deadline.afterMillis(10)).code == Status.ok);
    }
    assert(first.value.value.secretAccessKey == "first-secret" && first.value.value.sessionToken == "first-token");
    while (credentials.close().code != Status.ok)
    {
        assert(Deadline.afterMillis(0).monotonicNanoseconds < deadline);
        assert(waitUntil(Deadline.afterMillis(5)).code == Status.ok);
    }
}

@("Real signed HTTP verifies multipart, embedded failures, private presigning and opaque metadata")
unittest
{
    const address = environment.get("FLINT_S3_TEST_URL", "");
    if (!address.length)
        return;
    StorageOptions options;
    options.endpoint = address;
    options.pathStyle = true;
    options.allowLoopbackCleartext = true;
    ObjectStorage storage;
    const opened = storage.open(options, (ref Context) @safe nothrow{
        return Result!Credentials(Credentials("fixture-access", "fixture-secret",
            "fixture-session", unixSeconds() + 600));
    });
    assert(opened.code == Status.ok, opened.message);
    scope (exit)
        assert(storage.close().code == Status.ok);
    auto context = Context.init.withDeadline(Deadline.afterMillis(15_000));
    ubyte[16_384] backing;
    auto arena = RequestArena(backing[]);
    enum key = "a//../white space+%🦊.json";
    enum bucket = "flint-test";
    assert(storage.head(bucket, key, arena, context).error.code == Status.notFound);
    auto uploaded = storage.beginUpload(bucket, key, "application/octet-stream", context);
    assert(uploaded.ok, uploaded.error.message);
    auto sample = new ubyte[options.partBytes + 123];
    sample[] = 37;
    assert(uploaded.value.write(sample[0 .. options.partBytes - 7], context).code == Status.ok);
    const added = uploaded.value.write(sample[options.partBytes - 7 .. $], context);
    assert(added.code == Status.ok, added.message);
    const done = uploaded.value.complete(arena, context);
    assert(done.ok, done.error.message);
    assert(done.value.size == sample.length && done.value.etag.length != 0 && done.value.versionId.length != 0);
    assert(uploaded.value.write(sample[0 .. 1], context).code == Status.notFound);

    const observed = storage.head(bucket, key, arena, context);
    assert(observed.ok && observed.value.size == sample.length, observed.error.message);
    DownloadOptions wanted = DownloadOptions(true, 7, 29, "\"obj&&etag\"", "rev/1+");
    size_t received;
    const fetched = storage.get(bucket, key, wanted, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        foreach (byteValue; bytes)
            assert(byteValue == 37);
        received += bytes.length;
        return Error.init;
    }, context);
    assert(fetched.code == Status.ok && received == 23, fetched.message);
    assert(storage.presignGet(bucket, key, 601, unixSeconds(), arena).error.code == Status.permissionDenied);
    const signed = storage.presignGet(bucket, key, 60, unixSeconds(), arena);
    assert(signed.ok, signed.error.message);
    assert(readPresigned(arena, signed, address, context) == sample.length);
    assert(storage.remove(bucket, key, context).code == Status.ok);

    auto rejected = storage.beginUpload(bucket, "finish-fails", "application/octet-stream", context);
    assert(rejected.ok && rejected.value.write(sample[0 .. 128], context).code == Status.ok);
    const failure = rejected.value.complete(arena, context);
    assert(failure.error.code == Status.ioError, failure.error.message);
    auto malformed = storage.beginUpload(bucket, "finish-malformed", "application/octet-stream", context);
    assert(malformed.ok && malformed.value.write(sample[0 .. 128], context).code == Status.ok);
    const truncated = malformed.value.complete(arena, context);
    assert(!truncated.ok && truncated.error.code != Status.ok, "malformed completion XML was treated as success");
    auto empty = storage.beginUpload(bucket, "empty", "application/octet-stream", context);
    assert(empty.ok);
    const result = empty.value.complete(arena, context);
    assert(result.ok && result.value.size == 0, result.error.message);

    if (environment.get("FLINT_S3_TEST_ABORT", "") == "1")
        verifyAbort(storage, options, arena, context);
}

@("MinIO accepts the signed multipart upload, ranged GET, and presigned GET")
unittest
{
    const address = environment.get("FLINT_S3_MINIO_URL", "");
    if (!address.length)
        return;
    StorageOptions options;
    options.endpoint = address;
    options.pathStyle = true;
    options.allowLoopbackCleartext = true;
    ObjectStorage storage;
    const opened = storage.open(options, (ref Context) @safe nothrow{
        return Result!Credentials(Credentials("fixture-access", "fixture-secret"));
    });
    assert(opened.code == Status.ok, opened.message);
    scope (exit)
        assert(storage.close().code == Status.ok);
    auto context = Context.init.withDeadline(Deadline.afterMillis(30_000));
    ubyte[16_384] backing;
    auto arena = RequestArena(backing[]);
    enum key = "white space+%🦊.json";
    enum bucket = "flint-test";
    auto upload = storage.beginUpload(bucket, key, "application/octet-stream", context);
    assert(upload.ok, upload.error.message);
    auto sample = new ubyte[options.partBytes + 123];
    sample[] = 37;
    const written = upload.value.write(sample, context);
    assert(written.code == Status.ok, written.message);
    const completed = upload.value.complete(arena, context);
    assert(completed.ok && completed.value.size == sample.length, completed.error.message);
    const metadata = storage.head(bucket, key, arena, context);
    assert(metadata.ok && metadata.value.size == sample.length && metadata.value.etag.length, metadata.error.message);
    ulong received;
    const fetched = storage.get(bucket, key, DownloadOptions(true, 7, 29), (scope const(ubyte)[] payload) {
        foreach (entry; payload)
            assert(entry == 37);
        received += payload.length;
        return Error.init;
    }, context);
    assert(fetched.code == Status.ok && received == 23, fetched.message);
    const signed = storage.presignGet(bucket, key, 60, unixSeconds(), arena);
    assert(signed.ok, signed.error.message);
    assert(readPresigned(arena, signed, address, context) == sample.length);
    assert(storage.remove(bucket, key, context).code == Status.ok);
    assert(storage.head(bucket, key, arena, context).error.code == Status.notFound);
    foreach (unsupportedKey; ["a//white space+%🦊.json", "a/../white space+%🦊.json"])
    {
        auto rejected = storage.beginUpload(bucket, unsupportedKey, "application/octet-stream", context);
        assert(rejected.ok, rejected.error.message);
        const attempted = rejected.value.write(sample[0 .. 1], context);
        assert(attempted.code == Status.invalidArgument && attempted.message == "S3 rejected the request");
        assert(rejected.value.abort(context).code == Status.ok);
    }
}

private ulong readPresigned(ref scope RequestArena arena, Result!Buffer signed, string address, ref Context context)
{
    HttpClient verifier;
    ClientOptions options;
    options.maxResponseBytes = 16 * 1024 * 1024;
    assert(verifier.open(options).code == Status.ok);
    scope (exit)
        assert(verifier.close().code == Status.ok);
    ulong verified;
    assert(arena.read(signed.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            const found = cast(const(char)[]) bytes;
            assert(found[0 .. address.length] == address);
            ubyte[1] responseMemory;
            auto responseArena = RequestArena(responseMemory[]);
            scope request = HttpRequestView(HttpMethod.get, found);
            request.preservePath = true;
            request.successBodyOnly = true;
            const confirmed = verifier.streamView(request, responseArena, context, (scope const(ubyte)[] payload) {
                foreach (entry; payload)
                    assert(entry == 37);
                verified += payload.length;
                return Error.init;
            });
            assert(confirmed.ok && confirmed.value == 200);
        }) == Status.ok);
    return verified;
}

private void verifyAbort(ref ObjectStorage storage, StorageOptions options,
        ref scope RequestArena arena, ref Context context)
{
    auto upload = storage.beginUpload("flint-test", "abort-race", "application/octet-stream", context);
    assert(upload.ok);
    auto bytes = new ubyte[options.partBytes];
    foreach (_; 0 .. options.concurrentParts)
        assert(upload.value.write(bytes, context).code == Status.ok);
    for (;;)
    {
        assert(arena.reset() == Status.ok);
        const pending = storage.head("flint-test", "hold-status", arena, context);
        assert(pending.ok, pending.error.message);
        if (pending.value.size == options.concurrentParts)
            break;
        assert(context.check().code == Status.ok);
        assert(waitUntil(Deadline.afterMillis(10)).code == Status.ok);
    }
    assert(upload.value.abort(context).code == Status.unavailable);
    const identity = upload.value.copyUploadId(arena);
    assert(identity.ok);
    assert(upload.value.write(bytes[0 .. 1], context).code == Status.unavailable);
    assert(upload.value.abort(context).code == Status.ok);
    assert(upload.value.copyUploadId(arena).error.code == Status.notFound);
}

version (FlintNativeOpenssl)
{
    private enum awsAccess = "AKIAIOSFODNN7EXAMPLE";
    private enum awsSecret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
    private enum awsHost = "examplebucket.s3.amazonaws.com";
    private enum awsDate = "20130524T000000Z";
    private enum awsEmpty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    private void expectSignature(scope const ref CredentialView credential,
            scope const ref Message message, scope const(HttpStreamField)[] fields, scope const(char)[] expected)
    {
        SigningScratch work;
        char[64] signature;
        assert(sign(credential, message, fields, work, signature).code == Status.ok);
        assert(signature[] == expected);
    }

    @("sigv4_vectors: published PUT object, bucket lifecycle and list-objects signatures match byte for byte")
    unittest
    {
        const credential = CredentialView(awsAccess, awsSecret);
        char[64] digest;
        assert(payloadHash(cast(const(ubyte)[]) "Welcome to Amazon S3.", digest).code == Status.ok);
        enum putHash = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072";
        assert(digest[] == putHash);
        const HttpStreamField[5] put = [
            HttpStreamField("date", "Fri, 24 May 2013 00:00:00 GMT"), HttpStreamField("host",
                    awsHost), HttpStreamField("x-amz-content-sha256",
                    putHash), HttpStreamField("x-amz-date", awsDate),
            HttpStreamField("x-amz-storage-class", "REDUCED_REDUNDANCY")
        ];
        const putMessage = Message("PUT", "/test%24file.text", null, awsDate, "us-east-1", putHash);
        expectSignature(credential, putMessage, put[],
                "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd");

        const HttpStreamField[3] bucket = [
            HttpStreamField("host", awsHost), HttpStreamField("x-amz-content-sha256", awsEmpty),
            HttpStreamField("x-amz-date", awsDate)
        ];
        const lifecycle = Message("GET", "/", "lifecycle=", awsDate, "us-east-1", awsEmpty);
        expectSignature(credential, lifecycle, bucket[],
                "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543");
        const list = Message("GET", "/", "max-keys=2&prefix=J", awsDate, "us-east-1", awsEmpty);
        expectSignature(credential, list, bucket[],
                "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7");
    }

    @("sigv4_vectors: a temporary session token is signed as a canonical header")
    unittest
    {
        // Reference value from an independent Python hmac/hashlib SigV4 implementation (as in tests/local_peer.py).
        enum token = "FQoGZXIvYXdzEJr//////////wEaDOtoken+/=";
        const credential = CredentialView(awsAccess, awsSecret, token, 1_369_354_600);
        const HttpStreamField[4] fields = [
            HttpStreamField("host", awsHost), HttpStreamField("x-amz-content-sha256", awsEmpty),
            HttpStreamField("x-amz-date", awsDate), HttpStreamField("x-amz-security-token", token)
        ];
        const message = Message("GET", "/a%20b/c", null, awsDate, "eu-west-2", awsEmpty);
        expectSignature(credential, message, fields[],
                "4b0d080d7e5d21763925b171f50e9e661c514efa62f786784585242a14f2621a");
        // Omitting the token from the signed fields changes the signature.
        SigningScratch work;
        char[64] other;
        assert(sign(credential, message, fields[0 .. 3], work, other).code == Status.ok);
        assert(other[] != "4b0d080d7e5d21763925b171f50e9e661c514efa62f786784585242a14f2621a");
    }

    private ObjectStorage openOffline(string endpoint, Credentials credentials)
    {
        StorageOptions options;
        options.endpoint = endpoint;
        options.pathStyle = endpoint[0 .. 5] == "http:";
        options.allowLoopbackCleartext = options.pathStyle;
        ObjectStorage storage;
        const opened = storage.open(options, (ref Context) @safe nothrow => Result!Credentials(credentials));
        assert(opened.code == Status.ok, opened.message);
        return storage;
    }

    private bool contains(scope const(char)[] text, scope const(char)[] needle) pure nothrow @nogc
    {
        foreach (index; 0 .. text.length >= needle.length ? text.length - needle.length + 1 : 0)
            if (text[index .. index + needle.length] == needle)
                return true;
        return false;
    }

    @("presign_bounds: the published presigned GET URL matches and expiry is capped at seven days")
    unittest
    {
        auto storage = openOffline("https://s3.amazonaws.com", Credentials(awsAccess, awsSecret));
        scope (exit)
            assert(storage.close().code == Status.ok);
        ubyte[4096] backing;
        auto arena = RequestArena(backing[]);
        const signed = storage.presignGet("examplebucket", "test.txt", 86_400, 1_369_353_600, arena);
        assert(signed.ok, signed.error.message);
        enum expected = "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256"
            ~ "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
            ~ "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host"
            ~ "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404";
        bool matched;
        assert(arena.read(signed.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
                matched = cast(const(char)[]) bytes == expected;
            }) == Status.ok);
        assert(matched);
        const now = unixSeconds();
        assert(storage.presignGet("examplebucket", "test.txt", 604_800, now, arena).ok);
        assert(storage.presignGet("examplebucket", "test.txt", 604_801, now, arena).error.code == Status
                .invalidArgument);
        assert(storage.presignGet("examplebucket", "test.txt", 0, now, arena).error.code == Status.invalidArgument);
    }

    @("presign_bounds: temporary credentials bound expiry and the URL never carries the secret")
    unittest
    {
        const now = unixSeconds();
        auto storage = openOffline("http://127.0.0.1:9", Credentials("temporary-access",
                "temporary-secret", "temporary-token", now + 600));
        scope (exit)
            assert(storage.close().code == Status.ok);
        ubyte[4096] backing;
        auto arena = RequestArena(backing[]);
        assert(storage.presignGet("bucket", "key", 601, now, arena).error.code == Status.permissionDenied);
        assert(storage.presignGet("bucket", "key", 300, now + 301, arena).error.code == Status.permissionDenied);
        const signed = storage.presignGet("bucket", "key", 300, now, arena);
        assert(signed.ok, signed.error.message);
        assert(arena.read(signed.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
                const url = cast(const(char)[]) bytes;
                assert(contains(url, "X-Amz-Security-Token=temporary-token"));
                assert(contains(url, "X-Amz-Expires=300&"));
                assert(!contains(url, "temporary-secret"));
            }) == Status.ok);
    }
}

@("multipart_limits: part size below 5 MiB, above 5 GiB or beyond the buffer budget is rejected at open")
unittest
{
    StorageOptions options;
    options.endpoint = "http://127.0.0.1:9";
    options.pathStyle = true;
    options.allowLoopbackCleartext = true;
    CredentialProvider provider = (ref Context) @safe nothrow => Result!Credentials(Credentials("access", "secret"));
    foreach (bytes; [5UL * 1024 * 1024 - 1, 5UL * 1024 * 1024 * 1024 + 1, 9UL * 1024 * 1024])
    {
        StorageOptions invalid = options;
        invalid.partBytes = cast(size_t) bytes;
        ObjectStorage storage;
        assert(storage.open(invalid, provider).code == Status.invalidArgument);
    }
    StorageOptions parts = options;
    parts.concurrentParts = 5;
    ObjectStorage tooMany;
    assert(tooMany.open(parts, provider).code == Status.invalidArgument);

    StorageOptions boundary = options;
    boundary.partBytes = 5 * 1024 * 1024;
    ObjectStorage storage;
    assert(storage.open(boundary, provider).code == Status.ok);
    assert(storage.close().code == Status.ok);
}

@("multipart_limits: part numbers outside 1..10000 and empty upload IDs are rejected before transfer")
unittest
{
    import flint.engine.storage.endpoint : Endpoint;
    import flint.engine.storage.parts : Part, PartPhase, maximumParts;

    StorageOptions options;
    options.partBytes = 5 * 1024 * 1024;
    auto part = new Part(Endpoint.init, options, new CredentialStore(null));
    Context context;
    part.acquire(1);
    part.used = 1;
    foreach (number; [0U, maximumParts + 1])
    {
        assert(part.queue("bucket", "key", "upload", number, context).code == Status.invalidArgument);
        assert(part.state == PartPhase.filling);
    }
    assert(part.queue("bucket", "key", "", 1, context).code == Status.invalidArgument);
    assert(part.queue("bucket", "key", "upload", maximumParts, context).code == Status.ok);
    assert(part.state == PartPhase.queued);
}

private string tagged(string prefix, uint generation) pure nothrow
{
    char[10] digits;
    size_t start = digits.length;
    do
    {
        digits[--start] = cast(char)('0' + generation % 10);
        generation /= 10;
    }
    while (generation != 0);
    return prefix ~ digits[start .. $].idup;
}

@("credential_rotation: concurrent signers observe whole snapshots and never an expired session")
@system unittest
{
    import core.thread.osthread : Thread;

    shared uint generation;
    auto credentials = new CredentialStore((ref Context) @safe nothrow{
        const next = atomicOp!"+="(generation, 1u);
        // Three seconds of life makes the worker refresh about once per second.
        return Result!Credentials(Credentials(tagged("access-", next), tagged("secret-", next),
            tagged("token-", next), unixSeconds() + 3));
    });
    assert(credentials.start().code == Status.ok);
    scope (exit)
    {
        while (credentials.close().code != Status.ok)
            assert(waitUntil(Deadline.afterMillis(5)).code == Status.ok);
    }
    shared uint observed;
    void read()
    {
        const deadline = Deadline.afterMillis(2_600).monotonicNanoseconds;
        string previous;
        while (Deadline.afterMillis(0).monotonicNanoseconds < deadline)
        {
            const now = unixSeconds();
            const snapshot = credentials.take(now);
            assert(snapshot.ok, snapshot.error.message);
            const value = snapshot.value.value;
            assert(value.expiresAtUnixSeconds > now);
            const suffix = value.accessKeyId["access-".length .. $];
            assert(value.secretAccessKey == "secret-" ~ suffix && value.sessionToken == "token-" ~ suffix);
            if (value.accessKeyId != previous)
            {
                atomicOp!"+="(observed, 1u);
                previous = value.accessKeyId;
            }
        }
    }

    Thread[4] readers;
    foreach (ref reader; readers)
        reader = new Thread(&read).start();
    foreach (reader; readers)
        reader.join();
    // Every reader saw the first snapshot and at least one rotation.
    assert(observed >= 2 * readers.length);
}
