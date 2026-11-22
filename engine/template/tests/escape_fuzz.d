module template_escape_fuzz;

import flint.arena : RequestArena, Status;
import flint.templates : escapeHtml, validateUrl;

@safe:

@("All byte prefixes either produce bounded HTML or refuse invalid UTF-8")
unittest
{
    ubyte[256] data;
    uint random = 742;
    foreach (ref byte_; data)
    {
        random = random * 1_664_525U + 1_013_904_223U;
        byte_ = cast(ubyte)(random >> 24);
    }
    ubyte[2_048] scratch;
    scope arena = RequestArena(scratch[]);
    foreach (length; 0 .. 257)
    {
        assert(arena.reset() == Status.ok);
        const case_ = data[0 .. length];
        const escaped = escapeHtml(case_, arena);
        assert(escaped.ok() || escaped.error.code == Status.invalidArgument);
        assert(escaped.value.length() <= 8 * length);
        const url = validateUrl(cast(const(char)[]) case_);
        assert(url.code == Status.ok || url.code == Status.invalidArgument);
    }
    auto bytes = new ubyte[1_048_577];
    bytes[] = 'a';
    auto backing = new ubyte[bytes.length];
    scope large = RequestArena(backing);
    foreach (length; [1_023, 1_024, 1_025, 1_048_575, 1_048_576, 1_048_577])
    {
        assert(large.reset() == Status.ok);
        assert(escapeHtml(bytes[0 .. length], large).value.length() == length);
    }
}

@("ASCII escaping matches a byte-by-byte reference at every run length and position")
unittest
{
    static string reference(ubyte value) pure nothrow @nogc
    {
        switch (value)
        {
        case '&':
            return "&amp;";
        case '<':
            return "&lt;";
        case '>':
            return "&gt;";
        case '"':
            return "&quot;";
        case '\'':
            return "&#39;";
        case 0:
            return "&#xfffd;";
        default:
            return null;
        }
    }

    ubyte[96] input;
    char[96 * 8] expected;
    ubyte[96 * 8] scratch;
    uint random = 1_234_567;
    foreach (round; 0 .. 2_000)
    {
        random = random * 1_664_525U + 1_013_904_223U;
        const length = (random >> 8) % input.length;
        foreach (ref value; input[0 .. length])
        {
            random = random * 1_664_525U + 1_013_904_223U;
            // Mostly plain text with occasional special bytes, so runs of every length occur.
            value = (random >> 28) == 0 ? "&<>\"'\0"[(random >> 8) % 6] : cast(ubyte)(0x20 + (random >> 9) % 0x5f);
        }
        size_t used;
        foreach (value; input[0 .. length])
        {
            const mapped = reference(value);
            if (mapped is null)
                expected[used++] = cast(char) value;
            else
            {
                expected[used .. used + mapped.length] = mapped;
                used += mapped.length;
            }
        }
        scope arena = RequestArena(scratch[]);
        const escaped = escapeHtml(input[0 .. length], arena);
        assert(escaped.ok());
        assert(arena.read(escaped.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
                assert(bytes == cast(const(ubyte)[]) expected[0 .. used]);
            }) == Status.ok);
    }
}
