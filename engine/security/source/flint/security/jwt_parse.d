/// Strict, bounded JWT fields and arena-backed principal publication.
module flint.security.jwt_parse;

import flint.arena : Buffer, Error, RequestArena, Result, Status, Text;
import flint.security.ffi.crypto : wipe;
import flint.security.types : JwtAlgorithm, Principal;
import flint.serde : decodeInto;
import flint.serde.json_visit : JsonMemberName, visitJsonArray, visitJsonObject;

@safe:
nothrow @nogc:

package(flint.security) enum tokenLimit = 16_384;
package(flint.security) enum keyIdLimit = 128;
private enum roleLimit = 64;
private enum roleNameLimit = 128;

package(flint.security) Error denied() pure
{
    return Error(Status.permissionDenied, "JWT verification denied");
}

package(flint.security) struct Header
{
    JwtAlgorithm algorithm;
    bool hasAlgorithm;
    ubyte[keyIdLimit] kid;
    size_t kidLength;
}

package(flint.security) bool recognizeAlgorithm(scope const(ubyte)[] name, out JwtAlgorithm algorithm) pure
{
    if (name == cast(const(ubyte)[]) "RS256")
        algorithm = JwtAlgorithm.rs256;
    else if (name == cast(const(ubyte)[]) "ES256")
        algorithm = JwtAlgorithm.es256;
    else if (name == cast(const(ubyte)[]) "EdDSA")
        algorithm = JwtAlgorithm.eddsa;
    else
        return false;
    return true;
}

package(flint.security) bool textMatches(ref scope RequestArena arena, Text text, scope const(char)[] expected)
{
    bool equal;
    const read = arena.read(text.bytes, (scope const(ubyte)[] raw) {
        equal = raw == cast(const(ubyte)[]) expected;
    });
    return read == Status.ok && equal;
}

private bool prohibited(scope JsonMemberName name)
{
    return name.isName("crit") || name.isName("b64") || name.isName("jku") || name.isName("x5u")
        || name.isName("jwk") || name.isName("x5c");
}

package(flint.security) Result!Header parseHeader(scope const(ubyte)[] bytes, ref scope RequestArena scratch)
{
    Header header;
    const traversed = visitJsonObject(bytes, (scope JsonMemberName name, scope const(ubyte)[] value) {
        if (prohibited(name))
            return denied();
        if (!name.isName("alg") && !name.isName("kid"))
            return Error.init;

        Text text;
        if (value.length > keyIdLimit * 6 + 2 || decodeInto(value, text, scratch).code != Status.ok)
            return denied();
        const checked = scratch.read(text.bytes, (scope const(ubyte)[] raw) {
            if (name.isName("alg"))
                header.hasAlgorithm = recognizeAlgorithm(raw, header.algorithm);
            else if (raw.length && raw.length <= header.kid.length)
            {
                header.kid[0 .. raw.length] = raw[];
                header.kidLength = raw.length;
            }
        });
        return checked == Status.ok ? Error.init : denied();
    });
    return traversed.code == Status.ok && header.hasAlgorithm && header.kidLength
        ? Result!Header(header) : Result!Header(Header.init, denied());
}

private struct Claims
{
    Text subject;
    Text[roleLimit] roles;
    size_t roleCount;
    size_t roleBytes;
    long expiry;
    long notBefore;
    bool hasSubject;
    bool hasExpiry;
    bool hasNotBefore;
    bool correctIssuer;
    bool correctAudience;
}

private Error readAudience(scope const(ubyte)[] value, scope const(char)[] expected,
        ref scope RequestArena scratch, out bool matched)
{
    bool yes;
    if (value.length && value[0] == '[')
    {
        const walked = visitJsonArray(value, delegate Error(scope const(ubyte)[] item) @safe nothrow @nogc {
            Text text;
            const decoded = decodeInto(item, text, scratch);
            if (decoded.code == Status.ok)
                yes |= textMatches(scratch, text, expected);
            return decoded;
        });
        matched = yes;
        return walked;
    }
    Text only;
    const decoded = decodeInto(value, only, scratch);
    matched = decoded.code == Status.ok && textMatches(scratch, only, expected);
    return decoded;
}

private Error readRoles(scope const(ubyte)[] value, ref Claims claims, ref scope RequestArena scratch)
{
    return visitJsonArray(value, (scope const(ubyte)[] item) {
        if (claims.roleCount == claims.roles.length)
            return denied();
        Text role;
        const decoded = decodeInto(item, role, scratch);
        const length = role.bytes.length;
        if (decoded.code != Status.ok || !length || length > roleNameLimit)
            return denied();
        claims.roles[claims.roleCount++] = role;
        claims.roleBytes += length + 2;
        return Error.init;
    });
}

private Error field(scope JsonMemberName name, scope const(ubyte)[] value, ref Claims claims,
        scope const(char)[] issuer, scope const(char)[] audience, ref scope RequestArena scratch)
{
    if (name.isName("aud"))
        return readAudience(value, audience, scratch, claims.correctAudience);
    if (name.isName("roles"))
        return readRoles(value, claims, scratch);
    if (name.isName("iss"))
    {
        Text source;
        const decoded = decodeInto(value, source, scratch);
        claims.correctIssuer = decoded.code == Status.ok && textMatches(scratch, source, issuer);
        return decoded;
    }
    if (name.isName("sub"))
    {
        claims.hasSubject = true;
        return decodeInto(value, claims.subject, scratch);
    }
    if (name.isName("exp"))
    {
        claims.hasExpiry = true;
        return decodeInto(value, claims.expiry, scratch);
    }
    if (name.isName("nbf"))
    {
        claims.hasNotBefore = true;
        return decodeInto(value, claims.notBefore, scratch);
    }
    return Error.init;
}

private bool claimTimes(scope const ref Claims claims, long now, ulong skew, bool requireExpiry) pure
{
    if (!claims.hasExpiry && requireExpiry)
        return false;
    if (claims.hasExpiry && now >= claims.expiry && cast(ulong) now - cast(ulong) claims.expiry >= skew)
        return false;
    return !claims.hasNotBefore || now >= claims.notBefore || cast(ulong) claims.notBefore - cast(ulong) now <= skew;
}

package(flint.security) Result!Principal parseClaims(scope const(ubyte)[] input,
        scope const(char)[] issuer, scope const(char)[] audience, long now, ulong skew,
        bool requireExpiry, ref scope RequestArena output)
{
    ubyte[tokenLimit] memory;
    scope (exit)
        wipe(memory[]);
    auto scratch = RequestArena(memory[]);
    Claims claims;
    const parsed = visitJsonObject(input, (scope JsonMemberName name, scope const(ubyte)[] value) {
        return field(name, value, claims, issuer, audience, scratch);
    });
    if (parsed.code != Status.ok || !claims.correctIssuer || !claims.correctAudience
            || !claimTimes(claims, now, skew, requireExpiry))
        return Result!Principal(Principal.init, denied());
    return publish(claims, scratch, output);
}

private Result!Principal publish(scope const ref Claims claims, ref scope RequestArena scratch,
        ref scope RequestArena output)
{
    const usage = output.stats();
    const subjectBytes = claims.subject.bytes.length;
    if (subjectBytes + claims.roleBytes > usage.capacity - usage.used)
        return Result!Principal(Principal.init, Error(Status.outOfMemory, "principal arena exhausted"));

    const subject = output.allocate(subjectBytes, 1);
    if (!subject.ok())
        return Result!Principal(Principal.init, subject.error);
    if (claims.hasSubject)
    {
        const copied = scratch.read(claims.subject.bytes, (scope const(ubyte)[] bytes) {
            const written = output.write(subject.value, (scope ubyte[] range) { range[] = bytes[]; });
            if (written != Status.ok)
                assert(0, "unable to copy a validated JWT subject");
        });
        assert(copied == Status.ok);
    }
    const roles = output.allocate(claims.roleBytes, 1);
    if (!roles.ok())
        return Result!Principal(Principal.init, roles.error);
    const packed = output.write(roles.value, (scope ubyte[] target) {
        packRoles(claims, scratch, target);
    });
    assert(packed == Status.ok);
    return Result!Principal(Principal(Text(subject.value), roles.value, claims.hasExpiry ? claims.expiry : long.max));
}

private void packRoles(scope const ref Claims claims, ref scope RequestArena source, scope ubyte[] output)
{
    size_t offset;
    foreach (role; claims.roles[0 .. claims.roleCount])
    {
        const length = role.bytes.length;
        output[offset++] = cast(ubyte) length;
        output[offset++] = cast(ubyte)(length >> 8);
        const status = source.read(role.bytes, (scope const(ubyte)[] data) {
            output[offset .. offset + length] = data[];
        });
        assert(status == Status.ok);
        offset += length;
    }
}
