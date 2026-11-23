module flint.engine.actuator.text;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.serde : encodeJson;

@safe:

package(flint.engine.actuator) struct TextWriter
{
    Buffer bytes;
    Error error;

    void open(ref scope RequestArena arena) nothrow @nogc
    {
        const allocation = arena.allocate(0, 1);
        bytes = allocation.value;
        error = allocation.error;
    }

    void put(ref scope RequestArena arena, scope const(char)[] text) nothrow @nogc
    {
        if (error.code != Status.ok)
            return;
        const status = arena.append(bytes, cast(const(ubyte)[]) text);
        if (status != Status.ok)
            error = Error(status, "management output exceeds its arena");
    }

    void integer(ref scope RequestArena arena, ulong value) nothrow @nogc
    {
        char[20] digits;
        size_t start = digits.length;
        do
        {
            digits[--start] = cast(char)('0' + value % 10);
            value /= 10;
        }
        while (value != 0);
        put(arena, digits[start .. $]);
    }

    void hex(ref scope RequestArena arena, scope const(ubyte)[] value) nothrow @nogc
    {
        enum digits = "0123456789abcdef";
        char[32] encoded;
        assert(value.length <= encoded.length / 2);
        foreach (i, byteValue; value)
        {
            encoded[2 * i] = digits[byteValue >> 4];
            encoded[2 * i + 1] = digits[byteValue & 15];
        }
        put(arena, encoded[0 .. 2 * value.length]);
    }

    void quoted(ref scope RequestArena arena, scope const(char)[] value) nothrow @nogc
    {
        ubyte[4096] scratch;
        scope RequestArena temporary = RequestArena(scratch[]);
        const encoded = encodeJson(value, temporary);
        copy(arena, temporary, encoded);
    }

    void number(ref scope RequestArena arena, double value) nothrow @nogc
    {
        ubyte[1100] scratch;
        scope RequestArena temporary = RequestArena(scratch[]);
        const encoded = encodeJson(value, temporary);
        copy(arena, temporary, encoded);
    }

    private void copy(ref scope RequestArena to, ref scope RequestArena from, Result!Buffer value) nothrow @nogc
    {
        if (error.code != Status.ok)
            return;
        if (!value.ok)
        {
            error = value.error;
            return;
        }
        const read = from.read(value.value, (scope const(ubyte)[] data) @safe nothrow @nogc {
            put(to, cast(const(char)[]) data);
        });
        if (read != Status.ok)
            error = Error(read, "encoded management value is invalid");
    }
}
