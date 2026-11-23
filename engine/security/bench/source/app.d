/// Measure actual Flint verification using pinned, cached JWKS keys.
module app;

import flint.arena : RequestArena, Status;
import flint.conc : Context;
import flint.engine.security : JwtAlgorithm, JwtPolicy, JwtVerifier;
import security_workload : claimsChecksum, finish, fixture, measure;
import std.exception : enforce;

@safe:

int main()
{
    JwtPolicy policy;
    policy.issuer = "fixture-issuer";
    policy.audience = "api";
    policy.algorithms = [JwtAlgorithm.rs256, JwtAlgorithm.es256];
    policy.jwksCaBundle = fixture("CA");
    JwtVerifier verifier;
    enforce(verifier.open(policy, fixture("ORIGIN") ~ "/stable").code == Status.ok, "security fixture did not open");
    scope (exit)
        enforce(verifier.close().code == Status.ok, "security fixture did not close");
    Context context;
    enforce(verifier.refresh(context).code == Status.ok, "security fixture could not refresh keys");

    ulong checksum;
    foreach (item; ["RSA", "EC"])
    {
        const token = fixture(item);
        ubyte[256] storage;
        auto arena = RequestArena(storage[]);
        checksum += measure(item, delegate ulong() @safe nothrow @nogc {
            if (arena.reset() != Status.ok)
                return 0;
            const verified = verifier.verify(token, 990, arena);
            return verified.ok() ? claimsChecksum(arena, verified.value.subject, verified.value.expiresAtUnixSeconds)
                : 0;
        });
    }
    finish(checksum);
    return 0;
}
