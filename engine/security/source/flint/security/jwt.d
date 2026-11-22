/// Configured JWT verification over atomically published JWKS snapshots.
module flint.security.jwt;

import core.atomic : atomicLoad, atomicStore, cas, pause;
import flint.arena : Error, RequestArena, Result, Status;
import flint.conc : Background, CancelSource, Context, Deadline, startBackground;
import flint.conc.wait : waitUntil;
import flint.http : ClientOptions, HttpClient, HttpRequest;
import flint.security.base64url : decodeUrl64;
import flint.security.ffi.crypto : Key, beginRefresh, cryptoReady, registerIssuer, retireIssuer, wipe;
import flint.security.jwks : KeySet;
import flint.security.jwt_parse : denied, parseClaims, parseHeader, tokenLimit;
import flint.security.origin : sameAscii, validJwksUrl;
import flint.security.sys.worker : Wake;
import flint.security.types : JwtAlgorithm, JwtPolicy, Principal;

@safe:

private enum maxJwks = 1_048_576;
private enum maxIssuer = 1024;
private enum second = 1_000_000_000L;

version (unittest)
{
    private shared long clockShift;

    package(flint.security) void setJwksTestClockShift(long nanoseconds) nothrow @nogc
    {
        atomicStore(clockShift, nanoseconds);
    }

    package(flint.security) ulong completedJwksRefreshes(ref JwtVerifier verifier) nothrow @nogc
    {
        if (verifier.state is null)
            return 0;
        verifier.state.gate.lock();
        scope (exit)
            verifier.state.gate.unlock();
        return verifier.state.completed;
    }
}

private long monotonic() nothrow @nogc
{
    long now = Deadline.afterMillis(0).monotonicNanoseconds;
    version (unittest)
    {
        const offset = atomicLoad(clockShift);
        if (offset > 0)
            now = now > long.max - offset ? long.max : now + offset;
    }
    return now;
}

private struct Gate
{
    private shared bool held;

    void lock() nothrow @nogc
    {
        while (!cas(&held, false, true))
            pause();
    }

    void unlock() nothrow @nogc
    {
        atomicStore(held, false);
    }
}

/// A shared verifier handle. Close it to retire its private refresh owner and key snapshots.
struct JwtVerifier
{
    private Verifier state;

    /// Validate and snapshot policy. Refresh is explicit or triggered by a verified-format key lookup miss.
    Error open(scope const ref JwtPolicy policy, string jwksUrl)
    {
        if (state !is null)
            return Error(Status.conflict, "JWT verifier already opened");
        const validated = validate(policy, jwksUrl);
        if (!validated.ok())
            return validated.error;
        const crypto = cryptoReady();
        if (crypto.code != Status.ok)
            return crypto;

        auto prepared = new Verifier(policy, jwksUrl, validated.value);
        const opened = prepared.prepare(policy.jwksCaBundle);
        if (opened.code != Status.ok)
            return opened;
        const started = startBackground(&prepared.run, prepared.worker);
        if (started.code != Status.ok)
        {
            prepared.cleanup();
            return Error(Status.unavailable, "unable to start the JWKS worker");
        }
        state = prepared;
        return Error.init;
    }

    /// Verify one compact token, optionally prefixed with Bearer, using cached public keys only.
    Result!Principal verify(scope const(char)[] bearer, long nowUnixSeconds, ref scope RequestArena arena) nothrow @nogc
    {
        if (state is null)
            return failure();
        if (bearer.length >= 7 && sameAscii(bearer[0 .. 7], "Bearer "))
            bearer = bearer[7 .. $];
        if (!bearer.length || bearer.length > state.tokenBytes)
            return failure();
        return state.verify(cast(const(ubyte)[]) bearer, nowUnixSeconds, arena);
    }

    /// Join one bounded refresh. Callers whose context expires leave the shared refresh running.
    Error refresh(ref Context context) nothrow @nogc
    {
        if (state is null)
            return Error(Status.unavailable, "JWT verifier closed");
        const valid = context.check();
        if (valid.code != Status.ok)
            return valid;
        const flight = state.requestRefresh();
        return flight.ok() ? state.await(flight.value, context) : flight.error;
    }

    /// Cancel refresh and wait for the owner to retire its transport and keys.
    Error close() nothrow @nogc
    {
        if (state is null)
            return Error.init;
        state.requestClose();
        while (!atomicLoad(state.stopped))
        {
            const waited = waitUntil(Deadline.afterMillis(1));
            if (waited.code != Status.ok)
                return waited;
        }
        state.worker.join();
        state = null;
        return Error.init;
    }
}

private Result!uint validate(scope const ref JwtPolicy policy, scope const(char)[] url) nothrow @nogc
{
    if (!policy.issuer.length || policy.issuer.length > maxIssuer || !policy.audience.length
            || policy.audience.length > maxIssuer || !policy.algorithms.length
            || policy.algorithms.length > 3 || policy.clockSkewSeconds < 0 || policy.clockSkewSeconds > 300
            || !policy.maxTokenBytes || policy.maxTokenBytes > tokenLimit || !policy.jwksTtlSeconds
            || policy.jwksTtlSeconds > 86_400 || !validJwksUrl(url))
        return Result!uint(0, Error(Status.invalidArgument, "invalid JWT or HTTPS JWKS policy"));
    uint mask;
    foreach (algorithm; policy.algorithms)
    {
        if (algorithm > JwtAlgorithm.max || (mask & (1U << cast(uint) algorithm)))
            return Result!uint(0, Error(Status.invalidArgument, "invalid JWT algorithm allowlist"));
        mask |= 1U << cast(uint) algorithm;
    }
    return Result!uint(mask);
}

private struct Pieces
{
    size_t headerEnd;
    size_t signedEnd;
}

private bool split(scope const(ubyte)[] token, out Pieces result) pure nothrow @nogc
{
    foreach (index, item; token)
    {
        if (item != '.')
            continue;
        if (!index || result.signedEnd)
            return false;
        if (!result.headerEnd)
            result.headerEnd = index;
        else
            result.signedEnd = index;
    }
    return result.headerEnd + 1 < result.signedEnd && result.signedEnd + 1 < token.length;
}

private Result!Principal failure() pure nothrow @nogc
{
    return Result!Principal(Principal.init, denied());
}

private struct Lookup
{
    Result!Key key;
    bool renew;
}

private struct Receipt
{
    ulong ticket;
    Error outcome;
}

private final class Verifier
{
    private Gate gate;
    private Wake wake;
    private CancelSource cancel;
    private HttpClient client;
    private HttpRequest request;
    private ubyte[] responseMemory;
    private KeySet[2] snapshots;
    private uint current;
    private ulong requested;
    private ulong completed;
    private Receipt[4] receipts;
    private uint limiter;
    private long renewal;
    private long renewAt;
    private bool closing;
    shared bool stopped;
    Background worker;

    private string issuer;
    private string audience;
    private uint algorithms;
    private ulong skew;
    private uint ttl;
    private bool requireExpiry;
    uint tokenBytes;

    this(scope const ref JwtPolicy policy, string url, uint algorithms)
    {
        issuer = policy.issuer.idup;
        audience = policy.audience.idup;
        this.algorithms = algorithms;
        skew = cast(ulong) policy.clockSkewSeconds;
        ttl = policy.jwksTtlSeconds;
        // Renew a still-valid snapshot during its final half lifetime, at most one minute early.
        renewal = ttl * (second / 2) < 60 * second ? ttl * (second / 2) : 60 * second;
        requireExpiry = policy.requireExpiry;
        tokenBytes = policy.maxTokenBytes;
        request.url = url;
        responseMemory = new ubyte[maxJwks + 65_536];
    }

    Error prepare(scope const(char)[] ca)
    {
        auto source = CancelSource.create(Context.init, Deadline.none());
        if (!source.ok())
            return source.error;
        import core.lifetime : move;

        move(source.value, cancel);
        const registered = registerIssuer(issuer, monotonic());
        if (!registered.ok())
        {
            cancel.close();
            return registered.error;
        }
        limiter = registered.value;

        ClientOptions options;
        options.maxConnections = 1;
        options.maxConnectionsPerOrigin = 1;
        options.maxResponseBytes = maxJwks;
        options.caBundle = ca.idup;
        auto ready = client.open(options);
        if (ready.code == Status.ok)
            ready = wake.open();
        if (ready.code != Status.ok)
            cleanup();
        return ready;
    }

    Result!ulong requestRefresh() nothrow @nogc
    {
        gate.lock();
        scope (exit)
            gate.unlock();
        if (closing)
            return Result!ulong(0, Error(Status.cancelled, "JWKS worker closed"));
        if (requested != completed)
            return Result!ulong(requested);
        if (requested == ulong.max)
            return Result!ulong(0, Error(Status.resourceExhausted, "JWKS refresh identities exhausted"));
        const allowed = beginRefresh(limiter, monotonic());
        if (allowed.code != Status.ok)
            return Result!ulong(0, allowed);
        ++requested;
        wake.signal();
        return Result!ulong(requested);
    }

    Error await(ulong ticket, ref Context context) nothrow @nogc
    {
        while (true)
        {
            const valid = context.check();
            if (valid.code != Status.ok)
                return valid;
            gate.lock();
            const receipt = receipts[ticket % receipts.length];
            const closed = closing;
            const finished = completed;
            gate.unlock();
            if (receipt.ticket == ticket)
                return receipt.outcome;
            if (closed)
                return Error(Status.cancelled, "JWKS worker closed");
            if (ticket <= finished)
                return Error(Status.notFound, "JWKS refresh receipt expired");
            const waited = waitUntil(Deadline.afterMillis(1));
            if (waited.code != Status.ok)
                return waited;
        }
    }

    void requestClose() nothrow @nogc
    {
        gate.lock();
        if (!closing)
        {
            closing = true;
            cancel.cancel();
            wake.signal();
        }
        gate.unlock();
    }

    void run() nothrow @nogc
    {
        scope (exit)
            cleanup();
        while (true)
        {
            gate.lock();
            const closed = closing;
            const ticket = requested;
            const pending = requested != completed;
            const next = 1 - current;
            gate.unlock();
            if (closed)
                return;
            if (!pending)
            {
                wake.listen();
                continue;
            }
            const received = fetch(snapshots[next]);
            publish(ticket, next, received);
        }
    }

    private Error fetch(ref KeySet draft) nothrow @nogc
    {
        auto deadline = CancelSource.create(cancel.context(), Deadline.afterMillis(10_000));
        if (!deadline.ok())
            return deadline.error;
        auto context = deadline.value.context();
        auto arena = RequestArena(responseMemory);
        auto reply = client.send(request, arena, context);
        if (!reply.ok())
            return reply.error;
        if (reply.value.status != 200)
            return Error(Status.ioError, "JWKS origin did not return a successful response");
        Error decoded;
        const read = arena.read(reply.value.body, (scope const(ubyte)[] json) {
            decoded = draft.parse(json, algorithms);
        });
        if (read != Status.ok)
            return Error(read, "JWKS response could not be read");
        return decoded;
    }

    private void publish(ulong ticket, uint next, Error completedFetch) nothrow @nogc
    {
        gate.lock();
        const accepted = !closing && completedFetch.code == Status.ok;
        const old = current;
        if (accepted)
        {
            const refresh = monotonic();
            const duration = ttl * second;
            snapshots[next].expiry = refresh > long.max - duration ? long.max : refresh + duration;
            current = next;
        }
        receipts[ticket % receipts.length] = Receipt(ticket, completedFetch);
        completed = ticket;
        retireIssuer(limiter, true);
        gate.unlock();
        snapshots[accepted ? old : next].clear();
    }

    void cleanup() nothrow @nogc
    {
        const stoppedClient = client.close();
        assert(stoppedClient.code == Status.ok);
        gate.lock();
        closing = true;
        if (requested != completed)
            retireIssuer(limiter, true);
        foreach (ref snapshot; snapshots)
            snapshot.clear();
        retireIssuer(limiter, false);
        limiter = 0;
        wake.release();
        cancel.close();
        atomicStore(stopped, true);
        gate.unlock();
    }

    private Lookup findKey(scope const(ubyte)[] kid, JwtAlgorithm algorithm) nothrow @nogc
    {
        gate.lock();
        scope (exit)
            gate.unlock();
        const now = monotonic();
        const expiry = snapshots[current].expiry;
        if (closing || expiry <= now)
            return Lookup(Result!Key(Key.init, denied()));
        bool renew;
        if (requested == completed && now >= renewAt && expiry - now <= renewal)
        {
            // Attempt at most once per second; the native issuer limiter still bounds fetches.
            renewAt = now > long.max - second ? long.max : now + second;
            renew = true;
        }
        return Lookup(snapshots[current].retain(kid, algorithm), renew);
    }

    Result!Principal verify(scope const(ubyte)[] token, long now, ref scope RequestArena output) nothrow @nogc
    {
        Pieces spans;
        if (!split(token, spans))
            return failure();
        ubyte[tokenLimit] decoded;
        scope (exit)
            wipe(decoded[]);
        size_t header, payload, signature;
        if (!decodeUrl64(token[0 .. spans.headerEnd], decoded[], header))
            return failure();
        if (!decodeUrl64(token[spans.headerEnd + 1 .. spans.signedEnd], decoded[header .. $], payload))
            return failure();
        const signedBytes = header + payload;
        if (!decodeUrl64(token[spans.signedEnd + 1 .. $], decoded[signedBytes .. $], signature))
            return failure();

        ubyte[2048] headerScratch;
        scope (exit)
            wipe(headerScratch[]);
        auto scratch = RequestArena(headerScratch[]);
        const claim = parseHeader(decoded[0 .. header], scratch);
        if (!claim.ok() || !(algorithms & (1U << cast(uint) claim.value.algorithm)))
            return failure();
        auto selected = findKey(claim.value.kid[0 .. claim.value.kidLength], claim.value.algorithm);
        if (!selected.key.ok() || selected.renew)
            requestRefresh();
        if (!selected.key.ok())
            return failure();
        scope (exit)
            selected.key.value.release();
        const verified = selected.key.value.verify(claim.value.algorithm,
                token[0 .. spans.signedEnd], decoded[signedBytes .. signedBytes + signature]);
        if (verified.code != Status.ok)
            return failure();
        return parseClaims(decoded[header .. signedBytes], issuer, audience, now, skew, requireExpiry, output);
    }
}
