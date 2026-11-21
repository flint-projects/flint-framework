/// Public synchronous digest operations and cooperatively awaited password work.
module flint.security.crypto;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context, Deadline;
import flint.conc.wait : waitUntil;
import flint.security.ffi.crypto : abandonPassword, digest, mac, submitPassword, takePassword, wipe;

@safe:

/// Compute SHA-256 through the pinned native provider.
Error sha256(scope const(ubyte)[] input, ref ubyte[32] output) nothrow @nogc
{
    return digest(input, output);
}

/// Compute HMAC-SHA-256 through the pinned native provider.
Error hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] input, ref ubyte[32] output) nothrow @nogc
{
    return mac(key, input, output);
}

/// Erase caller-owned mutable secret storage through the selected native provider.
void eraseSecret(scope ubyte[] storage) nothrow @nogc
{
    wipe(storage);
}

/// Produce a complete interactive-cost Argon2id verifier as caller-owned bytes.
Result!Buffer hashPassword(scope const(ubyte)[] input, ref scope RequestArena arena, ref Context context) nothrow @nogc
{
    ubyte[128] output;
    scope (exit)
        wipe(output[]);
    size_t length;
    const status = passwordWork(false, input, null, output[], length, context);
    if (status.code != Status.ok)
        return Result!Buffer(Buffer.init, status);
    return arena.copyIn(output[0 .. length]);
}

/// Check a bounded Argon2id verifier. A wrong password returns a successful false result.
Result!bool verifyPassword(scope const(ubyte)[] input, scope const(char)[] encoded, ref Context context) nothrow @nogc
{
    ubyte[1] output;
    scope (exit)
        wipe(output[]);
    size_t length;
    const status = passwordWork(true, input, encoded, output[], length, context);
    const matched = status.code == Status.ok && length == 1 && output[0] == 1;
    return Result!bool(matched, status);
}

private Error passwordWork(bool verify, scope const(ubyte)[] password, scope const(char)[] encoded,
        scope ubyte[] output, out size_t length, ref Context context) nothrow @nogc
{
    const allowed = context.check();
    if (allowed.code != Status.ok)
        return allowed;
    const job = submitPassword(verify, password, encoded);
    if (!job.ok())
        return job.error;
    while (true)
    {
        const valid = context.check();
        if (valid.code != Status.ok)
        {
            abandonPassword(job.value);
            return valid;
        }

        const result = takePassword(job.value, output, length);
        if (!result.waiting)
            return result.error;
        const waited = waitUntil(Deadline.afterMillis(1));
        if (waited.code != Status.ok)
        {
            abandonPassword(job.value);
            return waited;
        }
    }
}
