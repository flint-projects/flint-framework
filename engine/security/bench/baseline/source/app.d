/// Direct EVP reference over the identical signed input and public keys.
module app;

import direct_provider : CachedKey, directVerify;
import flint.arena : RequestArena, Status, Text;
import flint.conc : Context;
import flint.http : ClientOptions, HttpClient, HttpRequest;
import flint.serde : DecodeOptions, UnknownFields, decodeInto;
import security_workload : claimsChecksum, finish, fixture, measure;
import std.base64 : Base64URLNoPadding;
import std.exception : enforce;
import std.string : indexOf, lastIndexOf;

@safe:

private struct Claims
{
    Text sub;
    long exp;
}

private void fetch()
{
    ClientOptions options;
    options.maxConnections = 1;
    options.maxConnectionsPerOrigin = 1;
    options.maxResponseBytes = 1_048_576;
    options.caBundle = fixture("CA");
    HttpClient client;
    enforce(client.open(options).code == Status.ok, "reference HTTP open failed");
    scope (exit)
        enforce(client.close().code == Status.ok, "reference HTTP close failed");
    HttpRequest request;
    request.url = fixture("ORIGIN") ~ "/stable";
    Context context;
    auto arena = RequestArena(new ubyte[options.maxResponseBytes + options.maxHeaderBytes + 256]);
    auto response = client.send(request, arena, context);
    enforce(response.ok() && response.value.status == 200 && response.value.body.length > 0,
            "reference TLS fixture fetch failed");
}

private ulong signedClaims(scope const(ubyte)[] payload)
{
    ubyte[512] memory;
    auto arena = RequestArena(memory[]);
    Claims claims;
    DecodeOptions options;
    options.unknownFields = UnknownFields.ignore;
    enforce(decodeInto(payload, claims, arena, options).code == Status.ok, "reference signed payload did not parse");
    return claimsChecksum(arena, claims.sub, claims.exp);
}

int main()
{
    fetch();
    ulong checksum;
    foreach (index, item; ["RSA", "EC"])
    {
        const token = fixture(item);
        const first = indexOf(token, '.');
        const last = lastIndexOf(token, '.');
        enforce(first > 0 && last > first, "reference token encoding is invalid");
        auto keyDer = Base64URLNoPadding.decode(fixture(item ~ "_DER"));
        auto signature = Base64URLNoPadding.decode(token[last + 1 .. $]);
        const payload = Base64URLNoPadding.decode(token[first + 1 .. last]);
        const observed = signedClaims(payload);
        auto cached = CachedKey.load(keyDer);
        enforce(cached.available, "reference public key did not load");
        scope (exit)
            cached.release();
        const signingInput = cast(const(ubyte)[]) token[0 .. last];
        const rsa = index == 0;
        checksum += measure(item, delegate ulong() @safe nothrow @nogc {
            return directVerify(cached, rsa, signingInput, signature) ? observed : 0;
        });
    }
    finish(checksum);
    return 0;
}
