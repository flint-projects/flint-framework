module flint.engine.wasm_bridge.contract_tests;

import flint.arena : Status;
import flint.engine.wasm_bridge : CommandBuffer, NodeHandle, TagName;
import flint.engine.wasm_bridge.internal : read32, write32;

@safe:

@("exact capacity, atomic failure and nested scoped borrows")
unittest
{
    ubyte[56] storage;
    assert(CommandBuffer.fromStorage(storage[0 .. 31]).error.code == Status.invalidArgument);
    assert(CommandBuffer.fromStorage(storage[], 0).error.code == Status.invalidArgument);
    auto frame = CommandBuffer.fromStorage(storage[], 7);
    assert(frame.ok);
    assert(frame.value.usedBytes == 32 && frame.value.capacityBytes == 56);
    immutable mount = NodeHandle(0, 1);
    immutable node = NodeHandle(1, 1);
    assert(frame.value.setText(mount, cast(const(ubyte)[]) "hi").code == Status.ok);
    assert(frame.value.usedBytes == storage.length);
    const before = storage;
    assert(frame.value.createElement(node, TagName.span).code == Status.resourceExhausted);
    assert(storage == before);
    assert(frame.value.visit((scope const(ubyte)[] bytes) @safe nothrow @nogc {
            assert(bytes[0 .. 4] == cast(const(ubyte)[]) "FLNT");
            assert(read32(bytes, 8) == 56 && read32(bytes, 12) == 1);
            assert(read32(bytes, 16) == 0 && read32(bytes, 20) == 7);
            assert(read32(bytes, 36) == 24 && read32(bytes, 48) == 2);
            assert(bytes[52 .. 54] == cast(const(ubyte)[]) "hi");
            assert(bytes[54 .. 56] == [0, 0]);
            assert(frame.value.remove(node).code == Status.conflict);
            assert(frame.value.visit((scope const(ubyte)[] inner) @safe nothrow @nogc {
                assert(inner == bytes);
            }).code == Status.ok);
            frame.value.clear();
            assert(bytes == before[]);
        }).code == Status.ok);
    frame.value.clear();
    assert(frame.value.usedBytes == 32);
    assert(read32(storage, 12) == 0 && read32(storage, 16) == 1 && read32(storage, 20) == 7);
    assert(frame.value.createElement(node, TagName.span).code == Status.ok);
}

@("bounded UTF-8, handle, attribute and exact graphics payload validation")
unittest
{
    auto storage = new ubyte[256 * 1024];
    auto frame = CommandBuffer.fromStorage(storage);
    assert(frame.ok);
    immutable node = NodeHandle(65_535, 1);
    assert(frame.value.createElement(node, TagName.canvas).code == Status.ok);
    assert(frame.value.createElement(NodeHandle(65_536, 1), TagName.div).code == Status.invalidArgument);
    assert(frame.value.createElement(NodeHandle(1, 0), TagName.div).code == Status.invalidArgument);
    assert(frame.value.remove(NodeHandle(0, 1)).code == Status.invalidArgument);
    assert(frame.value.appendChild(node, node).code == Status.invalidArgument);
    immutable malformed = cast(ubyte[])[0xed, 0xa0, 0x80];
    assert(frame.value.setText(node, malformed).code == Status.invalidArgument);
    auto longText = new ubyte[65_537];
    longText[] = 'a';
    assert(frame.value.setText(node, longText[0 .. $ - 1]).code == Status.ok);
    assert(frame.value.setText(node, longText).code == Status.invalidArgument);
    assert(frame.value.setAttribute(node, cast(const(ubyte)[]) "onclick", null).code == Status.invalidArgument);
    assert(frame.value.setAttribute(node, cast(const(ubyte)[]) "data-label", cast(const(ubyte)[]) "🦊").code
            == Status.ok);

    ubyte[24] drawing;
    write32(drawing, 0, 1);
    write32(drawing, 4, 299);
    write32(drawing, 8, 149);
    write32(drawing, 12, 1);
    write32(drawing, 16, 1);
    assert(frame.value.canvas(node, drawing).code == Status.ok);
    write32(drawing, 12, 2);
    assert(frame.value.canvas(node, drawing).code == Status.invalidArgument);
    write32(drawing, 4, 300);
    write32(drawing, 8, 150);
    write32(drawing, 12, 0);
    write32(drawing, 16, 0);
    assert(frame.value.canvas(node, drawing).code == Status.ok);
    assert(frame.value.webgpu(node, drawing[0 .. 19]).code == Status.invalidArgument);
    drawing[4 .. $] = 0;
    write32(drawing, 4, 0x3f800000);
    write32(drawing, 8, 0x80000000);
    assert(frame.value.webgpu(node, drawing[0 .. 20]).code == Status.ok);
    write32(drawing, 4, 0x7fc00000);
    assert(frame.value.webgpu(node, drawing[0 .. 20]).code == Status.invalidArgument);
}

// Independent oracle: Phobos' decoder, which substitutes U+FFFD for every malformed sequence.
private bool referenceUtf8(scope const(ubyte)[] input) nothrow
{
    import std.typecons : Yes;
    import std.utf : decode, replacementDchar;

    const text = cast(const(char)[]) input;
    size_t index;
    while (index < text.length)
    {
        const start = index;
        if (decode!(Yes.useReplacementDchar)(text, index) == replacementDchar && text[start .. index] != "\uFFFD")
            return false;
    }
    return true;
}

@("BRIDGE-01 one byte beyond an exact frame is rejected without touching the prior batch")
unittest
{
    ubyte[56] storage;
    auto frame = CommandBuffer.fromStorage(storage[0 .. 55], 3);
    assert(frame.ok);
    const empty = storage;
    assert(frame.value.setText(NodeHandle(0, 1), cast(const(ubyte)[]) "hi").code == Status.resourceExhausted);
    assert(storage == empty && frame.value.usedBytes == 32 && read32(storage, 12) == 0);

    auto exactFit = CommandBuffer.fromStorage(storage[0 .. 56], 3);
    assert(exactFit.ok);
    assert(exactFit.value.createElement(NodeHandle(1, 1), TagName.div).code == Status.ok);
    const before = storage;
    assert(exactFit.value.setText(NodeHandle(0, 1), null).code == Status.resourceExhausted);
    assert(storage == before && exactFit.value.usedBytes == 56);
    assert(read32(storage, 12) == 1 && read32(storage, 8) == 56);

    auto largest = new ubyte[16 * 1024 * 1024 + 1];
    assert(CommandBuffer.fromStorage(largest).error.code == Status.invalidArgument);
    const exact = CommandBuffer.fromStorage(largest[0 .. $ - 1]);
    assert(exact.ok && exact.value.capacityBytes == 16 * 1024 * 1024);
}

@("BRIDGE-02 seeded UTF-8 corpus matches an independent validator and every length 0..256 encodes exactly")
unittest
{
    import flint.engine.wasm_bridge : textCommandBytes;
    import flint.engine.wasm_bridge.internal : validUtf8;

    uint state = 0x5eed_0001;
    ubyte[8] sample;
    foreach (_; 0 .. 200_000)
    {
        state = state * 1_664_525 + 1_013_904_223;
        const length = (state >> 28) % 9;
        foreach (ref value; sample[0 .. length])
        {
            state = state * 1_664_525 + 1_013_904_223;
            // Bias toward lead and continuation bytes so multi-byte boundaries are common.
            value = cast(ubyte)((state >> 31) ? 0x80 | ((state >> 16) & 0x7f) : state >> 24);
        }
        assert(validUtf8(sample[0 .. length]) == referenceUtf8(sample[0 .. length]));
    }
    immutable ubyte[][] rejected = [
        [0xc0, 0x80], [0xc1, 0xbf], [0xe0, 0x80, 0x80], [0xed, 0xa0, 0x80], [0xf0, 0x80, 0x80,
            0x80], [0xf4, 0x90, 0x80, 0x80], [0xf5, 0x80, 0x80, 0x80], [0x80], [0xe2, 0x82], [0xff],
        [0xef, 0xbf]
    ];
    foreach (input; rejected)
        assert(!validUtf8(input) && !referenceUtf8(input));
    immutable ubyte[][] accepted = [
        [0x7f], [0xc2, 0x80], [0xef, 0xbf, 0xbd], [0xef, 0xbf, 0xbf], [0xf4, 0x8f, 0xbf, 0xbf]
    ];
    foreach (input; accepted)
        assert(validUtf8(input) && referenceUtf8(input));

    auto storage = new ubyte[2 * 1024 * 1024];
    auto text = new ubyte[1024 * 1024];
    text[] = 'q';
    auto frame = CommandBuffer.fromStorage(storage);
    assert(frame.ok);
    size_t[] lengths;
    foreach (length; 0 .. 257)
        lengths ~= length;
    lengths ~= [1023, 1024, 1025, 65_535, 65_536];
    foreach (length; lengths)
    {
        frame.value.clear();
        assert(frame.value.setText(NodeHandle(0, 1), text[0 .. length]).code == Status.ok);
        assert(frame.value.usedBytes == 32 + textCommandBytes(length));
        assert(read32(storage, 36) == textCommandBytes(length) && read32(storage, 48) == length);
        foreach (pad; storage[52 + length .. frame.value.usedBytes])
            assert(pad == 0);
    }
    foreach (length; [65_537, 1024 * 1024])
    {
        assert(textCommandBytes(length) == 0);
        assert(frame.value.setText(NodeHandle(0, 1), text[0 .. length]).code == Status.invalidArgument);
    }
}

@("BRIDGE-03 mount and handle misuse is rejected by the encoder")
unittest
{
    ubyte[256] storage;
    auto frame = CommandBuffer.fromStorage(storage[]);
    assert(frame.ok);
    immutable mount = NodeHandle(0, 1);
    assert(frame.value.createElement(mount, TagName.div).code == Status.invalidArgument);
    assert(frame.value.createElement(NodeHandle(3, 1), cast(TagName) 0).code == Status.invalidArgument);
    assert(frame.value.createElement(NodeHandle(3, 1), cast(TagName) 7).code == Status.invalidArgument);
    assert(frame.value.appendChild(NodeHandle(3, 1), mount).code == Status.invalidArgument);
    assert(frame.value.appendChild(NodeHandle(0, 2), NodeHandle(3, 1)).code == Status.invalidArgument);
    assert(frame.value.appendChild(mount, NodeHandle(3, 0)).code == Status.invalidArgument);
    assert(frame.value.appendChild(mount, NodeHandle(65_536, 1)).code == Status.invalidArgument);
    assert(frame.value.setText(NodeHandle(0, 2), null).code == Status.invalidArgument);
    assert(frame.value.usedBytes == 32 && read32(storage, 12) == 0);
    assert(frame.value.appendChild(mount, NodeHandle(65_535, 9)).code == Status.ok);
}

@("BRIDGE-04 and attribute policy: only allowlisted names, any valid UTF-8 text is carried verbatim")
unittest
{
    ubyte[512] storage;
    auto frame = CommandBuffer.fromStorage(storage[]);
    assert(frame.ok);
    immutable node = NodeHandle(1, 1);
    foreach (name; [
        "onclick", "ONCLICK", "onload", "src", "href", "style", "srcdoc", "id", "data-", "data-X",
        "data-a b", "data-a=", "Title", "titles", "aria-labex", "aria-label "
    ])
        assert(frame.value.setAttribute(node, cast(const(ubyte)[]) name, null).code == Status.invalidArgument);
    foreach (name; ["title", "aria-label", "class", "value", "data-a", "data-0-z", "data-abcde"])
        assert(frame.value.setAttribute(node, cast(const(ubyte)[]) name, null).code == Status.ok);
    immutable ubyte[] broken = [0xc3];
    assert(frame.value.setAttribute(node, cast(const(ubyte)[]) "title", broken).code == Status.invalidArgument);
    frame.value.clear();
    enum hostile = `<script>alert(1)</script>" onclick="x()" 🦊`;
    assert(frame.value.setText(node, cast(const(ubyte)[]) hostile).code == Status.ok);
    assert(storage[52 .. 52 + hostile.length] == cast(const(ubyte)[]) hostile);
}

@("BRIDGE-09 clear advances the sequence exactly once per frame and never during a borrow")
unittest
{
    ubyte[128] storage;
    auto frame = CommandBuffer.fromStorage(storage[], 0xffff_ffff);
    assert(frame.ok);
    assert(read32(storage, 16) == 0 && read32(storage, 20) == 0xffff_ffff);
    foreach (expected; 1 .. 5)
    {
        assert(frame.value.setText(NodeHandle(0, 1), cast(const(ubyte)[]) "x").code == Status.ok);
        assert(frame.value.visit((scope const(ubyte)[]) @safe nothrow @nogc {}).code == Status.ok);
        assert(read32(storage, 16) == expected - 1);
        frame.value.clear();
        assert(read32(storage, 16) == expected && read32(storage, 20) == 0xffff_ffff);
        assert(read32(storage, 8) == 32 && read32(storage, 12) == 0);
    }
    assert(frame.value.visit((scope const(ubyte)[]) @safe nothrow @nogc {
            frame.value.clear();
            frame.value.clear();
        }).code == Status.ok);
    assert(read32(storage, 16) == 4);
}

@("BRIDGE-11 field and index boundaries: 65536-byte fields and index 65535 accepted, one more rejected")
unittest
{
    auto storage = new ubyte[512 * 1024];
    auto frame = CommandBuffer.fromStorage(storage);
    assert(frame.ok);
    immutable node = NodeHandle(65_535, 1);
    auto value = new ubyte[65_537];
    value[] = 'v';
    auto name = new ubyte[65_537];
    name[] = 'n';
    name[0 .. 5] = cast(const(ubyte)[]) "data-";
    assert(frame.value.setAttribute(node, name[0 .. 65_536], value[0 .. 65_536]).code == Status.ok);
    assert(frame.value.setAttribute(node, name, null).code == Status.invalidArgument);
    assert(frame.value.setAttribute(node, cast(const(ubyte)[]) "title", value).code == Status.invalidArgument);
    assert(frame.value.remove(NodeHandle(65_536, 1)).code == Status.invalidArgument);
    assert(frame.value.remove(node).code == Status.ok);

    ubyte[64] small;
    auto tiny = CommandBuffer.fromStorage(small[]);
    assert(tiny.ok);
    assert(tiny.value.setText(node, value[0 .. 65_536]).code == Status.resourceExhausted);
    assert(tiny.value.setText(node, value).code == Status.invalidArgument);
}

@("BRIDGE-06 and BRIDGE-12 exact canvas surface, wrapped geometry and malformed RGBA")
unittest
{
    ubyte[1024] storage;
    auto frame = CommandBuffer.fromStorage(storage[]);
    assert(frame.ok);
    immutable node = NodeHandle(1, 1);
    ubyte[24] drawing;
    bool rect(uint x, uint y, uint width, uint height)
    {
        write32(drawing, 0, 1);
        write32(drawing, 4, x);
        write32(drawing, 8, y);
        write32(drawing, 12, width);
        write32(drawing, 16, height);
        return frame.value.canvas(node, drawing).code == Status.ok;
    }

    assert(rect(0, 0, 300, 150) && rect(0, 0, 0, 0) && rect(300, 0, 0, 150) && rect(0, 150, 300, 0));
    assert(!rect(0, 0, 301, 150) && !rect(0, 0, 300, 151) && !rect(1, 0, 300, 150) && !rect(0, 1, 300, 150));
    assert(!rect(301, 0, 0, 0) && !rect(0, 151, 0, 0));
    assert(!rect(0xffff_ffff, 0, 1, 0) && !rect(1, 0, 0xffff_ffff, 0) && !rect(0, 1, 0, 0xffff_ffff));
    write32(drawing, 0, 2);
    write32(drawing, 4, 0);
    write32(drawing, 8, 0);
    write32(drawing, 12, 0);
    write32(drawing, 16, 0);
    assert(frame.value.canvas(node, drawing).code == Status.invalidArgument);
    write32(drawing, 0, 1);
    assert(frame.value.canvas(node, drawing[0 .. 23]).code == Status.invalidArgument);

    ubyte[24] color;
    write32(color, 0, 1);
    assert(frame.value.webgpu(node, color[0 .. 20]).code == Status.ok);
    foreach (bits; [0xbf80_0000, 0x7f80_0000, 0xff80_0000, 0x3f80_0001, 0x8000_0001])
    {
        write32(color, 8, bits);
        assert(frame.value.webgpu(node, color[0 .. 20]).code == Status.invalidArgument);
    }
    write32(color, 8, 0);
    write32(color, 0, 0);
    assert(frame.value.webgpu(node, color[0 .. 20]).code == Status.invalidArgument);
    write32(color, 0, 1);
    assert(frame.value.webgpu(node, color[0 .. 21]).code == Status.invalidArgument);
}
