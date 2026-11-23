module copy_frame;

import flint.engine.wasm_bridge : CommandBuffer;

/// A second frame owner cannot be copied from the first.
uint duplicate(ref CommandBuffer output) @safe nothrow @nogc
{
    const copy = output;
    return copy.usedBytes();
}
