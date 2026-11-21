/// Incremental MIME serialization with UTF-8 fields and scoped arena payloads.
module flint.mail.mime;

import flint.arena : Buffer, Error, RequestArena, Status;
import flint.conc : fillSecureRandom;
import flint.mail.types : Attachment, MailAddress, MailMessage;

@safe:

nothrow @nogc:

package(flint.mail) alias MailSink = Error delegate(scope const(ubyte)[] bytes) @safe nothrow @nogc;

private enum alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

package(flint.mail) void encode64(scope const(ubyte)[] input, scope char[] output) pure nothrow @nogc
{
    size_t offset;
    foreach (index; 0 .. (input.length + 2) / 3)
    {
        const first = input[offset++];
        const more = offset < input.length;
        const second = more ? input[offset++] : 0;
        const tail = offset < input.length;
        const third = tail ? input[offset++] : 0;
        const start = index * 4;
        output[start] = alphabet[first >> 2];
        output[start + 1] = alphabet[((first & 3) << 4) | (second >> 4)];
        output[start + 2] = more ? alphabet[((second & 15) << 2) | (third >> 6)] : '=';
        output[start + 3] = tail ? alphabet[third & 63] : '=';
    }
}

package(flint.mail) struct Boundaries
{
    char[41] mixed;
    char[41] alternative;
}

package(flint.mail) Error boundaries(out Boundaries result) nothrow @nogc
{
    ubyte[32] random;
    const status = fillSecureRandom(random[]);
    if (status.code != Status.ok)
        return status;
    setBoundary(result.mixed[], "flint-mx-", random[0 .. 16]);
    setBoundary(result.alternative[], "flint-al-", random[16 .. 32]);
    return Error.init;
}

private void setBoundary(scope char[] output, string prefix, scope const(ubyte)[] random) pure nothrow @nogc
{
    output[0 .. prefix.length] = prefix[];
    foreach (index, item; random)
    {
        const offset = prefix.length + index * 2;
        output[offset] = "0123456789abcdef"[item >> 4];
        output[offset + 1] = "0123456789abcdef"[item & 15];
    }
}

private struct Output
{
    private MailSink sink;
    private Error failure;
    size_t size;
    size_t maximum;
    bool countOnly;

    void put(scope const(char)[] bytes) scope nothrow @nogc
    {
        if (failure.code != Status.ok || !bytes.length)
            return;
        if (bytes.length > maximum - size)
        {
            failure = Error(Status.resourceExhausted, "encoded mail exceeds configured limit");
            return;
        }
        size += bytes.length;
        if (!countOnly)
            failure = sink(cast(const(ubyte)[]) bytes);
    }

    void bodyBytes(scope const(ubyte)[] bytes) scope nothrow @nogc
    {
        if (countOnly)
        {
            const lines = bytes.length / 57;
            const tail = bytes.length % 57;
            if (lines > (maximum - size) / 78)
            {
                failure = Error(Status.resourceExhausted, "encoded mail exceeds configured limit");
                return;
            }
            size += lines * 78;
            const extra = tail ? ((tail + 2) / 3) * 4 + 2 : 0;
            if (extra > maximum - size)
                failure = Error(Status.resourceExhausted, "encoded mail exceeds configured limit");
            else
                size += extra;
            return;
        }
        char[78] line;
        size_t offset;
        while (offset < bytes.length && failure.code == Status.ok)
        {
            const count = bytes.length - offset > 57 ? 57 : bytes.length - offset;
            const encoded = ((count + 2) / 3) * 4;
            encode64(bytes[offset .. offset + count], line[0 .. encoded]);
            line[encoded .. encoded + 2] = "\r\n";
            put(line[0 .. encoded + 2]);
            offset += count;
        }
    }

    void body(Buffer buffer, ref scope RequestArena arena) scope nothrow @nogc
    {
        if (failure.code != Status.ok || !buffer.length)
            return;
        const borrowed = arena.read(buffer, (scope const(ubyte)[] value) { bodyBytes(value); });
        if (borrowed != Status.ok)
            failure = Error(borrowed, "mail payload does not belong to this arena");
    }
}

private void words(scope ref Output out_, scope const(char)[] value) nothrow @nogc
{
    size_t offset;
    while (offset < value.length && out_.failure.code == Status.ok)
    {
        size_t count = value.length - offset > 45 ? 45 : value.length - offset;
        while (offset + count < value.length && (cast(ubyte) value[offset + count] & 0xc0) == 0x80)
            --count;
        if (offset)
            out_.put("\r\n ");
        char[60] encoded;
        const length = ((count + 2) / 3) * 4;
        encode64(cast(const(ubyte)[]) value[offset .. offset + count], encoded[0 .. length]);
        out_.put("=?UTF-8?B?");
        out_.put(encoded[0 .. length]);
        out_.put("?=");
        offset += count;
    }
}

private void address(scope ref Output out_, scope const ref MailAddress value) nothrow @nogc
{
    if (value.displayName.length)
    {
        words(out_, value.displayName);
        out_.put("\r\n ");
    }
    out_.put("<");
    out_.put(value.address);
    out_.put(">");
}

private void addresses(scope ref Output out_, string name, scope const(MailAddress)[] values) nothrow @nogc
{
    if (!values.length)
        return;
    out_.put(name);
    foreach (index, ref recipient; values)
    {
        if (index)
            out_.put(",\r\n ");
        address(out_, recipient);
    }
    out_.put("\r\n");
}

private void textPart(scope ref Output out_, string kind, Buffer buffer, ref scope RequestArena arena)
{
    out_.put("Content-Type: ");
    out_.put(kind);
    out_.put("; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n");
    out_.body(buffer, arena);
}

private void contentBoundary(scope ref Output out_, string kind, scope const(char)[] boundary) nothrow @nogc
{
    out_.put("Content-Type: multipart/");
    out_.put(kind);
    out_.put("; boundary=\"");
    out_.put(boundary);
    out_.put("\"\r\n\r\n");
}

private void delimiter(scope ref Output out_, scope const(char)[] boundary, bool final_) nothrow @nogc
{
    out_.put("--");
    out_.put(boundary);
    out_.put(final_ ? "--\r\n" : "\r\n");
}

private void ordinaryBody(scope ref Output out_, scope const ref MailMessage mail,
        scope const ref Boundaries parts, ref scope RequestArena arena)
{
    if (mail.text.length && mail.html.length)
    {
        contentBoundary(out_, "alternative", parts.alternative[]);
        delimiter(out_, parts.alternative[], false);
        textPart(out_, "text/plain", mail.text, arena);
        delimiter(out_, parts.alternative[], false);
        textPart(out_, "text/html", mail.html, arena);
        delimiter(out_, parts.alternative[], true);
    }
    else if (mail.html.length)
        textPart(out_, "text/html", mail.html, arena);
    else
        textPart(out_, "text/plain", mail.text, arena);
}

private bool fileChar(char item) pure nothrow @nogc
{
    return (item >= 'a' && item <= 'z') || (item >= 'A' && item <= 'Z') || (item >= '0' && item <= '9')
        || item == '-' || item == '.' || item == '_';
}

private void filename(scope ref Output out_, scope const(char)[] file) nothrow @nogc
{
    char[3] encoded = ['%', '0', '0'];
    size_t kept;
    foreach (ref character; file)
    {
        if (character == '/' || character == '\\')
            continue;
        ++kept;
        if (fileChar(character))
        {
            const char[1] item = [character];
            out_.put(item[]);
        }
        else
        {
            const byteValue = cast(ubyte) character;
            encoded[1] = "0123456789ABCDEF"[byteValue >> 4];
            encoded[2] = "0123456789ABCDEF"[byteValue & 15];
            out_.put(encoded[]);
        }
    }
    if (!kept)
        out_.put("attachment");
}

private void attachment(scope ref Output out_, scope const ref Attachment file, ref scope RequestArena arena)
{
    out_.put("Content-Type: ");
    out_.put(file.contentType.length ? file.contentType : "application/octet-stream");
    out_.put("\r\nContent-Disposition: attachment;\r\n filename*=UTF-8''");
    filename(out_, file.fileName);
    out_.put("\r\nContent-Transfer-Encoding: base64\r\n\r\n");
    out_.body(file.content, arena);
}

private void serialize(scope ref Output out_, scope const ref MailMessage mail,
        scope const ref Boundaries parts, ref scope RequestArena arena)
{
    out_.put("From: ");
    address(out_, mail.from);
    out_.put("\r\n");
    addresses(out_, "To: ", mail.to);
    addresses(out_, "Cc: ", mail.cc);
    out_.put("Subject: ");
    words(out_, mail.subject);
    out_.put("\r\nMIME-Version: 1.0\r\n");
    if (!mail.attachments.length)
    {
        ordinaryBody(out_, mail, parts, arena);
        return;
    }
    contentBoundary(out_, "mixed", parts.mixed[]);
    delimiter(out_, parts.mixed[], false);
    ordinaryBody(out_, mail, parts, arena);
    foreach (ref file; mail.attachments)
    {
        delimiter(out_, parts.mixed[], false);
        attachment(out_, file, arena);
    }
    delimiter(out_, parts.mixed[], true);
}

package(flint.mail) Error emitMime(scope const ref MailMessage mail, scope const ref Boundaries parts,
        ref scope RequestArena arena, size_t maximum, scope MailSink sink, out size_t size) nothrow @nogc
{
    scope output = Output(sink, Error.init, 0, maximum, sink is null);
    serialize(output, mail, parts, arena);
    size = output.size;
    return output.failure.code == Status.ok ? Error.init : Error(output.failure.code,
            "mail MIME serialization interrupted", output.failure.offset);
}
