module template_reference;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import template_replay : benchmark, require;

@safe:

private string entity(char ch) pure nothrow @nogc
{
    switch (ch)
    {
    case '<':
        return "&lt;";
    case '&':
        return "&amp;";
    case '\'':
        return "&#39;";
    default:
        return null;
    }
}

private Result!Buffer renderBody(scope const(char)[] body, ref scope RequestArena arena) nothrow @nogc
{
    enum header = "<main>";
    enum footer = "</main>";
    size_t length = header.length + footer.length;
    foreach (ch; body)
    {
        const escaped = entity(ch);
        length += escaped is null ? 1 : escaped.length;
    }
    const result = arena.allocate(length, 1);
    if (!result.ok())
        return result;
    const stored = arena.write(result.value, (scope ubyte[] output) @safe nothrow @nogc {
        output[0 .. header.length] = cast(const(ubyte)[]) header;
        size_t cursor = header.length;
        foreach (ch; body)
        {
            const escaped = entity(ch);
            if (escaped is null)
                output[cursor++] = cast(ubyte) ch;
            else
            {
                output[cursor .. cursor + escaped.length] = cast(const(ubyte)[]) escaped;
                cursor += escaped.length;
            }
        }
        require(cursor + footer.length == output.length);
        output[cursor .. $] = cast(const(ubyte)[]) footer;
    });
    return stored == Status.ok ? result : Result!Buffer(Buffer.init, Error(stored));
}

int main(string[] args)
{
    benchmark(&renderBody, args.length > 1 && args[1] == "--measure");
    return 0;
}
