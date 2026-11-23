/// Validation of version-1 little-endian desktop draw lists.
module flint.engine.desktop.commands;

import flint.arena : Error, Status;
import flint.engine.wasm_bridge : abiVersion;

@safe:
nothrow @nogc:

package(flint.engine.desktop) enum drawMaximum = 16_384;
package(flint.engine.desktop) enum clipMaximum = 32;

private enum Operation : ubyte
{
    clear = 1,
    rectangle,
    glyphs,
    image,
    clip,
    unclip
}

private enum invalid = Error(Status.invalidArgument, "invalid desktop draw-list record");
private enum maximumCoordinate = 16_384;
private enum headerBytes = 8;
private enum recordBytes = 4;

/// Check the complete list before it can enter a shared queue.
package(flint.engine.desktop) Error validateDrawList(scope const(ubyte)[] bytes)
{
    if (bytes.length > drawMaximum)
        return Error(Status.resourceExhausted, "desktop draw list exceeds its command slot");
    if (bytes.length < headerBytes || bytes[0 .. 3] != cast(const(ubyte)[]) "FDL"
            || bytes[3] != abiVersion || word(bytes[6 .. 8]) != 0)
        return Error(Status.invalidArgument, "invalid desktop draw-list header");

    const operations = word(bytes[4 .. 6]);
    if (operations > 1024)
        return Error(Status.resourceExhausted, "desktop draw list exceeds 1024 records");
    size_t offset = headerBytes;
    uint depth;
    foreach (_; 0 .. operations)
    {
        const code = advance(bytes, offset, depth);
        if (code != Status.ok)
            return Error(code, invalid.message, offset);
    }
    return offset == bytes.length && depth == 0 ? Error.init : invalid;
}

private Status advance(scope const(ubyte)[] bytes, ref size_t offset, ref uint depth)
{
    if (bytes.length - offset < recordBytes)
        return Status.invalidArgument;
    const next = bytes[offset .. offset + recordBytes];
    offset += recordBytes;
    const length = word(next[2 .. 4]);
    if (next[1] != 0 || length > bytes.length - offset)
        return Status.invalidArgument;
    const value = bytes[offset .. offset + length];
    const valid = payload(cast(Operation) next[0], value, depth);
    offset += length;
    return valid;
}

private Status payload(Operation operation, scope const(ubyte)[] data, ref uint depth)
{
    switch (operation)
    {
    case Operation.clear:
        return data.length == 4 ? Status.ok : Status.invalidArgument;
    case Operation.rectangle:
        return data.length == 20 && geometry(data) ? Status.ok : Status.invalidArgument;
    case Operation.glyphs:
        return glyphs(data) ? Status.ok : Status.invalidArgument;
    case Operation.image:
        return image(data) ? Status.ok : Status.invalidArgument;
    case Operation.clip:
        return pushClip(data, depth);
    case Operation.unclip:
        return popClip(data, depth);
    default:
        return Status.invalidArgument;
    }
}

private Status pushClip(scope const(ubyte)[] data, ref uint depth)
{
    if (data.length != 16 || !geometry(data))
        return Status.invalidArgument;
    if (depth == clipMaximum)
        return Status.resourceExhausted;
    ++depth;
    return Status.ok;
}

private Status popClip(scope const(ubyte)[] data, ref uint depth)
{
    if (data.length || !depth)
        return Status.invalidArgument;
    --depth;
    return Status.ok;
}

private bool image(scope const(ubyte)[] data)
{
    return data.length == 24 && geometry(data) && word(data[16 .. 18]) == 1 && word(data[18 .. 20]) == 0;
}

private bool glyphs(scope const(ubyte)[] data)
{
    if (data.length < 16 || !position(data) || word(data[8 .. 10]) != 1)
        return false;
    const length = word(data[10 .. 12]);
    if (!length || length > 1024 || data.length != length + 16)
        return false;
    foreach (letter; data[16 .. $])
    {
        if (letter < 0x20 || letter > 0x7e)
            return false;
    }
    return true;
}

private bool geometry(scope const(ubyte)[] data)
{
    const width = dword(data[8 .. 12]);
    const height = dword(data[12 .. 16]);
    return position(data) && width <= maximumCoordinate && height <= maximumCoordinate;
}

private bool position(scope const(ubyte)[] data)
{
    const x = cast(int) dword(data[0 .. 4]);
    const y = cast(int) dword(data[4 .. 8]);
    return x >= -maximumCoordinate && x <= maximumCoordinate && y >= -maximumCoordinate && y <= maximumCoordinate;
}

private ushort word(scope const(ubyte)[] data)
{
    return cast(ushort)(cast(uint) data[0] | (cast(uint) data[1] << 8));
}

private uint dword(scope const(ubyte)[] data)
{
    return cast(uint) word(data[0 .. 2]) | (cast(uint) word(data[2 .. 4]) << 16);
}
