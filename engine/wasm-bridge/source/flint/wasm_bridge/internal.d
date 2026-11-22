module flint.wasm_bridge.internal;

@safe:
pure:
nothrow:
@nogc:

package(flint.wasm_bridge) void write16(scope ubyte[] destination, size_t offset, uint value)
{
    destination[offset] = cast(ubyte) value;
    destination[offset + 1] = cast(ubyte)(value >> 8);
}

package(flint.wasm_bridge) void write32(scope ubyte[] destination, size_t offset, uint value)
{
    write16(destination, offset, value);
    write16(destination, offset + 2, value >> 16);
}

package(flint.wasm_bridge) uint read32(scope const(ubyte)[] input, size_t offset)
{
    uint result;
    foreach_reverse (value; input[offset .. offset + 4])
        result = (result << 8) | value;
    return result;
}

private bool validSecond(ubyte first, ubyte second)
{
    switch (first)
    {
    case 0xe0:
        return second >= 0xa0;
    case 0xed:
        return second < 0xa0;
    case 0xf0:
        return second >= 0x90;
    case 0xf4:
        return second < 0x90;
    default:
        return true;
    }
}

package(flint.wasm_bridge) bool validUtf8(scope const(ubyte)[] input)
{
    while (input.length != 0)
    {
        const first = input[0];
        input = input[1 .. $];
        if (first < 128)
            continue;
        if (first < 0xc2 || first > 0xf4)
            return false;
        const count = first <= 0xdf ? 1 : first <= 0xef ? 2 : 3;
        if (input.length < count || !validSecond(first, input[0]))
            return false;
        foreach (next; input[0 .. count])
            if (next < 0x80 || next > 0xbf)
                return false;
        input = input[count .. $];
    }
    return true;
}

// Pack a fixed-width prefix into a little-endian word. Array equality would lower to memcmp,
// which a freestanding wasm32 module does not have, and this form is also faster.
private ulong word(size_t count)(scope const(ubyte)[] input)
{
    const bytes = input[0 .. count];
    ulong value;
    static foreach (index; 0 .. count)
        value |= cast(ulong) bytes[index] << (8 * index);
    return value;
}

package(flint.wasm_bridge) bool permittedAttribute(scope const(ubyte)[] input)
{
    enum title = word!5(cast(const(ubyte)[]) "title");
    enum klass = word!5(cast(const(ubyte)[]) "class");
    enum value = word!5(cast(const(ubyte)[]) "value");
    enum data = word!5(cast(const(ubyte)[]) "data-");
    enum aria = word!8(cast(const(ubyte)[]) "aria-lab");
    enum label = word!2(cast(const(ubyte)[]) "el");
    if (input.length == 5)
    {
        const name = word!5(input);
        return name == title || name == klass || name == value;
    }
    if (input.length == 10 && word!8(input) == aria && word!2(input[8 .. $]) == label)
        return true;
    if (input.length < 6 || word!5(input) != data)
        return false;
    foreach (character; input[5 .. $])
        if ((character < 'a' || character > 'z') && (character < '0' || character > '9') && character != '-')
            return false;
    return true;
}

package(flint.wasm_bridge) bool rectangle(scope const(ubyte)[] input)
{
    if (input.length != 24 || read32(input, 0) != 1)
        return false;
    const x = read32(input, 4);
    const y = read32(input, 8);
    return x <= 300 && y <= 150 && read32(input, 12) <= 300 - x && read32(input, 16) <= 150 - y;
}

package(flint.wasm_bridge) bool clearColor(scope const(ubyte)[] input)
{
    if (input.length != 20 || read32(input, 0) != 1)
        return false;
    foreach (offset; 1 .. 5)
    {
        const bits = read32(input, offset * 4);
        if (bits > 0x3f800000 && bits != 0x80000000)
            return false;
    }
    return true;
}
