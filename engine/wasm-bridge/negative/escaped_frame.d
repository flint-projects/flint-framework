module escaped_frame;

import flint.arena : Error;
import flint.wasm_bridge : CommandBuffer;

private const(ubyte)[] saved;

/// A scoped frame observation cannot publish a borrowed slice.
Error escape(ref CommandBuffer output) @safe nothrow @nogc
{
    return output.visit((scope const(ubyte)[] bytes) @safe nothrow @nogc { saved = bytes; });
}
