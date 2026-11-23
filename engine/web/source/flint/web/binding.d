/// Arena-backed path, query, JSON and validation bindings for generated actions.
module flint.web.binding;

import flint.arena : Buffer, Error, RequestArena, Result, Status, Text;
import flint.serde : decodeInto, encodeJson;
import flint.validate : Violation, validateIn;
import flint.web.router : decodedEqual, maximumTargetBytes, nextByte;
import flint.web.types : Method, Request, RequestContext, Response;

@safe:
package(flint.web):

enum signedScalar(T) = is(T == byte) || is(T == short) || is(T == int) || is(T == long);
enum unsignedScalar(T) = is(T == ubyte) || is(T == ushort) || is(T == uint) || is(T == ulong);
enum scalar(T) = signedScalar!T || unsignedScalar!T || is(T == Text) || is(T == bool) || is(T == string);

/// A `string` path or query argument: decoded like `Text`, then copied to the GC heap. Only handlers that are not
/// `@nogc` take one (ADR-028 section 3).
Error bindPath(T : string)(ref scope Request request, ref scope RequestArena arena, string name, ref T output) nothrow
{
    Text text;
    const failed = bindPath(request, arena, name, text);
    return failed.code == Status.ok ? ownedText(arena, text, output) : failed;
}

/// ditto
Error bindQuery(T : string)(ref scope const Request request, ref scope RequestArena arena, string name,
        bool required, ref T output) nothrow
{
    Text text;
    const failed = bindQuery(request, arena, name, required, text);
    return failed.code == Status.ok ? ownedText(arena, text, output) : failed;
}

private Error ownedText(ref scope RequestArena arena, Text text, ref string output) nothrow
{
    ubyte[maximumTargetBytes] copied;
    size_t length;
    const read = arena.read(text.bytes, (scope const(ubyte)[] value) @safe nothrow @nogc {
        length = value.length <= copied.length ? value.length : copied.length;
        copied[0 .. length] = value[0 .. length];
    });
    if (read != Status.ok)
        return Error(read, "expired HTTP argument");
    output = (cast(const(char)[]) copied[0 .. length]).idup;
    return Error.init;
}

Error bindPath(T)(ref scope Request request, ref scope RequestArena arena, string name, ref T output) nothrow @nogc
        if (!is(T == string))
{
    auto capture = request.capture(name);
    auto path = request.path();
    if (!capture.ok() || !path.ok())
        return Error(Status.invalidArgument, "missing HTTP path argument");
    return bindBuffer(path.value, capture.value.start, capture.value.end, false, arena, output);
}

Error bindQuery(T)(ref scope const Request request, ref scope RequestArena arena, string name,
        bool required, ref T output) nothrow @nogc if (!is(T == string))
{
    auto query = request.query();
    if (!query.ok())
        return query.error;

    QuerySpan span;
    const checked = arena.read(query.value, (scope const(ubyte)[] value) @safe nothrow @nogc {
        span = locateQuery(value, name);
    });
    if (checked != Status.ok || span.invalid)
        return Error(Status.invalidArgument, "invalid or repeated HTTP query argument", span.start);
    if (!span.found)
        return required ? Error(Status.invalidArgument, "required HTTP query argument is missing") : Error.init;
    return bindBuffer(query.value, span.start, span.end, true, arena, output);
}

private struct QuerySpan
{
    bool found;
    bool invalid;
    size_t start;
    size_t end;
}

private QuerySpan locateQuery(scope const(ubyte)[] bytes, string name) nothrow @nogc
{
    QuerySpan result;
    size_t position;
    while (position < bytes.length)
    {
        const start = position;
        while (position < bytes.length && bytes[position] != '&' && bytes[position] != '=')
            ++position;
        const key = bytes[start .. position];
        if (position < bytes.length && bytes[position] == '=')
            ++position;
        const valueStart = position;
        while (position < bytes.length && bytes[position] != '&')
            ++position;
        if (!validForm(key) || !validForm(bytes[valueStart .. position]))
            return QuerySpan(false, true, start);
        if (decodedEqual(key, name, true))
        {
            if (result.found)
                return QuerySpan(false, true, start);
            result = QuerySpan(true, false, valueStart, position);
        }
        if (position < bytes.length)
            ++position;
    }
    return result;
}

private bool validForm(scope const(ubyte)[] bytes) nothrow @nogc
{
    size_t position;
    while (position < bytes.length)
    {
        if (nextByte(bytes, position, true) <= 0)
            return false;
    }
    return true;
}

private Error bindBuffer(T)(Buffer buffer, size_t start, size_t end, bool form, ref scope RequestArena arena,
        ref T output) nothrow @nogc
{
    if (start > end || end > buffer.length() || end - start > maximumTargetBytes)
        return Error(Status.invalidArgument, "invalid HTTP argument range");
    Error result;
    static if (is(T == Text))
    {
        ubyte[maximumTargetBytes] decoded;
        size_t length;
        const verified = arena.read(buffer, (scope const(ubyte)[] value) @safe nothrow @nogc {
            const selected = value[start .. end];
            size_t position;
            while (position < selected.length)
            {
                const byteValue = nextByte(selected, position, form);
                if (byteValue <= 0)
                {
                    result = Error(Status.invalidArgument, "invalid HTTP argument escape", start + position);
                    return;
                }
                decoded[length++] = cast(ubyte) byteValue;
            }
        });
        if (verified != Status.ok)
            return Error(verified, "expired HTTP argument");
        if (result.code != Status.ok)
            return result;
        auto copy = arena.copyIn(decoded[0 .. length]);
        if (copy.ok())
            output = Text(copy.value);
        return copy.error;
    }
    else
    {
        const verified = arena.read(buffer, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            if (!parseScalar(bytes[start .. end], form, output))
                result = Error(Status.invalidArgument, "invalid HTTP scalar argument", start);
        });
        return verified == Status.ok ? result : Error(verified, "expired HTTP argument");
    }
}

private bool parseScalar(T)(scope const(ubyte)[] bytes, bool form, ref T output) nothrow @nogc
{
    static if (is(T == bool))
    {
        if (decodedEqual(bytes, "true", form))
            output = true;
        else if (decodedEqual(bytes, "false", form))
            output = false;
        else
            return false;
        return true;
    }
    else
    {
        size_t position;
        int next = nextByte(bytes, position, form);
        const negative = next == '-';
        if (negative)
        {
            static if (unsignedScalar!T)
                return false;
            next = nextByte(bytes, position, form);
        }
        const limit = cast(ulong) T.max + (negative ? 1UL : 0UL);
        ulong magnitude;
        for (;;)
        {
            if (next < '0' || next > '9')
                return false;
            const digit = cast(uint)(next - '0');
            if (magnitude > (limit - digit) / 10)
                return false;
            magnitude = magnitude * 10 + digit;
            if (position == bytes.length)
                break;
            next = nextByte(bytes, position, form);
        }
        static if (signedScalar!T)
            output = negative ? (magnitude == limit ? T.min : cast(T)(-cast(long) magnitude)) : cast(T) magnitude;
        else
            output = cast(T) magnitude;
        return true;
    }
}

Error bindBody(T)(ref scope const Request request, ref scope RequestArena arena, ref T output) nothrow @nogc
{
    const payload = request.body();
    if (!payload.ok())
        return payload.error;
    Error result;
    const verified = arena.read(payload.value, (scope const(ubyte)[] value) @safe nothrow @nogc {
        result = decodeInto(value, output, arena);
    });
    return verified == Status.ok ? result : Error(verified, "expired HTTP request body");
}

private struct ValidationReply
{
    string error = "validation failed";
    string field;
    string constraint;
}

bool validateBody(T)(scope const ref T body, ref scope RequestArena arena, out Result!Response rejected) nothrow @nogc
{
    Violation[1] issues;
    const report = validateIn(body, arena, issues[]);
    if (report.valid)
        return true;

    const reply = ValidationReply("validation failed", issues[0].field, issues[0].constraint);
    auto output = encodeJson(reply, arena);
    if (output.ok())
        rejected = Result!Response(Response(400, "application/json", output.value));
    else
        rejected.error = output.error;
    return false;
}

Result!Response responseFor(T)(T value, ref scope RequestContext context, Method method) nothrow @nogc
{
    static if (is(T == Response))
        return Result!Response(value);
    else static if (is(T == Error))
        return value.code == Status.ok ? Result!Response(Response(204, null,
                Buffer.init)) : Result!Response(Response.init, value);
    else static if (is(T == Result!Value, Value))
    {
        if (!value.ok())
            return Result!Response(Response.init, value.error);
        static if (is(Value == Response))
            return value;
        else
        {
            auto output = encodeJson(value.value, context.arena);
            if (!output.ok())
                return Result!Response(Response.init, output.error);
            enum entity = is(Value == struct);
            const status = method == Method.post && entity ? cast(ushort) 201 : cast(ushort) 200;
            return Result!Response(Response(status, "application/json", output.value));
        }
    }
    else
        static assert(false, "Web handler return must be Response, Error or Result!T");
}
