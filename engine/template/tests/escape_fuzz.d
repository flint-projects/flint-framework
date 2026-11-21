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
