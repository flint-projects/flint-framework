/// Minimal bindings to pinned OpenSSL for the provider-only comparison.
module direct_provider;

import core.stdc.config : c_long;

@safe:

private struct EVP_PKEY;
private struct EVP_MD;
private struct EVP_MD_CTX;
private struct EVP_PKEY_CTX;
private struct ECDSA_SIG;
private struct BIGNUM;

extern (C) private @system nothrow @nogc
{
    pragma(mangle, "d2i_PUBKEY") EVP_PKEY* decodePublicKey(EVP_PKEY**, const(ubyte)**, c_long);
    pragma(mangle, "EVP_PKEY_free") void freePublicKey(EVP_PKEY*);
    pragma(mangle, "EVP_MD_CTX_new") EVP_MD_CTX* newDigestContext();
    pragma(mangle, "EVP_MD_CTX_free") void freeDigestContext(EVP_MD_CTX*);
    pragma(mangle, "EVP_sha256") const(EVP_MD)* sha256Digest();
    pragma(mangle, "EVP_DigestVerifyInit") int initializeVerification(EVP_MD_CTX*,
            EVP_PKEY_CTX**, const(EVP_MD)*, void*, EVP_PKEY*);
    pragma(mangle, "EVP_PKEY_CTX_set_rsa_padding") int setRsaPadding(EVP_PKEY_CTX*, int);
    pragma(mangle, "EVP_DigestVerify") int verifyDigest(EVP_MD_CTX*, const(ubyte)*, size_t, const(ubyte)*, size_t);
    pragma(mangle, "ECDSA_SIG_new") ECDSA_SIG* newSignaturePair();
    pragma(mangle, "ECDSA_SIG_free") void freeSignaturePair(ECDSA_SIG*);
    pragma(mangle, "ECDSA_SIG_set0") int setSignaturePair(ECDSA_SIG*, BIGNUM*, BIGNUM*);
    pragma(mangle, "BN_bin2bn") BIGNUM* binaryToInteger(const(ubyte)*, int, BIGNUM*);
    pragma(mangle, "BN_clear_free") void freeInteger(BIGNUM*);
    pragma(mangle, "i2d_ECDSA_SIG") int encodeSignaturePair(const(ECDSA_SIG)*, ubyte**);
    pragma(mangle, "sodium_memzero") void eraseBytes(void*, size_t);
}

/// One native public key owned by the reference fixture.
struct CachedKey
{
    private EVP_PKEY* native;

    /// Whether the key was successfully loaded.
    bool available() const nothrow @nogc
    {
        return native !is null;
    }

    // SAFETY: Decode synchronously from caller bytes without retaining the input.
    /// Load the same public key used by the TLS JWKS fixture, in DER form.
    static CachedKey load(scope const(ubyte)[] der) @trusted nothrow @nogc
    {
        if (!der.length || der.length > c_long.max)
            return CachedKey.init;
        auto end = der.ptr;
        return CachedKey(decodePublicKey(null, &end, cast(c_long) der.length));
    }

    // SAFETY: Free the fixture-owned key once, after the last synchronous operation.
    /// Release the upstream key.
    void release() @trusted nothrow @nogc
    {
        freePublicKey(native);
        native = null;
    }
}

// SAFETY: Wrap fixed-size JWS-to-DER conversion and one synchronous upstream call. OpenSSL retains no
// borrowed bytes. The enclosing reference fixture owns the key for the whole call.
/// Verify the exact JWS signing input and fixed-curve or RSA signature.
@trusted nothrow @nogc bool directVerify(ref CachedKey key, bool rsa, scope const(ubyte)[] input,
        scope const(ubyte)[] sig)
{
    ubyte[80] der;
    scope (exit)
        eraseBytes(der.ptr, der.length);
    if (!rsa)
    {
        if (sig.length != 64)
            return false;
        const encoded = encodeDer(sig.ptr, der.ptr);
        if (encoded <= 0)
            return false;
        sig = der[0 .. encoded];
    }
    auto digest = newDigestContext();
    if (!digest)
        return false;
    scope (exit)
        freeDigestContext(digest);
    EVP_PKEY_CTX* context;
    if (initializeVerification(digest, &context, sha256Digest(), null, key.native) != 1)
        return false;
    return (!rsa || setRsaPadding(context, 1) > 0) && verifyDigest(digest, sig.ptr, sig.length,
            input.ptr, input.length) == 1;
}

private int encodeDer(const(ubyte)* raw, ubyte* output) @system nothrow @nogc
{
    auto pair = newSignaturePair();
    scope (exit)
        freeSignaturePair(pair);
    auto r = binaryToInteger(raw, 32, null);
    auto s = binaryToInteger(raw + 32, 32, null);
    if (!pair || !r || !s || setSignaturePair(pair, r, s) != 1)
    {
        freeInteger(r);
        freeInteger(s);
        return -1;
    }
    const required = encodeSignaturePair(pair, null);
    return required > 0 && required <= 80 ? encodeSignaturePair(pair, &output) : -1;
}
