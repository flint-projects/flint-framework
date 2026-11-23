module flint.engine.desktop.draw_list_tests;

import flint.arena : Status;
import flint.engine.desktop.commands : validateDrawList;

@safe:

@("Draw-list versions, record lengths, geometry and resource identities")
unittest
{
    immutable ubyte[] clear = [0x46, 0x44, 0x4c, 1, 1, 0, 0, 0, 1, 0, 4, 0, 17, 49, 83, 255];
    assert(validateDrawList(clear).code == Status.ok);
    foreach (length; 0 .. clear.length)
        assert(validateDrawList(clear[0 .. length]).code == Status.invalidArgument);

    auto broken = clear.dup;
    broken[3] = 2;
    assert(validateDrawList(broken).code == Status.invalidArgument);
    broken[] = clear[];
    broken[10] = 5;
    assert(validateDrawList(broken).code == Status.invalidArgument);
    broken[] = clear[];
    broken[8] = 6;
    broken[10] = 0;
    assert(validateDrawList(broken[0 .. 12]).code == Status.invalidArgument);
    assert(validateDrawList(new ubyte[16_385]).code == Status.resourceExhausted);

    auto rect = new ubyte[32];
    rect[0 .. 8] = clear[0 .. 8];
    rect[8] = 2;
    rect[10] = 20;
    assert(validateDrawList(rect).code == Status.ok);
    rect[15] = 0x80;
    assert(validateDrawList(rect).code == Status.invalidArgument);
    rect[15] = 0;
    rect[23] = 0x80;
    assert(validateDrawList(rect).code == Status.invalidArgument);

    auto image = new ubyte[36];
    image[0 .. 8] = clear[0 .. 8];
    image[8] = 4;
    image[10] = 24;
    image[28] = 1;
    assert(validateDrawList(image).code == Status.ok);
    image[28] = 2;
    assert(validateDrawList(image).code == Status.invalidArgument);
}

@("Glyph and clip bounds are validated before queue admission")
unittest
{
    ubyte[29] glyph;
    glyph[0 .. 11] = [0x46, 0x44, 0x4c, 1, 1, 0, 0, 0, 3, 0, 17];
    glyph[20] = 1;
    glyph[22] = 1;
    glyph[28] = 'x';
    assert(validateDrawList(glyph[]).code == Status.ok);
    glyph[28] = 0;
    assert(validateDrawList(glyph[]).code == Status.invalidArgument);

    enum count = 33;
    ubyte[8 + count * 20 + count * 4] deep;
    deep[0 .. 8] = [0x46, 0x44, 0x4c, 1, count * 2, 0, 0, 0];
    foreach (index; 0 .. count)
    {
        deep[8 + index * 20] = 5;
        deep[10 + index * 20] = 16;
        deep[8 + count * 20 + index * 4] = 6;
    }
    assert(validateDrawList(deep[]).code == Status.resourceExhausted);
}

@("Deterministic draw-list byte mutations stay within the configured parser limits")
unittest
{
    ubyte[1024] data;
    uint value = 0xde1757a1;
    foreach (trial; 0 .. 4096)
    {
        foreach (ref byte_; data)
        {
            value ^= value << 13;
            value ^= value >> 17;
            value ^= value << 5;
            byte_ = cast(ubyte) value;
        }
        data[0 .. 4] = [cast(ubyte) 'F', 'D', 'L', 1];
        data[6 .. 8] = 0;
        const result = validateDrawList(data[0 .. trial % data.length]);
        assert(result.code == Status.ok || result.code == Status.resourceExhausted
                || result.code == Status.invalidArgument);
    }
}
