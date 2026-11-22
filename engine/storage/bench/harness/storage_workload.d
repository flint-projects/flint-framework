module storage_workload;

import core.memory : GC;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;
import core.stdc.string : strlen;
import core.time : MonoTime;

@safe:

/// The shared S3 fixture bucket.
enum bucket = "flint-test";
/// The shared fixture object key.
enum key = "storage-probe";
/// The payload reservation for each transfer.
enum partBytes = 8 * 1024 * 1024;
/// Four simultaneously owned part buffers.
enum parallelParts = 4;
/// Generate and consume payload in one fixed-size stripe at a time.
enum stripeBytes = 64 * 1024;
/// A complete upload contains 128 full parts.
enum parts = 128;
/// The downloaded payload must have this exact length.
enum objectBytes = cast(ulong) parts * partBytes;
/// Credentials for the disposable loopback peer only.
enum access = "fixture-access";
/// Local-only signing secret.
enum secret = "fixture-secret";
/// Local-only temporary session token.
enum token = "fixture-session";
/// The loopback signing region.
enum region = "us-east-1";
/// Content type common to the object and multipart parts.
enum objectType = "application/octet-stream";

/// Check an invariant that remains enabled in release builds.
void require(bool condition, string message) pure nothrow @nogc
{
    if (!condition)
        assert(0, message);
}

/// Get the fixture endpoint. The producer never accepts credentials from a caller.
string address()
{
    const endpoint = variable("FLINT_STORAGE_BENCH_URL");
    enum prefix = "http://127.0.0.1:";
    require(endpoint.length > prefix.length && endpoint[0 .. prefix.length] == prefix,
            "start the loopback Storage benchmark peer first");
    foreach (digit; endpoint[prefix.length .. $])
        require(digit >= '0' && digit <= '9', "invalid loopback benchmark port");
    return endpoint;
}

// SAFETY: getenv returns null or a NUL-terminated environment string, copied before returning;
// the name is a NUL-terminated literal.
private string variable(scope const(char)* name) @trusted
{
    const value = getenv(name);
    return value is null ? "" : value[0 .. strlen(value)].idup;
}

/// Fill the canonical byte stripe for an ordered multipart part.
void stripe(uint part, scope ubyte[] output) pure nothrow @nogc
{
    require(output.length == stripeBytes && part >= 1 && part <= parts, "invalid fixture stripe");
    output[0 .. pattern.length] = pattern[];
    repeatPrefix(output, pattern.length);
    output[0] = cast(ubyte) part;
}

/// Feed a complete part to either sender using the same generator.
void fillPart(uint part, scope ubyte[] output) pure nothrow @nogc
{
    require(output.length == partBytes, "invalid fixture part buffer");
    stripe(part, output[0 .. stripeBytes]);
    repeatPrefix(output, stripeBytes);
}

private void repeatPrefix(scope ubyte[] output, size_t filled) pure nothrow @nogc
{
    while (filled < output.length)
    {
        output[filled .. 2 * filled] = output[0 .. filled];
        filled *= 2;
    }
}

private static immutable pattern = makePattern();

private ubyte[256] makePattern() pure
{
    ubyte[256] bytes;
    foreach (index, ref value; bytes)
        value = cast(ubyte) index;
    return bytes;
}

private struct NativeDigest;
private struct Algorithm;

extern (C) private @system nothrow @nogc
{
    pragma(mangle, "EVP_MD_CTX_new") NativeDigest* newDigest();
    pragma(mangle, "EVP_MD_CTX_free") void freeDigest(NativeDigest*);
    pragma(mangle, "EVP_sha256") const(Algorithm)* sha256Algorithm();
    pragma(mangle, "EVP_DigestInit_ex") int initDigest(NativeDigest*, const(Algorithm)*, void*);
    pragma(mangle, "EVP_DigestUpdate") int updateDigest(NativeDigest*, const(void)*, size_t);
    pragma(mangle, "EVP_DigestFinal_ex") int finishDigest(NativeDigest*, ubyte*, uint*);
}

/// SHA-256 over bytes actually delivered by the native providers.
struct Checksum
{
    private NativeDigest* state;
    /// Total bytes forwarded to OpenSSL.
    ulong bytes;

    @disable this(this);

    // SAFETY: This lexical owner initializes a single opaque OpenSSL context without retaining any D span.
    /// Allocate one digest context.
    void open() @trusted nothrow @nogc
    {
        require(state is null, "checksum already open");
        state = newDigest();
        require(state !is null && initDigest(state, sha256Algorithm(), null) == 1, "cannot start SHA-256");
    }

    // SAFETY: OpenSSL synchronously consumes the borrowed span using precisely its provided length.
    /// Consume the next part of the actual received body.
    void add(scope const(ubyte)[] input) @trusted nothrow @nogc
    {
        require(state !is null && input.length <= objectBytes - bytes, "fixture body exceeds its budget");
        require(updateDigest(state, input.ptr, input.length) == 1, "cannot hash payload");
        bytes += input.length;
    }

    // SAFETY: This context is owned by the caller and the 32-byte destination lasts through the native call.
    /// Finish once and release the native context.
    ubyte[32] finish() @trusted nothrow @nogc
    {
        ubyte[32] digest;
        uint size;
        require(state !is null && finishDigest(state, digest.ptr, &size) == 1 && size == 32, "cannot finish SHA-256");
        freeDigest(state);
        state = null;
        return digest;
    }
}

/// Produce a canonical lowercase hex digest on the stack.
char[64] hex(ubyte[32] digest) pure nothrow @nogc
{
    enum digits = "0123456789abcdef";
    char[64] text;
    foreach (index, byte_; digest)
    {
        text[2 * index] = digits[byte_ >> 4];
        text[2 * index + 1] = digits[byte_ & 0x0f];
    }
    return text;
}

/// Verify the expected digest and report measurable bytes and timings.
void report(ref Checksum body, MonoTime started, MonoTime uploaded, MonoTime downloaded, ulong before)
{
    const allocated = GC.stats().allocatedInCurrentThread - before;
    const digest = hex(body.finish());
    require(body.bytes == objectBytes, "incorrect download size");
    require(digest[] == "a1ff2f9757141e98267eb65c3f85fb88974d7cf35ac444c10453dae607321d63",
            "download checksum differs from the fixture");
    print(body.bytes, digest[], (uploaded - started).total!"msecs", (downloaded - uploaded).total!"msecs", allocated);
}

// SAFETY: Fixed NUL-terminated literal formats; the digest is printed with its explicit length and
// every scalar matches its conversion.
private void print(ulong received, scope const(char)[] digest, long upload, long download, ulong allocated) @trusted
{
    printf("storage uploaded=%llu downloaded=%llu parts=%d part_bytes=%d buffers=%d sha256=%.*s\n",
            objectBytes, received, parts, partBytes, parallelParts, cast(int) digest.length, digest.ptr);
    printf("storage upload_ms=%lld download_ms=%lld d_gc_bytes=%llu\n", upload, download, allocated);
}
