/// Bounded decoder for the three transactional acknowledgement shapes.
module flint.engine.mail.provider_reply;

import flint.arena : Error, Status;
import flint.engine.mail.types : MailBackend, maximumReceiptBytes;
import flint.engine.mail.validation : headerText;

@safe:

pure nothrow @nogc:

package(flint.engine.mail) struct ProviderId
{
    ubyte[maximumReceiptBytes] data;
    size_t length;
}

private struct Text
{
    size_t start;
    size_t end;
}

private struct Json
{
    const(ubyte)[] input;
    size_t offset;

pure nothrow @nogc:

    ubyte peek() const scope
    {
        return offset < input.length ? input[offset] : 0;
    }

    void space() scope
    {
        while (offset < input.length && (peek() == ' ' || peek() == '\r' || peek() == '\n' || peek() == '\t'))
            ++offset;
    }

    bool take(ubyte symbol) scope
    {
        if (offset == input.length || peek() != symbol)
            return false;
        ++offset;
        return true;
    }

    bool token(string literal) scope
    {
        if (literal.length > input.length - offset
                || input[offset .. offset + literal.length] != cast(const(ubyte)[]) literal)
            return false;
        offset += literal.length;
        return true;
    }

    bool text(out Text value) scope
    {
        if (!take('"'))
            return false;
        value.start = offset;
        while (offset < input.length)
        {
            const mark = input[offset++];
            if (mark == '"')
            {
                value.end = offset - 1;
                return true;
            }
            if (mark < 32 || (mark == '\\' && !escape()))
                return false;
        }
        return false;
    }

    private bool escape() scope
    {
        if (offset == input.length)
            return false;
        const mark = input[offset++];
        foreach (item; "\"\\/bfnrt")
            if (item == mark)
                return true;
        if (mark != 'u')
            return false;
        const code = scalarPart();
        if (code < 0 || (code >= 0xdc00 && code <= 0xdfff))
            return false;
        if (code < 0xd800 || code > 0xdbff)
            return true;
        if (!take('\\') || !take('u'))
            return false;
        const low = scalarPart();
        return low >= 0xdc00 && low <= 0xdfff;
    }

    private int scalarPart() scope
    {
        if (input.length - offset < 4)
            return -1;
        int result;
        foreach (ignored; 0 .. 4)
        {
            const part = nibble(input[offset++]);
            if (part < 0)
                return -1;
            result = (result << 4) | part;
        }
        return result;
    }

    bool number() scope
    {
        if (!take('0'))
        {
            take('-');
            if (!take('0') && !digits())
                return false;
        }
        if (take('.') && !digits())
            return false;
        if (take('e') || take('E'))
        {
            if (!take('-'))
                take('+');
            return digits();
        }
        return true;
    }

    private bool digits() scope
    {
        const start = offset;
        while (peek() >= '0' && peek() <= '9')
            ++offset;
        return offset != start;
    }

    bool skip(uint depth) scope
    {
        if (depth == 32)
            return false;
        space();
        if (peek() == '[' || peek() == '{')
            return collection(depth + 1);
        if (peek() == '"')
        {
            Text ignored;
            return text(ignored);
        }
        return token("null") || token("true") || token("false") || number();
    }

    private bool collection(uint depth) scope
    {
        const object = take('{');
        if (!object)
            take('[');
        const end = cast(ubyte)(object ? '}' : ']');
        space();
        if (take(end))
            return true;
        while (true)
        {
            space();
            if (object)
            {
                Text field;
                if (!text(field))
                    return false;
                space();
                if (!take(':'))
                    return false;
            }
            if (!skip(depth))
                return false;
            space();
            if (take(end))
                return true;
            if (!take(','))
                return false;
        }
    }
}

private int nibble(ubyte character)
{
    if (character >= '0' && character <= '9')
        return character - '0';
    if (character >= 'a' && character <= 'f')
        return character - 'a' + 10;
    if (character >= 'A' && character <= 'F')
        return character - 'A' + 10;
    return -1;
}

private bool visible(scope const(ubyte)[] spelling, scope ubyte[] plain, out size_t written)
{
    size_t cursor;
    while (cursor < spelling.length)
    {
        uint item = spelling[cursor++];
        if (item == '\\')
        {
            const escaped = spelling[cursor++];
            if (escaped == 'u')
            {
                item = 0;
                foreach (ignored; 0 .. 4)
                    item = item * 16 + cast(uint) nibble(spelling[cursor++]);
            }
            else if (escaped == '"' || escaped == '\\' || escaped == '/')
                item = escaped;
            else
                return false;
        }
        if (item < ' ' || item > 126 || written == plain.length)
            return false;
        plain[written++] = cast(ubyte) item;
    }
    return true;
}

private bool matches(scope const ref Json json, Text token, string literal)
{
    ubyte[32] buffer;
    size_t used;
    return visible(json.input[token.start .. token.end], buffer[], used)
        && buffer[0 .. used] == cast(const(ubyte)[]) literal;
}

private Error malformed()
{
    return Error(Status.unavailable, "mail provider acceptance receipt is missing or malformed");
}

private struct Fields
{
    bool seen;
    bool errorSeen;
    uint postmarkCode;
}

private bool identifier(ref scope Json json, ref ProviderId provider, ref Fields fields)
{
    Text value;
    if (fields.seen || !json.text(value))
        return false;
    fields.seen = true;
    return visible(json.input[value.start .. value.end], provider.data[], provider.length) && provider.length != 0;
}

private bool errorCode(ref scope Json json, ref Fields fields)
{
    if (fields.errorSeen)
        return false;
    fields.errorSeen = true;
    const start = json.offset;
    if (!json.number() || json.offset - start > 5)
        return false;
    foreach (digit; json.input[start .. json.offset])
    {
        if (digit < '0' || digit > '9')
            return false;
        fields.postmarkCode = fields.postmarkCode * 10 + digit - '0';
    }
    return true;
}

private bool record(ref scope Json json, Text token, MailBackend backend, ref ProviderId provider, ref Fields fields)
{
    const key = backend == MailBackend.ses ? "MessageId" : backend == MailBackend.resend ? "id" : "MessageID";
    if (matches(json, token, key))
        return identifier(json, provider, fields);
    if (backend == MailBackend.postmark && matches(json, token, "ErrorCode"))
        return errorCode(json, fields);
    return json.skip(0);
}

private bool parseObject(ref scope Json json, MailBackend backend, ref ProviderId provider, ref Fields fields)
{
    json.space();
    if (!json.take('{'))
        return false;
    while (true)
    {
        json.space();
        Text token;
        if (!json.text(token))
            return false;
        json.space();
        if (!json.take(':'))
            return false;
        json.space();
        if (!record(json, token, backend, provider, fields))
            return false;
        json.space();
        if (json.take('}'))
            break;
        if (!json.take(','))
            return false;
    }
    json.space();
    return json.offset == json.input.length;
}

package(flint.engine.mail) Error providerReply(scope const(ubyte)[] body, MailBackend backend, out ProviderId provider)
{
    if (!body.length || !headerText(cast(const(char)[])
            body, 16_384, true))
        return malformed();
    scope json = Json(body);
    Fields fields;
    if (!parseObject(json, backend, provider, fields))
        return malformed();
    if (backend == MailBackend.postmark && fields.postmarkCode != 0)
        return postmarkRejection(fields.postmarkCode);
    if (!fields.seen || (backend == MailBackend.postmark && !fields.errorSeen))
        return malformed();
    return Error.init;
}

private Error postmarkRejection(uint code)
{
    switch (code)
    {
    case 10:
    case 14:
    case 413:
        return Error(Status.permissionDenied, "Postmark denied submission");
    case 100:
    case 101:
        return Error(Status.unavailable, "Postmark could not accept the submission");
    default:
        return Error(Status.invalidArgument, "Postmark rejected the message");
    }
}
