module flint.security.security_acceptance_test;

import flint.arena : RequestArena, Status;
import flint.conc : Context;
import flint.security : CorsPolicy, JwtVerifier, preflight;
import flint.security.jwks : KeySet;
import flint.security.jwt_parse : parseClaims;
import flint.security.types : JwtAlgorithm;

@safe:

private enum allAlgorithms = 0b111U;

private const(ubyte)[] bytes(return scope const(char)[] text) pure nothrow @nogc
{
    return cast(const(ubyte)[]) text;
}

private Status claimsAt(string json, long now, ulong skew = 30, bool requireExpiry = true) nothrow @nogc
{
    ubyte[1024] storage;
    auto arena = RequestArena(storage[]);
    return parseClaims(bytes(json), "issuer", "api", now, skew, requireExpiry, arena).error.code;
}

@("jwt_claims: exact exp/nbf skew boundaries, issuer, audience and expiry with a fake clock")
unittest
{
    enum expiring = `{"iss":"issuer","aud":"api","exp":1000}`;
    assert(claimsAt(expiring, 999) == Status.ok);
    assert(claimsAt(expiring, 1029) == Status.ok);
    assert(claimsAt(expiring, 1030) == Status.permissionDenied);
    assert(claimsAt(expiring, 999, 0) == Status.ok);
    assert(claimsAt(expiring, 1000, 0) == Status.permissionDenied);

    enum notBefore = `{"iss":"issuer","aud":["x","api"],"exp":5000,"nbf":2000}`;
    assert(claimsAt(notBefore, 1970) == Status.ok);
    assert(claimsAt(notBefore, 1969) == Status.permissionDenied);
    assert(claimsAt(notBefore, 2000, 0) == Status.ok);
    assert(claimsAt(notBefore, 1999, 0) == Status.permissionDenied);

    assert(claimsAt(`{"iss":"issuer","aud":"API","exp":1000}`, 10) == Status.permissionDenied);
    assert(claimsAt(`{"iss":"issuer","aud":["other"],"exp":1000}`, 10) == Status.permissionDenied);
    assert(claimsAt(`{"iss":"issuer","exp":1000}`, 10) == Status.permissionDenied);
    assert(claimsAt(`{"iss":"issuer2","aud":"api","exp":1000}`, 10) == Status.permissionDenied);
    assert(claimsAt(`{"iss":"Issuer","aud":"api","exp":1000}`, 10) == Status.permissionDenied);
    assert(claimsAt(`{"aud":"api","exp":1000}`, 10) == Status.permissionDenied);
    assert(claimsAt(`{"iss":"issuer","aud":"api"}`, 10) == Status.permissionDenied);
    assert(claimsAt(`{"iss":"issuer","aud":"api"}`, 10, 30, false) == Status.ok);
    assert(claimsAt(`{"iss":"issuer","aud":"api","exp":"1000"}`, 10) != Status.ok);
    assert(claimsAt(`{"iss":"issuer","aud":"api","exp":1000,"exp":2000}`, 10) != Status.ok);

    // Time arithmetic stays exact at the extremes of the signed claim range.
    assert(claimsAt(`{"iss":"issuer","aud":"api","exp":-9223372036854775808}`, long.max) == Status.permissionDenied);
    assert(claimsAt(`{"iss":"issuer","aud":"api","exp":9223372036854775807}`, long.min) == Status.ok);
    assert(claimsAt(`{"iss":"issuer","aud":"api","exp":9223372036854775807,"nbf":9223372036854775807}`,
            long.min) == Status.permissionDenied);
}

@("jwt_claims: role list and principal arena bounds fail closed")
unittest
{
    char[2048] json;
    size_t used;
    void put(scope const(char)[] text)
    {
        json[used .. used + text.length] = text[];
        used += text.length;
    }

    put(`{"iss":"issuer","aud":"api","exp":1000,"roles":[`);
    foreach (index; 0 .. 65)
        put(index ? `,"r"` : `"r"`);
    put(`]}`);
    ubyte[1024] storage;
    auto arena = RequestArena(storage[]);
    assert(parseClaims(bytes(json[0 .. used]), "issuer", "api", 10, 30, true, arena).error.code
            == Status.permissionDenied);
    assert(arena.stats().used == 0);
    assert(parseClaims(bytes(`{"iss":"issuer","aud":"api","exp":1000,"roles":[""]}`), "issuer",
            "api", 10, 30, true, arena).error.code == Status.permissionDenied);

    ubyte[4] tiny;
    auto small = RequestArena(tiny[]);
    assert(parseClaims(bytes(`{"iss":"issuer","aud":"api","exp":1000,"sub":"atlas-subject"}`),
            "issuer", "api", 10, 30, true, small).error.code == Status.outOfMemory);
    assert(small.stats().used == 0);
}

@("jwt_confusion: symmetric, mismatched-curve and mislabelled JWKs never become verification keys")
unittest
{
    KeySet keys;
    scope (exit)
        keys.clear();
    // A shared-secret JWK under a key ID used by an asymmetric token is ignored, never used as an HMAC key.
    assert(keys.parse(bytes(`{"keys":[{"kty":"oct","kid":"rsa1","alg":"HS256","k":"c2VjcmV0"}]}`),
            allAlgorithms).code == Status.ok);
    foreach (algorithm; [JwtAlgorithm.rs256, JwtAlgorithm.es256, JwtAlgorithm.eddsa])
        assert(keys.retain(bytes("rsa1"), algorithm).error.code == Status.notFound);
    keys.clear();
    // P-384 and other unsupported curves are not ES256 keys.
    assert(keys.parse(bytes(`{"keys":[{"kty":"EC","crv":"P-384","kid":"ec","x":"AA","y":"AA"}]}`),
            allAlgorithms).code == Status.ok);
    assert(keys.retain(bytes("ec"), JwtAlgorithm.es256).error.code == Status.notFound);
    keys.clear();
    // An RSA key labelled for HMAC or for a different asymmetric algorithm is a malformed snapshot.
    foreach (alg; ["HS256", "ES256", "none"])
    {
        char[96] json;
        enum head = `{"keys":[{"kty":"RSA","kid":"k","n":"AQAB","e":"AQAB","alg":"`;
        json[0 .. head.length] = head;
        json[head.length .. head.length + alg.length] = alg;
        const end = head.length + alg.length + 4;
        json[head.length + alg.length .. end] = `"}]}`;
        assert(keys.parse(bytes(json[0 .. end]), allAlgorithms).code == Status.invalidArgument);
        keys.clear();
    }
    // Encryption-only keys are skipped.
    assert(keys.parse(bytes(`{"keys":[{"kty":"OKP","crv":"Ed25519","kid":"e","use":"enc","x":"AA"}]}`),
            allAlgorithms).code == Status.ok);
    assert(keys.retain(bytes("e"), JwtAlgorithm.eddsa).error.code == Status.notFound);
    keys.clear();
    assert(keys.parse(bytes(`{"keys":[{"kty":"OKP","crv":"Ed25519","kid":"e","key_ops":["sign"],"x":"AA"}]}`),
            allAlgorithms).code == Status.ok);
    assert(keys.retain(bytes("e"), JwtAlgorithm.eddsa).error.code == Status.notFound);
    keys.clear();
    assert(keys.parse(bytes(`{"keys":[]}`), allAlgorithms).code == Status.ok);
    assert(keys.parse(bytes(`{"other":[]}`), allAlgorithms).code == Status.invalidArgument);
    assert(keys.parse(bytes(`{"keys":[],"keys":[]}`), allAlgorithms).code != Status.ok);
}

@("cors_matrix: denied and allowed preflights both vary on origin and request fields")
unittest
{
    CorsPolicy policy;
    policy.origins = ["https://app.example"];
    policy.methods = ["GET"];
    policy.headers = ["x-test"];
    enum vary = "Origin, Access-Control-Request-Method, Access-Control-Request-Headers";
    foreach (origin; [
        "https://app.example", "https://app.example.evil", "null", "https://evil.app.example"
    ])
    {
        const decision = preflight(policy, origin, "GET", "x-test");
        assert(decision.allowed == (origin == "https://app.example"));
        assert(decision.vary == vary);
        if (!decision.allowed)
            assert(!decision.credentials && decision.maxAgeSeconds == 0);
    }
    policy.origins = ["*"];
    policy.credentials = true;
    const wildcard = preflight(policy, "https://app.example", "GET", "");
    assert(!wildcard.allowed && !wildcard.credentials && wildcard.vary == vary);
}

@("secret_lifetime: unopened and failed verification report only a stable category")
unittest
{
    JwtVerifier verifier;
    ubyte[64] storage;
    auto arena = RequestArena(storage[]);
    enum secret = "Bearer eyJhbGciOiJSUzI1NiJ9.c2VjcmV0LXBheWxvYWQ.c2lnbmF0dXJl";
    const denied = verifier.verify(secret, 10, arena);
    assert(denied.error.code == Status.permissionDenied);
    assert(denied.error.message == "JWT verification denied");
    assert(arena.stats().used == 0);
    Context context;
    assert(verifier.refresh(context).code == Status.unavailable);
    assert(verifier.close().code == Status.ok);
}

version (FlintNativeOpenssl)
{
    import flint.security : hmacSha256, sha256;
    import flint.security.base64url : decodeUrl64;
    import flint.security.ffi.crypto : Key;

    private void sha(scope const(ubyte)[] input, scope const(ubyte)[] expected)
    {
        ubyte[32] digest;
        assert(sha256(input, digest).code == Status.ok);
        assert(digest[] == expected);
    }

    private void hmac(scope const(ubyte)[] key, scope const(ubyte)[] input, scope const(ubyte)[] expected)
    {
        ubyte[32] digest;
        assert(hmacSha256(key, input, digest).code == Status.ok);
        assert(digest[0 .. expected.length] == expected);
    }

    @("crypto_vectors: FIPS 180-2 SHA-256, RFC 4231 HMAC-SHA-256 and AWS SigV4 key derivation") unittest
    {
        sha(null, cast(const(ubyte)[]) x"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        sha(bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                cast(const(ubyte)[]) x"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
        auto million = new ubyte[1_000_000];
        million[] = 'a';
        sha(million, cast(const(ubyte)[]) x"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");

        hmac(bytes("Jefe"), bytes("what do ya want for nothing?"),
                cast(const(ubyte)[]) x"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
        ubyte[131] large;
        large[] = 0xaa;
        ubyte[50] filler;
        filler[] = 0xdd;
        hmac(large[0 .. 20], filler[],
                cast(const(ubyte)[]) x"773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe");
        ubyte[25] counting;
        foreach (index, ref item; counting)
            item = cast(ubyte)(index + 1);
        filler[] = 0xcd;
        hmac(counting[], filler[],
                cast(const(ubyte)[]) x"82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b");
        ubyte[20] truncated;
        truncated[] = 0x0c;
        hmac(truncated[], bytes("Test With Truncation"), cast(const(ubyte)[]) x"a3b6167473100ee06e0c796c2955552b");
        hmac(large[], bytes("Test Using Larger Than Block-Size Key - Hash Key First"),
                cast(const(ubyte)[]) x"60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
        hmac(large[], bytes("This is a test using a larger than block-size key and a larger than block-size data."
                ~ " The key needs to be hashed before being used by the HMAC algorithm."),
                cast(const(ubyte)[]) x"9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2");

        // AWS Signature Version 4 signing-key example: kDate, kRegion, kService and kSigning.
        ubyte[32] first, second;
        assert(hmacSha256(bytes("AWS4wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), bytes("20120215"),
                first).code == Status.ok);
        assert(first[] == cast(const(ubyte)[]) x"969fbb94feb542b71ede6f87fe4d5fa29c789342b0f407474670f0c2489e0a0d");
        assert(hmacSha256(first[], bytes("us-east-1"), second).code == Status.ok);
        assert(hmacSha256(second[], bytes("iam"), first).code == Status.ok);
        assert(hmacSha256(first[], bytes("aws4_request"), second).code == Status.ok);
        assert(second[] == cast(const(ubyte)[]) x"f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d");
    }

    private string joined(scope const(string)[] parts) pure nothrow
    {
        string result;
        foreach (part; parts)
            result ~= part;
        return result;
    }

    private enum rfcPayload = joined([
        "eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFt",
        "cGxlLmNvbS9pc19yb290Ijp0cnVlfQ",
    ]);
    private enum rfcModulus = joined(
                [
            "ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp",
            "-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOW",
            "vG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUs",
            "LA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9k",
            "G4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8NAco9_h9iaGNj8q2ethFkMLs91kzk2",
            "PAcDTW9gb54h4FRWyuXpoQ",
    ]);
    private enum rfcSignature = joined(
                [
            "cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7",
            "AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4",
            "BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K",
            "0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqv",
            "hJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrB",
            "p0igcN_IoypGlUPQGe77Rw",
    ]);

    private struct Vector
    {
        JwtAlgorithm algorithm;
        string kid;
        string input;
        string signature;
    }

    // RFC 7515 appendices A.2 (RS256) and A.3 (ES256) and RFC 8037 appendix A.4 (EdDSA).
    private immutable Vector[3] vectors = [
        Vector(JwtAlgorithm.rs256, "rfc7515-a2", "eyJhbGciOiJSUzI1NiJ9." ~ rfcPayload,
                rfcSignature),
        Vector(JwtAlgorithm.es256, "rfc7515-a3", "eyJhbGciOiJFUzI1NiJ9." ~ rfcPayload,
                "DtEhU3ljbEg8L38VWAfUAqOyKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqPP3-Kg6NU1Q"),
        Vector(JwtAlgorithm.eddsa, "rfc8037-a4", "eyJhbGciOiJFZERTQSJ9.RXhhbXBsZSBvZiBFZDI1NTE5IHNpZ25pbmc",
                "hgyY0il_MGCjP0JzlnLWG1PPOt7-09PGcvMg3AIbQR6dWbhijcNR4ki4iylGjg5BhVsPt9g7sVvpAr_MuM0KAg"),
    ];

    private enum rfcKeys = `{"keys":[`
        ~ `{"kty":"RSA","kid":"rfc7515-a2","use":"sig","alg":"RS256","n":"` ~ rfcModulus ~ `","e":"AQAB"},`
        ~ `{"kty":"EC","crv":"P-256","kid":"rfc7515-a3","x":"f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU",`
        ~ `"y":"x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"},`
        ~ `{"kty":"OKP","crv":"Ed25519","kid":"rfc8037-a4","key_ops":["verify"],`
        ~ `"x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}]}`;

    @("crypto_vectors: RFC 7515 and RFC 8037 JWS vectors verify and every signature bit flip fails")
    unittest
    {
        KeySet keys;
        scope (exit)
            keys.clear();
        assert(keys.parse(bytes(rfcKeys), allAlgorithms).code == Status.ok);
        foreach (vector; vectors)
        {
            ubyte[512] signature;
            size_t length;
            assert(decodeUrl64(bytes(vector.signature), signature[], length));
            auto key = keys.retain(bytes(vector.kid), vector.algorithm);
            assert(key.ok);
            scope (exit)
                key.value.release();
            const input = bytes(vector.input);
            assert(key.value.verify(vector.algorithm, input, signature[0 .. length]).code == Status.ok);
            foreach (bit; 0 .. length * 8)
            {
                signature[bit / 8] ^= cast(ubyte)(1U << (bit % 8));
                assert(key.value.verify(vector.algorithm, input, signature[0 .. length]).code != Status.ok);
                signature[bit / 8] ^= cast(ubyte)(1U << (bit % 8));
            }
            // A key never verifies under another algorithm, a truncated signature or an altered input.
            foreach (other; [JwtAlgorithm.rs256, JwtAlgorithm.es256, JwtAlgorithm.eddsa])
                if (other != vector.algorithm)
                    assert(key.value.verify(other, input, signature[0 .. length]).code != Status.ok);
            assert(key.value.verify(vector.algorithm, input, signature[0 .. length - 1]).code != Status.ok);
            assert(key.value.verify(vector.algorithm, input[0 .. $ - 1], signature[0 .. length]).code != Status.ok);
            // Key type selection is bound to the registered algorithm.
            foreach (other; [JwtAlgorithm.rs256, JwtAlgorithm.es256, JwtAlgorithm.eddsa])
                if (other != vector.algorithm)
                    assert(keys.retain(bytes(vector.kid), other).error.code == Status.notFound);
        }
    }

    @("jwt_confusion: RSA keys below 2048 bits fail the whole snapshot")
    unittest
    {
        KeySet keys;
        scope (exit)
            keys.clear();
        // The first 1008 bits of the RFC 7515 modulus form a syntactically valid but undersized key.
        enum weak = `{"keys":[{"kty":"RSA","kid":"weak","n":"` ~ rfcModulus[0 .. 168] ~ `","e":"AQAB"}]}`;
        assert(keys.parse(bytes(weak), allAlgorithms).code == Status.permissionDenied);
        assert(keys.retain(bytes("weak"), JwtAlgorithm.rs256).error.code == Status.notFound);
    }
}
