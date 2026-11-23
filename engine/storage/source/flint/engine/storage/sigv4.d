/// AWS Signature Version 4 request formatting through the pinned cryptographic provider.
module flint.engine.storage.sigv4;

import flint.arena : Error, Status;
import flint.engine.http : HttpStreamField;
import flint.engine.security : eraseSecret, hmacSha256, sha256;
import flint.engine.storage.encoding : Writer, asciiAlpha, asciiDigit, lowerAscii, safeField;

@safe:

package(flint.engine.storage) enum maximumAccessKey = 128;
package(flint.engine.storage) enum maximumSecret = 256;
package(flint.engine.storage) enum maximumToken = 2048;
package(flint.engine.storage) enum maximumExpiry = 604_800;
package(flint.engine.storage) enum algorithm = "AWS4-HMAC-SHA256";
package(flint.engine.storage) enum unsignedPayload = "UNSIGNED-PAYLOAD";

package(flint.engine.storage) struct CredentialView
{
    const(char)[] access;
    const(char)[] secret;
    const(char)[] token;
    long expiry;
}

package(flint.engine.storage) struct SigningScratch
{
    char[16_384] canonical;
    char[512] authorization;
    size_t authLength;
    char[256] signedNames;
    size_t signedLength;
}

package(flint.engine.storage) bool validCredentials(scope const ref CredentialView view, long now) pure nothrow @nogc
{
    if (!view.secret.length || !safeField(view.secret, maximumSecret) || view.expiry < 0
            || (view.expiry && view.expiry <= now))
        return false;
    return validAccess(view.access) && validToken(view.token, view.expiry);
}

private bool validAccess(scope const(char)[] access) pure nothrow @nogc
{
    if (!access.length || access.length > maximumAccessKey)
        return false;
    foreach (item; access)
        if (!asciiAlpha(item) && !asciiDigit(item) && item != '-' && item != '_')
            return false;
    return true;
}

private bool validToken(scope const(char)[] token, long expiry) pure nothrow @nogc
{
    if (token.length > maximumToken || (token.length && !expiry))
        return false;
    foreach (item; token)
        if (item <= ' ' || item >= 0x7f)
            return false;
    return true;
}

private void digits(uint value, scope char[] output) pure nothrow @nogc
{
    foreach_reverse (ref item; output)
    {
        item = cast(char)('0' + value % 10);
        value /= 10;
    }
}

package(flint.engine.storage) bool formatDate(long seconds, out char[16] output) pure nothrow @nogc
{
    if (seconds < 0 || seconds > 253_402_300_799L)
        return false;
    // Convert days after the Unix epoch into a Gregorian date using the 400-year cycle.
    const day = cast(uint)(seconds / 86_400) + 719_468;
    const era = day / 146_097;
    const position = day - era * 146_097;
    const yearIndex = (position - position / 1_460 + position / 36_524 - position / 1_46096) / 365;
    const monthDay = position - (365 * yearIndex + yearIndex / 4 - yearIndex / 100);
    const marchMonth = (5 * monthDay + 2) / 153;
    const month = marchMonth < 10 ? marchMonth + 3 : marchMonth - 9;
    const year = yearIndex + era * 400 + (month <= 2 ? 1 : 0);
    digits(year, output[0 .. 4]);
    digits(month, output[4 .. 6]);
    digits(monthDay - (153 * marchMonth + 2) / 5 + 1, output[6 .. 8]);
    output[8] = 'T';
    digits(cast(uint)(seconds / 3600 % 24), output[9 .. 11]);
    digits(cast(uint)(seconds / 60 % 60), output[11 .. 13]);
    digits(cast(uint)(seconds % 60), output[13 .. 15]);
    output[15] = 'Z';
    return true;
}

// dfmt off
package(flint.engine.storage) void writeScope(scope ref Writer output, scope const(char)[] date,
        scope const(char)[] region) pure nothrow @nogc
{
    output.append(date[0 .. 8]);
    output.put('/');
    output.append(region);
    output.append("/s3/aws4_request");
}
// dfmt on

private void hex(scope const(ubyte)[] bytes, scope char[] output) pure nothrow @nogc
{
    foreach (index, item; bytes)
    {
        output[index * 2] = "0123456789abcdef"[item >> 4];
        output[index * 2 + 1] = "0123456789abcdef"[item & 15];
    }
}

package(flint.engine.storage) Error payloadHash(scope const(ubyte)[] body, out char[64] hash) nothrow @nogc
{
    ubyte[32] digest;
    const verified = sha256(body, digest);
    if (verified.code == Status.ok)
        hex(digest[], hash[]);
    return verified;
}

private void normalizedValue(scope ref Writer output, scope const(char)[] input) pure nothrow @nogc
{
    bool written;
    bool whitespace;
    foreach (item; input)
    {
        if (item == ' ' || item == '\t')
        {
            whitespace = written;
            continue;
        }
        if (whitespace)
            output.put(' ');
        output.put(item);
        written = true;
        whitespace = false;
    }
}

private bool fieldNameValid(scope const(char)[] name) pure nothrow @nogc
{
    if (!name.length)
        return false;
    foreach (item; name)
        if ((item < 'a' || item > 'z') && item != '-' && !asciiDigit(item))
            return false;
    return true;
}

// dfmt off
private bool headers(scope ref Writer canonical, scope ref Writer names,
        scope const(HttpStreamField)[] fields) pure nothrow @nogc
{
    if (!fields.length || fields.length > 8)
        return false;
    foreach (index, ref field; fields)
    {
        if (!fieldNameValid(field.name) || !safeField(field.value, maximumToken) || (index
                && field.name <= fields[index - 1].name))
            return false;
        if (index)
            names.put(';');
        names.append(field.name);
        canonical.append(field.name);
        canonical.put(':');
        normalizedValue(canonical, field.value);
        canonical.put('\n');
    }
    return true;
}
// dfmt on

private Error derived(scope const ref CredentialView credential, scope const(char)[] date,
        scope const(char)[] region, scope const(ubyte)[] message, out ubyte[32] signature) nothrow @nogc
{
    ubyte[maximumSecret + 4] seed;
    ubyte[32] first;
    ubyte[32] second;
    scope (exit)
    {
        eraseSecret(seed[]);
        eraseSecret(first[]);
        eraseSecret(second[]);
    }
    if (!credential.secret.length || credential.secret.length > maximumSecret || date.length != 16)
        return Error(Status.invalidArgument, "invalid S3 signing credentials");
    seed[0 .. 4] = cast(const(ubyte)[]) "AWS4";
    const size = 4 + credential.secret.length;
    seed[4 .. size] = cast(const(ubyte)[]) credential.secret[];
    auto result = hmacSha256(seed[0 .. size], cast(const(ubyte)[]) date[0 .. 8], first);
    if (result.code == Status.ok)
        result = hmacSha256(first[], cast(const(ubyte)[]) region, second);
    if (result.code == Status.ok)
        result = hmacSha256(second[], cast(const(ubyte)[]) "s3", first);
    if (result.code == Status.ok)
        result = hmacSha256(first[], cast(const(ubyte)[]) "aws4_request", second);
    if (result.code == Status.ok)
        result = hmacSha256(second[], message, signature);
    return result;
}

package(flint.engine.storage) struct Message
{
    const(char)[] method;
    const(char)[] path;
    const(char)[] query;
    const(char)[] date;
    const(char)[] region;
    const(char)[] hash;
}

package(flint.engine.storage) Error sign(scope const ref CredentialView credential, scope const ref Message message,
        scope const(HttpStreamField)[] fields, ref SigningScratch work, out char[64] signature) nothrow @nogc
{
    if (message.date.length != 16)
        return Error(Status.invalidArgument, "invalid S3 signing timestamp");
    scope canonical = Writer(work.canonical[]);
    scope names = Writer(work.signedNames[]);
    canonical.append(message.method);
    canonical.put('\n');
    canonical.append(message.path);
    canonical.put('\n');
    canonical.append(message.query);
    canonical.put('\n');
    if (!headers(canonical, names, fields))
        return Error(Status.invalidArgument, "invalid or unordered S3 signing fields");
    canonical.put('\n');
    canonical.append(names.bytes());
    canonical.put('\n');
    canonical.append(message.hash);
    if (!canonical.valid || !names.valid)
        return Error(Status.resourceExhausted, "S3 canonical request exceeds capacity");
    work.signedLength = names.length;

    char[64] canonicalHash;
    const hashed = payloadHash(cast(const(ubyte)[]) canonical.bytes(), canonicalHash);
    if (hashed.code != Status.ok)
        return hashed;
    char[256] text;
    scope stringToSign = Writer(text[]);
    stringToSign.append(algorithm);
    stringToSign.put('\n');
    stringToSign.append(message.date);
    stringToSign.put('\n');
    writeScope(stringToSign, message.date, message.region);
    stringToSign.put('\n');
    stringToSign.append(canonicalHash[]);
    if (!stringToSign.valid)
        return Error(Status.resourceExhausted, "S3 signing text exceeds capacity");

    ubyte[32] raw;
    scope (exit)
        eraseSecret(raw[]);
    const generated = derived(credential, message.date, message.region, cast(const(ubyte)[]) stringToSign.bytes(), raw);
    if (generated.code == Status.ok)
        hex(raw[], signature[]);
    return generated;
}

package(flint.engine.storage) Error authorize(scope const ref CredentialView credential,
        scope const ref Message message, scope const(HttpStreamField)[] fields, ref SigningScratch work) nothrow @nogc
{
    char[64] signature;
    const signed = sign(credential, message, fields, work, signature);
    if (signed.code != Status.ok)
        return signed;

    scope auth = Writer(work.authorization[]);
    auth.append(algorithm);
    auth.append(" Credential=");
    auth.append(credential.access);
    auth.put('/');
    writeScope(auth, message.date, message.region);
    auth.append(",SignedHeaders=");
    auth.append(work.signedNames[0 .. work.signedLength]);
    auth.append(",Signature=");
    auth.append(signature[]);
    work.authLength = auth.length;
    return auth.valid ? Error.init : Error(Status.resourceExhausted, "S3 authorization exceeds capacity");
}

// dfmt off
package(flint.engine.storage) void writePresignedQuery(scope ref Writer output,
        scope const ref CredentialView credential, scope const(char)[] date,
        scope const(char)[] region, uint expires) pure nothrow @nogc
{
    output.append("X-Amz-Algorithm=");
    output.append(algorithm);
    output.append("&X-Amz-Credential=");
    output.percent(credential.access);
    char[128] data;
    scope signingScope = Writer(data[]);
    writeScope(signingScope, date, region);
    output.append("%2F");
    output.percent(signingScope.bytes());
    output.append("&X-Amz-Date=");
    output.append(date);
    output.append("&X-Amz-Expires=");
    output.decimal(expires);
    if (credential.token.length)
    {
        output.append("&X-Amz-Security-Token=");
        output.percent(credential.token);
    }
    output.append("&X-Amz-SignedHeaders=host");
}
// dfmt on
