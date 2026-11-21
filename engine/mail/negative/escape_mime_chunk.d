module flint.mail.negative.escape_mime_chunk;

import flint.arena : Error;
import flint.mail.mime : MailSink;

@safe nothrow @nogc:
private const(ubyte)[] escaped;

/// Forbid keeping the serializer's transient chunk after the callback.
Error rejectEscape(scope const(ubyte)[] sample)
{
    scope const MailSink consume = delegate Error(scope const(ubyte)[] chunk) @safe nothrow @nogc {
        escaped = chunk;
        return Error.init;
    };
    return consume(sample);
}
