/// Compile-time HTML resources with checked contextual escaping.
module flint.templates;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.templates.internal.emit : draw;
import flint.templates.output : Writer, urlPolicy;
public import flint.templates.types : HtmlTemplate, TrustedHtml;

@safe:

/// Compile and render a checked resource into a caller-owned arena buffer.
Result!Buffer render(string fileName, Model)(scope const ref Model model, ref scope RequestArena arena) nothrow @nogc
{
    Writer count;
    draw!fileName(model, count, arena);
    if (count.failure.code != Status.ok)
        return Result!Buffer(Buffer.init, count.failure);
    const bytes = arena.allocate(count.length, 1);
    if (!bytes.ok())
        return bytes;
    Status outputStatus;
    const populated = arena.write(bytes.value, (scope ubyte[] output) @safe nothrow @nogc {
        scope writer = Writer(output);
        draw!fileName(model, writer, arena);
        outputStatus = writer.failure.code;
        if (outputStatus == Status.ok && writer.length != output.length)
            outputStatus = Status.conflict;
    });
    if (populated != Status.ok)
        return Result!Buffer(Buffer.init, Error(populated, "template output buffer is unavailable"));
    return outputStatus == Status.ok ? bytes : Result!Buffer(Buffer.init, Error(outputStatus,
            "template rendering failed"));
}

/// Escape UTF-8 text into a caller-owned arena buffer.
Result!Buffer escapeHtml(scope const(ubyte)[] text, ref scope RequestArena arena) nothrow @nogc
{
    Writer count;
    count.escaped(cast(const(char)[]) text);
    if (count.failure.code != Status.ok)
        return Result!Buffer(Buffer.init, count.failure);
    const bytes = arena.allocate(count.length, 1);
    if (!bytes.ok())
        return bytes;
    Status failure;
    const stored = arena.write(bytes.value, (scope ubyte[] output) @safe nothrow @nogc {
        scope writer = Writer(output);
        writer.escaped(cast(const(char)[]) text);
        failure = writer.failure.code;
    });
    if (stored != Status.ok)
        return Result!Buffer(Buffer.init, Error(stored, "escaped buffer is unavailable"));
    return failure == Status.ok ? bytes : Result!Buffer(Buffer.init, Error(failure, "escaping failed"));
}

/// Check one entire URL attribute under the fixed relative/HTTP/HTTPS/mail policy.
Error validateUrl(scope const(char)[] url) nothrow @nogc
{
    return urlPolicy(url);
}
