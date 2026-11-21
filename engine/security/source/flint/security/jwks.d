/// Parse a bounded JWKS into independently retained native public keys.
module flint.security.jwks;

import flint.arena : Error, RequestArena, Result, Status, Text;
import flint.security.base64url : decodeUrl64;
import flint.security.ffi.crypto : Key, wipe;
import flint.security.jwt_parse : keyIdLimit, recognizeAlgorithm, textMatches, tokenLimit;
import flint.security.types : JwtAlgorithm;
import flint.serde : decodeInto;
import flint.serde.json_visit : JsonMemberName, visitJsonArray, visitJsonObject;

@safe:
nothrow @nogc:

private struct Entry
{
    ubyte[keyIdLimit] kid;
    size_t length;
    JwtAlgorithm algorithm;
    Key key;
}

package(flint.security) struct KeySet
{
    private Entry[64] keys;
    private size_t count;
    long expiry;

    Error parse(scope const(ubyte)[] input, uint allowed) nothrow @nogc
    {
        bool present;
        uint visited;
        const checked = visitJsonObject(input, (scope JsonMemberName name, scope const(ubyte)[] value) {
            if (!name.isName("keys"))
                return Error.init;
            present = true;
            return visitJsonArray(value, (scope const(ubyte)[] element) {
                if (visited == keys.length)
                    return Error(Status.resourceExhausted, "JWKS key limit exceeded");
                ++visited;
                auto prepared = readKey(element, allowed);
                if (!prepared.ok())
                    return prepared.error;
                if (!prepared.value.length)
                    return Error.init;
                foreach (ref key; keys[0 .. count])
                {
                    if (key.kid[0 .. key.length] == prepared.value.kid[0 .. prepared.value.length])
                    {
                        prepared.value.key.release();
                        return malformed();
                    }
                }
                keys[count++] = prepared.value;
                return Error.init;
            });
        });
        if (checked.code != Status.ok)
            return checked;
        return present ? Error.init : malformed();
    }

    Result!Key retain(scope const(ubyte)[] kid, JwtAlgorithm algorithm) nothrow @nogc
    {
        foreach (ref entry; keys[0 .. count])
        {
            if (entry.algorithm == algorithm && entry.kid[0 .. entry.length] == kid)
                return Result!Key(entry.key, entry.key.retain());
        }
        return Result!Key(Key.init, Error(Status.notFound));
    }

    void clear() nothrow @nogc
    {
        foreach (ref entry; keys[0 .. count])
            entry.key.release();
        count = 0;
        expiry = 0;
    }
}

private struct Fields
{
    Text kind;
    Text kid;
    Text algorithm;
    Text usage;
    Text curve;
    Text modulus;
    Text exponent;
    Text x;
    Text y;
    bool hasAlgorithm;
    bool hasUsage;
    bool hasOps;
    bool verify;
}

private Error malformed() pure
{
    return Error(Status.invalidArgument, "invalid JWKS snapshot");
}

private Error attribute(scope JsonMemberName name, scope const(ubyte)[] value, ref Fields fields,
        ref scope RequestArena scratch)
{
    if (name.isName("alg"))
    {
        fields.hasAlgorithm = true;
        return decodeInto(value, fields.algorithm, scratch);
    }
    if (name.isName("use"))
    {
        fields.hasUsage = true;
        return decodeInto(value, fields.usage, scratch);
    }
    if (name.isName("key_ops"))
    {
        fields.hasOps = true;
        return visitJsonArray(value, delegate Error(scope const(ubyte)[] operation) @safe nothrow @nogc {
            Text operationName;
            const parsed = decodeInto(operation, operationName, scratch);
            fields.verify |= parsed.code == Status.ok && textMatches(scratch, operationName, "verify");
            return parsed;
        });
    }
    return materialAttribute(name, value, fields, scratch);
}

private Error materialAttribute(scope JsonMemberName name, scope const(ubyte)[] value, ref Fields fields,
        ref scope RequestArena scratch)
{
    if (name.isName("kty"))
        return decodeInto(value, fields.kind, scratch);
    if (name.isName("kid"))
        return decodeInto(value, fields.kid, scratch);
    if (name.isName("crv"))
        return decodeInto(value, fields.curve, scratch);
    if (name.isName("n"))
        return decodeInto(value, fields.modulus, scratch);
    if (name.isName("e"))
        return decodeInto(value, fields.exponent, scratch);
    if (name.isName("x"))
        return decodeInto(value, fields.x, scratch);
    if (name.isName("y"))
        return decodeInto(value, fields.y, scratch);
    return Error.init;
}

private bool keyKind(scope const ref Fields fields, ref scope RequestArena scratch, out JwtAlgorithm algorithm)
{
    if (textMatches(scratch, fields.kind, "RSA"))
        algorithm = JwtAlgorithm.rs256;
    else if (textMatches(scratch, fields.kind, "EC") && textMatches(scratch, fields.curve, "P-256"))
        algorithm = JwtAlgorithm.es256;
    else if (textMatches(scratch, fields.kind, "OKP") && textMatches(scratch, fields.curve, "Ed25519"))
        algorithm = JwtAlgorithm.eddsa;
    else
        return false;
    return true;
}

private bool intendedAlgorithm(ref scope RequestArena scratch, Text registered, JwtAlgorithm actual)
{
    JwtAlgorithm expected;
    bool recognized;
    const read = scratch.read(registered.bytes, (scope const(ubyte)[] spelling) {
        recognized = recognizeAlgorithm(spelling, expected);
    });
    return read == Status.ok && recognized && expected == actual;
}

private Result!Entry readKey(scope const(ubyte)[] json, uint allowed)
{
    ubyte[8192] memory;
    scope (exit)
        wipe(memory[]);
    auto scratch = RequestArena(memory[]);
    Fields fields;
    const checked = visitJsonObject(json, (scope JsonMemberName name, scope const(ubyte)[] value) {
        return attribute(name, value, fields, scratch);
    });
    if (checked.code != Status.ok)
        return Result!Entry(Entry.init, malformed());
    JwtAlgorithm algorithm;
    if ((fields.hasUsage && !textMatches(scratch, fields.usage, "sig")) || (fields.hasOps
            && !fields.verify) || !keyKind(fields, scratch, algorithm) || !(allowed & (1U << cast(uint) algorithm)))
        return Result!Entry.init;
    if (fields.hasAlgorithm && !intendedAlgorithm(scratch, fields.algorithm, algorithm))
        return Result!Entry(Entry.init, malformed());

    return prepareEntry(fields, algorithm, scratch);
}

private Result!Entry prepareEntry(scope const ref Fields fields, JwtAlgorithm algorithm, ref scope RequestArena scratch)
{
    Entry entry;
    entry.algorithm = algorithm;
    entry.length = fields.kid.bytes.length;
    if (!entry.length || entry.length > keyIdLimit)
        return Result!Entry(Entry.init, malformed());
    const id = scratch.read(fields.kid.bytes, (scope const(ubyte)[] decoded) {
        entry.kid[0 .. decoded.length] = decoded[];
    });
    if (id != Status.ok)
        return Result!Entry(Entry.init, malformed());
    auto native = createKey(fields, algorithm, scratch);
    if (!native.ok())
        return Result!Entry(Entry.init, native.error);
    entry.key = native.value;
    return Result!Entry(entry);
}

private bool decodeField(Text field, ref scope RequestArena scratch, scope ubyte[] output, out size_t used)
{
    bool accepted;
    const read = scratch.read(field.bytes, (scope const(ubyte)[] encoded) {
        accepted = decodeUrl64(encoded, output, used);
    });
    return read == Status.ok && accepted;
}

private Result!Key createKey(scope const ref Fields fields, JwtAlgorithm algorithm, ref scope RequestArena scratch)
{
    ubyte[512] first;
    ubyte[32] second;
    size_t a, b;
    const primary = algorithm == JwtAlgorithm.rs256 ? fields.modulus : fields.x;
    const secondary = algorithm == JwtAlgorithm.rs256 ? fields.exponent : fields.y;
    if (!decodeField(primary, scratch, first[], a))
        return Result!Key(Key.init, malformed());
    if (algorithm != JwtAlgorithm.eddsa && !decodeField(secondary, scratch, second[], b))
        return Result!Key(Key.init, malformed());
    return Key.create(algorithm, first[0 .. a], second[0 .. b]);
}
