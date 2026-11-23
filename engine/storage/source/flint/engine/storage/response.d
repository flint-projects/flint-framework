/// Copy only the known metadata from the final HTTP response head.
module flint.engine.storage.response;

import flint.arena : Buffer, Error, Arena = RequestArena, Result, Status;
import flint.engine.storage.encoding : parseDecimal, sameAscii;
import flint.engine.storage.types : ObjectInfo;

@safe:

package(flint.engine.storage) alias FieldVisitor = void delegate(scope const(char)[] value) @safe nothrow @nogc;
package(flint.engine.storage) enum maximumEtag = 256;

package(flint.engine.storage) Error field(Buffer headers, string name, ref scope Arena arena,
        scope FieldVisitor consume, bool required = false) nothrow @nogc
{
    bool found;
    bool repeated;
    const status = arena.read(headers, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        size_t first;
        const text = cast(const(char)[]) bytes;
        foreach (index, item; text)
        {
            if (item != '\n')
                continue;
            const line = text[first .. index];
            first = index + 1;
            const value = headerValue(line, name);
            if (value.length != 0)
            {
                repeated |= found;
                if (!found)
                    consume(value);
                found = true;
            }
        }
    });
    if (status != Status.ok || repeated || (required && !found))
        return Error(Status.ioError, "missing or ambiguous S3 response header");
    return Error.init;
}

private const(char)[] headerValue(return scope const(char)[] line, string name) pure nothrow @nogc
{
    if (line.length <= name.length || line[name.length] != ':' || !sameAscii(line[0 .. name.length], name))
        return null;
    size_t begin = name.length + 1;
    size_t end = line.length;
    while (begin < end && padding(line[begin]))
        ++begin;
    while (begin < end && padding(line[end - 1]))
        --end;
    return line[begin .. end];
}

private bool padding(char value) pure nothrow @nogc
{
    return value == ' ' || value == '\t' || value == '\r';
}

package(flint.engine.storage) Result!ObjectInfo readHead(Buffer headers, ref scope Arena arena) nothrow @nogc
{
    ObjectInfo object;
    bool lengthValid;
    const count = field(headers, "content-length", arena, (scope const(char)[] value) {
        const available = parseDecimal(value);
        lengthValid = available.ok;
        object.size = available.value;
    }, true);
    if (count.code != Status.ok || !lengthValid)
        return Result!ObjectInfo(ObjectInfo.init, Error(Status.ioError, "invalid S3 object content length"));
    return readIdentity(headers, object.size, arena);
}

package(flint.engine.storage) nothrow @nogc Result!ObjectInfo readIdentity(Buffer headers,
        ulong size, ref scope Arena arena)
{
    Result!Buffer etag;
    Result!Buffer revision;
    const received = field(headers, "etag", arena, (scope const(char)[] value) {
        if (value.length > maximumEtag)
            etag.error = Error(Status.resourceExhausted, "S3 ETag exceeds its limit");
        else
            etag = arena.copyIn(cast(const(ubyte)[]) value);
    }, true);
    if (received.code != Status.ok || !etag.ok)
        return Result!ObjectInfo(ObjectInfo.init, received.code != Status.ok ? received : etag.error);
    const copied = field(headers, "x-amz-version-id", arena, (scope const(char)[] value) {
        if (value.length > 1_024)
            revision.error = Error(Status.resourceExhausted, "S3 version ID exceeds its limit");
        else
            revision = arena.copyIn(cast(const(ubyte)[]) value);
    });
    if (copied.code != Status.ok || !revision.ok)
        return Result!ObjectInfo(ObjectInfo.init, copied.code != Status.ok ? copied : revision.error);
    return Result!ObjectInfo(ObjectInfo(size, etag.value, revision.value));
}
