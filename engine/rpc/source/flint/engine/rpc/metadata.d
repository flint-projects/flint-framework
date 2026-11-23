/// Bounded field access for RFC HTTP metadata delivered by the pinned transport.
module flint.engine.rpc.metadata;

@safe:
package(flint.engine.rpc):

alias MetadataVisitor = void delegate(scope const(char)[] name, scope const(char)[] value) @safe nothrow @nogc;

void visitFields(scope const(ubyte)[] block, scope MetadataVisitor visitor) nothrow @nogc
{
    const text = cast(const(char)[]) block;
    size_t offset;
    while (offset < text.length)
    {
        size_t end = offset;
        while (end < text.length && text[end] != '\n')
            ++end;
        auto line = text[offset .. end];
        offset = end < text.length ? end + 1 : end;
        if (line.length != 0 && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        size_t colon;
        while (colon < line.length && line[colon] != ':')
            ++colon;
        if (colon != 0 && colon < line.length)
            visitor(line[0 .. colon], trimField(line[colon + 1 .. $]));
    }
}

const(char)[] trimField(return scope const(char)[] value) pure nothrow @nogc
{
    while (value.length != 0 && (value[0] == ' ' || value[0] == '\t'))
        value = value[1 .. $];
    while (value.length != 0 && (value[$ - 1] == ' ' || value[$ - 1] == '\t'))
        value = value[0 .. $ - 1];
    return value;
}

bool asciiEqual(scope const(char)[] value, string lowercase) pure nothrow @nogc
{
    if (value.length != lowercase.length)
        return false;
    foreach (index, byteValue; value)
    {
        const candidate = byteValue >= 'A' && byteValue <= 'Z' ? byteValue + ('a' - 'A') : byteValue;
        if (candidate != lowercase[index])
            return false;
    }
    return true;
}

const(char)[] mediaValue(return scope const(char)[] field) pure nothrow @nogc
{
    size_t end;
    while (end < field.length && field[end] != ';')
        ++end;
    return trimField(field[0 .. end]);
}

bool containsToken(scope const(char)[] list, string wanted) pure nothrow @nogc
{
    size_t first;
    foreach (index, value; list)
    {
        if (value == ',')
        {
            if (asciiEqual(trimField(list[first .. index]), wanted))
                return true;
            first = index + 1;
        }
    }
    return asciiEqual(trimField(list[first .. $]), wanted);
}
