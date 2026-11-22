module flint.security.security_behavior_test;

import flint.arena : Error, RequestArena, Status;
import flint.conc : Context;
import flint.security : CorsPolicy, JwtAlgorithm, JwtPolicy, JwtVerifier, PreAuthorize, Principal,
    RegisteredPolicy, authorize, hasRole, originAllowed, preflight, rolesAllowed;

@safe:

private Error registered(scope const ref Principal principal, ref Context) nothrow @nogc
{
    return principal.expiresAtUnixSeconds > 0 ? Error.init : Error(Status.permissionDenied);
}

unittest
{
    CorsPolicy policy;
    policy.origins = ["https://valid.example", "http://[::1]:8080"];
    policy.methods = ["GET", "POST"];
    policy.headers = ["x-test", "content-type"];
    policy.credentials = true;
    assert(originAllowed(policy, "HTTPS://VALID.EXAMPLE:443"));
    assert(originAllowed(policy, "http://[0:0:0:0:0:0:0:1]:8080"));
    assert(!originAllowed(policy, "http://[::1\0extra]:8080"));
    foreach (unsafe; [
        "null", "https://valid.example.attacker", "https://valid.example@other",
        "https://valid.example/path", "http://valid.example", "https://valid.example:0444"
    ])
        assert(!originAllowed(policy, unsafe));

    const allowed = preflight(policy, "https://valid.example", "POST", "Content-Type, X-TEST");
    assert(allowed.allowed && allowed.credentials && allowed.maxAgeSeconds == 600);
    assert(allowed.vary == "Origin, Access-Control-Request-Method, Access-Control-Request-Headers");
    assert(!preflight(policy, "https://valid.example", "PATCH", "").allowed);
    assert(!preflight(policy, "https://valid.example", "GET", "x-unlisted").allowed);
    assert(!preflight(policy, "https://valid.example", "GET", "x-test,,content-type").allowed);
    policy.origins ~= "*";
    assert(!originAllowed(policy, "https://valid.example"));
    policy.credentials = false;
    assert(originAllowed(policy, "https://another.example"));
    assert(!originAllowed(policy, "null"));

    JwtVerifier verifier;
    JwtPolicy config;
    assert(verifier.open(config, "https://operator.example/keys").code == Status.invalidArgument);
    config.issuer = "issuer";
    config.audience = "audience";
    config.algorithms = [JwtAlgorithm.rs256];
    assert(verifier.open(config, "http://operator.example/keys").code == Status.invalidArgument);
    assert(verifier.open(config, "https://operator.example@other/keys").code == Status.invalidArgument);
    config.algorithms ~= JwtAlgorithm.rs256;
    assert(verifier.open(config, "https://operator.example/keys").code == Status.invalidArgument);

    alias Permit = RegisteredPolicy!("checks", registered);
    enum rule = PreAuthorize("checks");
    Context context;
    Principal principal;
    assert(authorize!(rule, Permit)(principal, context).code == Status.permissionDenied);
    principal.expiresAtUnixSeconds = 10;
    assert(authorize!(rule, Permit)(principal, context).code == Status.ok);
}

version (FlintNativeOpenssl)
{
    import core.atomic : atomicLoad, atomicOp, atomicStore;
    import core.memory : GC;
    import core.thread : Thread;
    import core.time : msecs;
    import flint.arena : Text;
    import flint.conc : CancelSource, Deadline;
    import flint.security : RolesAllowed, hmacSha256, sha256;
    import flint.security.jwt : setJwksTestClockShift;
    import std.file : readText;
    import std.process : environment;

    private string fixture(string field)
    {
        return environment.get("FLINT_SECURITY_" ~ field, "");
    }

    private JwtPolicy policy(string issuer = "fixture-issuer")
    {
        JwtPolicy options;
        options.issuer = issuer;
        options.audience = "api";
        options.algorithms = [JwtAlgorithm.rs256, JwtAlgorithm.es256, JwtAlgorithm.eddsa];
        options.jwksCaBundle = fixture("CA");
        options.jwksTtlSeconds = 45;
        return options;
    }

    private bool subject(ref scope RequestArena arena, Text field, scope const(char)[] expected) nothrow @nogc
    {
        bool found;
        const read = arena.read(field.bytes, (scope const(ubyte)[] bytes) {
            found = bytes == cast(const(ubyte)[]) expected;
        });
        return found && read == Status.ok;
    }

    @("pinned SHA-256 and HMAC-SHA-256 vectors")
    unittest
    {
        ubyte[32] digest;
        assert(sha256(cast(const(ubyte)[]) "abc", digest).code == Status.ok);
        assert(digest == cast(const(ubyte)[]) x"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        ubyte[20] key;
        key[] = 0x0b;
        assert(hmacSha256(key[], cast(const(ubyte)[]) "Hi There", digest).code == Status.ok);
        assert(digest == cast(const(ubyte)[]) x"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
    }

    private final class Rotation
    {
        JwtVerifier verifier;
        string oldToken;
        string newToken;
        string unchanged;
        shared bool start;
        shared uint readCount;
        shared uint refreshed;

        void read() nothrow @nogc
        {
            while (!atomicLoad(start))
                Thread.sleep(1.msecs);
            ubyte[256] storage;
            auto arena = RequestArena(storage[]);
            foreach (turn; 0 .. 64)
            {
                const fixed = verifier.verify(unchanged, 990, arena);
                assert(fixed.ok && subject(arena, fixed.value.subject, "atlas"));
                assert(arena.reset() == Status.ok);
                const rotating = verifier.verify(turn % 2 ? oldToken : newToken, 990, arena);
                assert(rotating.ok || rotating.error.code == Status.permissionDenied);
                if (rotating.ok)
                    assert(subject(arena, rotating.value.subject, "atlas"));
                assert(arena.reset() == Status.ok);
                atomicOp!"+="(readCount, 1U);
                Thread.sleep(2.msecs);
            }
        }

        void refresh() nothrow @nogc
        {
            while (!atomicLoad(start))
                Thread.sleep(1.msecs);
            Context context;
            const status = verifier.refresh(context);
            assert(status.code == Status.ok, status.message);
            atomicOp!"+="(refreshed, 1U);
        }
    }

    @("verified claims, JWKS rotation and one refresh across concurrent readers")
    @system unittest
    {
        const origin = fixture("ORIGIN");
        if (!origin.length)
            return;
        auto options = policy();
        auto stage = new Rotation;
        assert(stage.verifier.open(options, origin ~ "/keys").code == Status.ok);
        scope (exit)
        {
            assert(stage.verifier.close().code == Status.ok);
            setJwksTestClockShift(0);
        }
        auto deadline = CancelSource.create(Context.init, Deadline.afterMillis(10_000));
        assert(deadline.ok);
        auto context = deadline.value.context();
        const refreshed = stage.verifier.refresh(context);
        assert(refreshed.code == Status.ok, refreshed.message);
        assert(readText(fixture("COUNT")) == "1");

        ubyte[4096] storage;
        auto arena = RequestArena(storage[]);
        enum role = RolesAllowed(["ops"]);
        foreach (name; ["RSA", "EC", "ED"])
        {
            const accepted = stage.verifier.verify(fixture(name), 1029, arena);
            assert(accepted.ok, accepted.error.message);
            assert(subject(arena, accepted.value.subject, "atlas"));
            assert(accepted.value.expiresAtUnixSeconds == 1000);
            assert(rolesAllowed!role(accepted.value, arena) && hasRole(accepted.value, "read", arena));
            assert(!hasRole(accepted.value, "READ", arena));
        }
        assert(stage.verifier.verify("Bearer " ~ fixture("RSA"), 1030, arena).error.code == Status.permissionDenied);
        assert(stage.verifier.verify(fixture("AUD_SINGLE"), 999, arena).ok);
        assert(stage.verifier.verify(fixture("NBF"), 1070, arena).ok);
        assert(stage.verifier.verify(fixture("NBF"), 1069, arena).error.code == Status.permissionDenied);
        const prior = arena.stats().used;
        foreach (bad; [
            "NONE", "HMAC", "CURVE", "CRIT", "DUP_ALG", "DUP_ISS", "DUP_AUD", "BAD_ISS", "BAD_AUD",
            "NO_EXP", "MISSING", "JKU", "X5U", "TAMPER"
        ])
        {
            const rejected = stage.verifier.verify(fixture(bad), 990, arena);
            assert(rejected.error.code == Status.permissionDenied);
            // Failures disclose only the stable category, never token material.
            assert(rejected.error.message == "JWT verification denied");
        }
        assert(stage.verifier.verify(fixture("RSA") ~ "=", 990, arena).error.code == Status.permissionDenied);
        assert(arena.stats().used == prior);
        assert(stage.verifier.refresh(context).code == Status.unavailable);
        assert(readText(fixture("COUNT")) == "1" && readText(fixture("TARGET_COUNT")) == "0");

        JwtVerifier duplicate;
        assert(duplicate.open(options, origin ~ "/stable").code == Status.ok);
        assert(duplicate.refresh(context).code == Status.unavailable);
        assert(duplicate.close().code == Status.ok);

        stage.oldToken = fixture("RSA");
        stage.newToken = fixture("NEXT");
        stage.unchanged = fixture("EC");
        const gcBefore = GC.stats.allocatedInCurrentThread;
        assert(stage.verifier.verify(stage.oldToken, 990, arena).ok);
        assert(GC.stats.allocatedInCurrentThread == gcBefore);

        setJwksTestClockShift(31_000_000_000L);
        Thread[6] threads;
        foreach (index, ref thread; threads)
            thread = new Thread(index < 4 ? &stage.read : &stage.refresh).start();
        atomicStore(stage.start, true);
        foreach (thread; threads)
            thread.join();
        assert(atomicLoad(stage.readCount) == 256 && atomicLoad(stage.refreshed) == 2);
        assert(readText(fixture("COUNT")) == "2");
        assert(stage.verifier.verify(stage.newToken, 990, arena).ok);
        assert(stage.verifier.verify(stage.oldToken, 990, arena).error.code == Status.permissionDenied);
        setJwksTestClockShift(77_000_000_000L);
        assert(stage.verifier.verify(stage.newToken, 990, arena).error.code == Status.permissionDenied);
    }

    @("JWKS redirect, key-count and byte bounds and optional expiration")
    unittest
    {
        const origin = fixture("ORIGIN");
        if (!origin.length)
            return;
        foreach (name; ["duplicate", "limit", "large", "redirect"])
        {
            JwtVerifier verifier;
            const options = policy("fixture-" ~ name);
            assert(verifier.open(options, origin ~ "/" ~ name).code == Status.ok);
            scope (exit)
                assert(verifier.close().code == Status.ok);
            Context context;
            const checked = verifier.refresh(context);
            const expected = name == "duplicate" ? Status.invalidArgument : name == "redirect"
                ? Status.ioError : Status.resourceExhausted;
            assert(checked.code == expected, checked.message);
        }
        assert(readText(fixture("TARGET_COUNT")) == "0");

        auto options = policy("fixture-optional");
        options.requireExpiry = false;
        JwtVerifier verifier;
        assert(verifier.open(options, origin ~ "/stable").code == Status.ok);
        scope (exit)
            assert(verifier.close().code == Status.ok);
        Context context;
        assert(verifier.refresh(context).code == Status.ok);
        ubyte[128] storage;
        auto arena = RequestArena(storage[]);
        const accepted = verifier.verify(fixture("OPTIONAL"), 990, arena);
        assert(accepted.ok && accepted.value.expiresAtUnixSeconds == long.max);
    }

    @("a verified snapshot renews in the background before its lifetime ends")
    @system unittest
    {
        import flint.security.jwt : completedJwksRefreshes;

        const origin = fixture("ORIGIN");
        if (!origin.length)
            return;
        auto options = policy("fixture-optional");
        options.requireExpiry = false;
        JwtVerifier verifier;
        // Start past the earlier refresh of this issuer so the per-issuer interval admits a fetch.
        enum second = 1_000_000_000L;
        setJwksTestClockShift(60 * second);
        assert(verifier.open(options, origin ~ "/stable").code == Status.ok);
        scope (exit)
        {
            assert(verifier.close().code == Status.ok);
            setJwksTestClockShift(0);
        }
        Context context;
        assert(verifier.refresh(context).code == Status.ok);
        assert(completedJwksRefreshes(verifier) == 1);
        ubyte[128] storage;
        auto arena = RequestArena(storage[]);
        assert(verifier.verify(fixture("OPTIONAL"), 990, arena).ok);
        assert(completedJwksRefreshes(verifier) == 1);

        // Five seconds of the 45-second lifetime remain. Verification still succeeds and renews.
        setJwksTestClockShift(100 * second);
        assert(arena.reset() == Status.ok);
        assert(verifier.verify(fixture("OPTIONAL"), 990, arena).ok);
        foreach (_; 0 .. 5000)
        {
            if (completedJwksRefreshes(verifier) == 2)
                break;
            Thread.sleep(1.msecs);
        }
        assert(completedJwksRefreshes(verifier) == 2);

        // The original snapshot would have expired; the renewed one remains valid without a gap.
        setJwksTestClockShift(110 * second);
        assert(arena.reset() == Status.ok);
        assert(verifier.verify(fixture("OPTIONAL"), 990, arena).ok);
    }
}

version (FlintNativeLibsodium)
{
    import flint.conc : CancelSource, Deadline;
    import flint.conc.wait : replaceWaitHook;
    import flint.security : hashPassword, verifyPassword;

    private Error cancelWait(Deadline) nothrow @nogc
    {
        return Error(Status.cancelled);
    }

    @("interactive Argon2id with binary passwords, verifier limits and cancellation")
    unittest
    {
        ubyte[512] storage;
        auto arena = RequestArena(storage[]);
        Context context;
        const password = cast(const(ubyte)[]) "p\0ss";
        const encoded = hashPassword(password, arena, context);
        assert(encoded.ok, encoded.error.message);
        const checked = arena.read(encoded.value, (scope const(ubyte)[] hash) {
            const typed = cast(const(char)[]) hash;
            const right = verifyPassword(password, typed, context);
            assert(right.ok && right.value);
            const wrong = verifyPassword(cast(const(ubyte)[]) "p", typed, context);
            assert(wrong.ok && !wrong.value);
            char[127] edited;
            edited[0 .. typed.length] = typed[];
            edited[17] = '9';
            const exaggerated = verifyPassword(password, edited[0 .. typed.length], context);
            assert(exaggerated.error.code == Status.resourceExhausted);
        });
        assert(checked == Status.ok);
        assert(verifyPassword(password, "$argon2id$v=19$invalid", context).error.code == Status.invalidArgument);
        ubyte[1025] maximum;
        assert(hashPassword(maximum[], arena, context).error.code == Status.invalidArgument);
        assert(hashPassword(maximum[0 .. 1024], arena, context).ok);

        const usage = arena.stats().used;
        const previous = replaceWaitHook(&cancelWait);
        const detached = hashPassword(password, arena, context);
        replaceWaitHook(previous);
        assert(detached.error.code == Status.cancelled && arena.stats().used == usage);
        assert(arena.reset() == Status.ok);
        assert(hashPassword(password, arena, context).ok);
    }
}
