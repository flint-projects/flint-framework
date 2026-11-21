/// Bounded, backend-specific transactional email bodies.
module flint.mail.provider_payload;

import flint.arena : Buffer, Error, RequestArena, Status;
import flint.mail.mime : Boundaries, emitMime, encode64;
import flint.mail.types : Attachment, MailAddress, MailBackend, MailMessage;
import flint.mail.validation : headerText;

@safe:

nothrow @nogc:

private struct Json
{
    ubyte[] storage;
    size_t length;
    Status status;

nothrow @nogc:

    void text(scope const(char)[] bytes) scope
    {
        if (status != Status.ok)
            return;
        if (bytes.length > storage.length - length)
        {
            status = Status.resourceExhausted;
            return;
        }
        storage[length .. length + bytes.length] = cast(const(ubyte)[]) bytes[];
        length += bytes.length;
    }

    void item(ubyte byteValue) scope
    {
        if (status != Status.ok)
            return;
        if (length == storage.length)
            status = Status.resourceExhausted;
        else
            storage[length++] = byteValue;
    }

    void escape(ubyte byteValue) scope
    {
        if (byteValue == '"' || byteValue == '\\')
        {
            item('\\');
            item(byteValue);
        }
        else if (byteValue < 32)
        {
            text("\\u00");
            item("0123456789abcdef"[byteValue >> 4]);
            item("0123456789abcdef"[byteValue & 15]);
        }
        else
            item(byteValue);
    }

    void quoted(scope const(char)[] value) scope
    {
        item('"');
        foreach (byteValue; cast(const(ubyte)[]) value)
            escape(byteValue);
        item('"');
    }

    void key(string name) scope
    {
        quoted(name);
        item(':');
    }

    void base64(scope const(ubyte)[] bytes) scope
    {
        char[76] out_;
        size_t offset;
        while (offset < bytes.length && status == Status.ok)
        {
            const count = bytes.length - offset > 57 ? 57 : bytes.length - offset;
            const encoded = ((count + 2) / 3) * 4;
            encode64(bytes[offset .. offset + count], out_[0 .. encoded]);
            text(out_[0 .. encoded]);
            offset += count;
        }
    }

    void body(Buffer value, ref scope RequestArena arena, bool binary) scope
    {
        item('"');
        if (value.length && status == Status.ok)
        {
            const read = arena.read(value, (scope const(ubyte)[] bytes) {
                if (binary)
                    base64(bytes);
                else if (!headerText(cast(const(char)[]) bytes, bytes.length, true))
                    status = Status.invalidArgument;
                else
                    foreach (byteValue; bytes)
                        escape(byteValue);
            });
            if (read != Status.ok)
                status = read;
        }
        item('"');
    }
}

private void mailbox(scope ref Json json, scope const ref MailAddress address, bool name)
{
    if (name && address.displayName.length)
    {
        json.text("\\\"");
        foreach (item; cast(const(ubyte)[]) address.displayName)
        {
            if (item == '\\' || item == '"')
                json.text("\\\\");
            json.escape(item);
        }
        json.text("\\\" <");
        json.text(address.address);
        json.item('>');
    }
    else
        json.text(address.address);
}

private bool recipients(scope ref Json json, string name, scope const(MailAddress)[] list, bool array,
        bool labels, bool started)
{
    if (!list.length)
        return started;
    if (started)
        json.item(',');
    json.key(name);
    json.item(array ? '[' : '"');
    foreach (index, ref recipient; list)
    {
        if (index)
            json.item(',');
        if (array)
            json.item('"');
        mailbox(json, recipient, labels);
        if (array)
            json.item('"');
    }
    json.item(array ? ']' : '"');
    return true;
}

private void attachmentName(scope ref Json json, scope const(char)[] value)
{
    json.item('"');
    bool seen;
    foreach (item; cast(const(ubyte)[]) value)
    {
        if (item == '/' || item == '\\')
            continue;
        seen = true;
        json.escape(item);
    }
    if (!seen)
        json.text("attachment");
    json.item('"');
}

private void files(scope ref Json json, scope const(Attachment)[] items, ref scope RequestArena arena, bool resend)
{
    if (!items.length)
        return;
    json.item(',');
    json.key(resend ? "attachments" : "Attachments");
    json.item('[');
    foreach (index, ref file; items)
    {
        if (index)
            json.item(',');
        json.item('{');
        json.key(resend ? "filename" : "Name");
        attachmentName(json, file.fileName);
        json.item(',');
        json.key(resend ? "content" : "Content");
        json.body(file.content, arena, true);
        json.item(',');
        json.key(resend ? "content_type" : "ContentType");
        json.quoted(file.contentType.length ? file.contentType : "application/octet-stream");
        json.item('}');
    }
    json.item(']');
}

private void structured(scope ref Json json, scope const ref MailMessage message, ref scope RequestArena arena,
        bool resend)
{
    json.item('{');
    json.key(resend ? "from" : "From");
    json.item('"');
    mailbox(json, message.from, true);
    json.item('"');
    auto started = recipients(json, resend ? "to" : "To", message.to, resend, true, true);
    started = recipients(json, resend ? "cc" : "Cc", message.cc, resend, true, started);
    cast(void) recipients(json, resend ? "bcc" : "Bcc", message.bcc, resend, true, started);
    json.item(',');
    json.key(resend ? "subject" : "Subject");
    json.quoted(message.subject);
    if (message.text.length || !message.html.length)
    {
        json.item(',');
        json.key(resend ? "text" : "TextBody");
        json.body(message.text, arena, false);
    }
    if (message.html.length)
    {
        json.item(',');
        json.key(resend ? "html" : "HtmlBody");
        json.body(message.html, arena, false);
    }
    files(json, message.attachments, arena, resend);
    json.item('}');
}

private struct RawMime
{
    Json json;
    ubyte[57] staging;
    size_t used;

nothrow @nogc:

    Error append(scope const(ubyte)[] bytes) scope
    {
        while (bytes.length && json.status == Status.ok)
        {
            const count = bytes.length < staging.length - used ? bytes.length : staging.length - used;
            staging[used .. used + count] = bytes[0 .. count];
            used += count;
            bytes = bytes[count .. $];
            if (used == staging.length)
            {
                json.base64(staging[]);
                used = 0;
            }
        }
        return json.status == Status.ok ? Error.init : Error(json.status, "transactional mail body exceeds capacity");
    }
}

private Error ses(ref scope RawMime result, scope const ref MailMessage message,
        scope const ref Boundaries parts, ref scope RequestArena arena, size_t limit)
{
    result.json.text("{\"FromEmailAddress\":");
    result.json.quoted(message.from.address);
    result.json.text(",\"Destination\":{");
    auto started = recipients(result.json, "ToAddresses", message.to, true, false, false);
    started = recipients(result.json, "CcAddresses", message.cc, true, false, started);
    cast(void) recipients(result.json, "BccAddresses", message.bcc, true, false, started);
    result.json.text("},\"Content\":{\"Raw\":{\"Data\":\"");
    size_t emitted;
    scope append = delegate Error(scope const(ubyte)[] bytes) @safe nothrow @nogc {
        return result.append(bytes);
    };
    const written = emitMime(message, parts, arena, limit, append, emitted);
    if (written.code != Status.ok)
        return written;
    result.json.base64(result.staging[0 .. result.used]);
    result.json.text("\"}}}");
    return Error.init;
}

package(flint.mail) Error encodeProvider(MailBackend backend, scope const ref MailMessage message,
        scope const ref Boundaries parts, ref scope RequestArena arena, scope ubyte[] target,
        size_t limit, out size_t length)
{
    RawMime body;
    body.json.storage = target;
    if (backend == MailBackend.ses)
    {
        const status = ses(body, message, parts, arena, limit);
        if (status.code != Status.ok)
        {
            length = body.json.length;
            return status;
        }
    }
    else
        structured(body.json, message, arena, backend == MailBackend.resend);
    length = body.json.length;
    return
    body.json.status == Status.ok ? Error.init : Error(body.json.status, "transactional mail body rejected");
}
