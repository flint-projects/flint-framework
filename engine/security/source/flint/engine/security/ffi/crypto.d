/// Length-delimited calls into the native OpenSSL and libsodium boundary.
module flint.engine.security.ffi.crypto;

import flint.arena : Error, Result, Status;
import flint.engine.security.types : JwtAlgorithm;

@safe:
nothrow @nogc:

private struct NativeKey;

extern (C) private @system
{
    int flint_crypto_initialize();
    int flint_sodium_initialize();
    int flint_password_workers();
    void flint_crypto_wipe(void*, size_t);
    void flint_sodium_wipe(void*, size_t);
    int flint_sha256(const(ubyte)*, size_t, ubyte*);
    int flint_hmac_sha256(const(ubyte)*, size_t, const(ubyte)*, size_t, ubyte*);
    int flint_jwk_create(uint, const(ubyte)*, size_t, const(ubyte)*, size_t, NativeKey**);
    int flint_jwk_retain(NativeKey*);
    void flint_jwk_release(NativeKey*);
    int flint_jwk_verify(const(NativeKey)*, uint, const(ubyte)*, size_t, const(ubyte)*, size_t);
    int flint_jwks_rate_register(const(ubyte)*, size_t, long, uint*);
    int flint_jwks_rate_begin(uint, long);
    void flint_jwks_rate_end(uint);
    void flint_jwks_rate_release(uint);
    int flint_password_submit(uint, const(ubyte)*, size_t, const(char)*, size_t, ulong*);
    int flint_password_take(ulong, ubyte*, size_t, size_t*);
    int flint_password_abandon(ulong);
}

version (linux)
{
    version (FlintNativeOpenssl) version = FlintSecurityOpenSSL;
    version (FlintNativeLibsodium) version = FlintSecuritySodium;
}
else version (OSX)
{
    version (FlintNativeOpenssl) version = FlintSecurityOpenSSL; // ADR-024
    version (FlintNativeLibsodium) version = FlintSecuritySodium;
}
else version (Windows)
{
    version (FlintNativeOpenssl) version = FlintSecurityOpenSSL; // ADR-026
    version (FlintNativeLibsodium) version = FlintSecuritySodium;
}
version (FlintSecurityOpenSSL)
    private enum hasCrypto = true;
else
    private enum hasCrypto = false;
version (FlintSecuritySodium)
    private enum hasPasswords = true;
else
    private enum hasPasswords = false;

private shared Status cryptoStatus = Status.unsupported;
private shared Status passwordStatus = Status.unsupported;

// SAFETY: Typed callers pass existing native handles or valid sized input/output storage.
// Crypto never retains these buffers. Password submission copies them into native worker slots.
private int invoke(bool linked, alias fn, Args...)(scope Args args) @trusted nothrow @nogc
{
    static if (linked)
        return fn(args);
    else
        return Status.unsupported;
}

shared static this()
{
    cryptoStatus = cast(Status) invoke!(hasCrypto, flint_crypto_initialize)();
    passwordStatus = cast(Status) invoke!(hasPasswords, flint_sodium_initialize)();
    if (passwordStatus == Status.ok)
        passwordStatus = cast(Status) invoke!(hasPasswords, flint_password_workers)();
}

package(flint.engine.security) Error cryptoReady()
{
    return outcome(cryptoStatus);
}

private Error outcome(int status) pure
{
    static immutable string[] messages = [
        null, // ok
        "invalid security input", // invalidArgument
        "native security allocation failed", // outOfMemory
        "security operation cancelled", // cancelled
        "security operation deadline elapsed", // timedOut
        "security operation identity expired", // notFound
        "security operation conflicts with its state", // conflict
        "native security operation failed", // ioError
        "security provider or refresh unavailable", // unavailable
        "pinned security provider unavailable", // unsupported
        "security policy denied the operation", // permissionDenied
        "security resource limit exceeded", // resourceExhausted
    ];
    static assert(messages.length == Status.max + 1);
    return Error(cast(Status) status, messages[status]);
}

package(flint.engine.security) Error digest(scope const(ubyte)[] input, ref ubyte[32] output)
{
    if (cryptoStatus != Status.ok)
    {
        output[] = 0;
        return outcome(cryptoStatus);
    }
    const bytes = input.length ? &input[0] : null;
    return outcome(invoke!(hasCrypto, flint_sha256)(bytes, input.length, &output[0]));
}

package(flint.engine.security) Error mac(scope const(ubyte)[] key, scope const(ubyte)[] input, ref ubyte[32] output)
{
    if (cryptoStatus != Status.ok)
    {
        output[] = 0;
        return outcome(cryptoStatus);
    }
    const keyBytes = key.length ? &key[0] : null;
    const inputBytes = input.length ? &input[0] : null;
    return outcome(invoke!(hasCrypto, flint_hmac_sha256)(keyBytes, key.length, inputBytes, input.length, &output[0]));
}

// SAFETY: The caller owns this valid writable span for immediate erasure. Neither provider
// retains it, calls D, or throws an exception.
package(flint.engine.security) void wipe(scope ubyte[] bytes) @trusted nothrow @nogc
{
    if (!bytes.length)
        return;
    static if (hasPasswords)
        flint_sodium_wipe(&bytes[0], bytes.length);
    else static if (hasCrypto)
        flint_crypto_wipe(&bytes[0], bytes.length);
    else
        bytes[] = 0;
}

package(flint.engine.security) struct Key
{
    private NativeKey* native;

    static Result!Key create(JwtAlgorithm alg, scope const(ubyte)[] first, scope const(ubyte)[] second) nothrow @nogc
    {
        Key key;
        const primary = first.length ? &first[0] : null;
        const secondary = second.length ? &second[0] : null;
        const result = invoke!(hasCrypto, flint_jwk_create)(cast(uint) alg, primary, first.length,
                secondary, second.length, &key.native);
        return Result!Key(key, outcome(result));
    }

    Error retain() nothrow @nogc
    {
        return outcome(invoke!(hasCrypto, flint_jwk_retain)(native));
    }

    Error verify(JwtAlgorithm algorithm, scope const(ubyte)[] input, scope const(ubyte)[] signature) const nothrow @nogc
    {
        return outcome(invoke!(hasCrypto, flint_jwk_verify)(native, cast(uint) algorithm,
                input.length ? &input[0] : null, input.length, signature.length
                ? &signature[0] : null, signature.length));
    }

    // SAFETY: Each owner calls release once, after its last synchronous use. The C reference
    // count is atomic, and other owners retain independent references.
    void release() @trusted nothrow @nogc
    {
        static if (hasCrypto)
            flint_jwk_release(native);
        native = null;
    }
}

package(flint.engine.security) Result!uint registerIssuer(scope const(char)[] issuer, long now)
{
    uint index;
    const code = invoke!(hasCrypto, flint_jwks_rate_register)(issuer.length
            ? cast(const(ubyte)*)&issuer[0] : null, issuer.length, now, &index);
    return Result!uint(index, outcome(code));
}

package(flint.engine.security) Error beginRefresh(uint index, long now)
{
    return outcome(invoke!(hasCrypto, flint_jwks_rate_begin)(index, now));
}

// SAFETY: Each registration and started refresh retires once. The C issuer slab synchronizes
// its scalar indices and takes no borrowed memory or callbacks.
package(flint.engine.security) void retireIssuer(uint index, bool refresh) @trusted nothrow @nogc
{
    static if (hasCrypto)
    {
        if (refresh)
            flint_jwks_rate_end(index);
        else
            flint_jwks_rate_release(index);
    }
}

package(flint.engine.security) Result!ulong submitPassword(bool verify, scope const(ubyte)[] password,
        scope const(char)[] encoded)
{
    if (passwordStatus != Status.ok)
        return Result!ulong(0, outcome(passwordStatus));
    ulong ticket;
    const input = password.length ? &password[0] : null;
    const verifier = encoded.length ? &encoded[0] : null;
    const result = invoke!(hasPasswords, flint_password_submit)(cast(uint) verify, input,
            password.length, verifier, encoded.length, &ticket);
    return Result!ulong(ticket, outcome(result));
}

package(flint.engine.security) struct PasswordReceipt
{
    Error error;
    bool waiting;
}

package(flint.engine.security) PasswordReceipt takePassword(ulong ticket, scope ubyte[] output, out size_t length)
{
    const status = invoke!(hasPasswords, flint_password_take)(ticket, output.length
            ? &output[0] : null, output.length, &length);
    return status == 12 ? PasswordReceipt(Error.init, true) : PasswordReceipt(outcome(status), false);
}

package(flint.engine.security) void abandonPassword(ulong ticket)
{
    const status = invoke!(hasPasswords, flint_password_abandon)(ticket);
    assert(status == Status.ok || status == Status.notFound);
}
