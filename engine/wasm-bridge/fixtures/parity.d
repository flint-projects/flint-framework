module flint.wasm_bridge.parity;

import flint.arena : Status;
import flint.wasm_bridge : CommandBuffer, NodeHandle, TagName;

@safe:

private uint encode(scope ubyte[] bytes) nothrow @nogc
{
    auto batch = CommandBuffer.fromStorage(bytes, 19);
    if (!batch.ok)
        return 0;
    immutable mount = NodeHandle(0, 1);
    immutable label = NodeHandle(7, 1);
    immutable canvas = NodeHandle(8, 1);
    enum text = `<script id='fixture'>ignored</script><img src=x onerror="alert(1)"> 🦊`;
    const ubyte[24] rectangle = [
        1, 0, 0, 0, 43, 1, 0, 0, 149, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 255, 0, 0, 255
    ];
    batch.value.clear();
    if (batch.value.createElement(label, TagName.paragraph).code != Status.ok
            || batch.value.setText(label, cast(const(ubyte)[]) text).code != Status.ok
            || batch.value.setAttribute(label, cast(const(ubyte)[]) "data-fixture", [49])
                .code != Status.ok || batch.value.appendChild(mount, label).code != Status.ok
            || batch.value.createElement(canvas, TagName.canvas).code != Status.ok
            || batch.value.canvas(canvas, rectangle[]).code != Status.ok
            || batch.value.appendChild(mount, canvas).code != Status.ok)
        return 0;
    return batch.value.usedBytes;
}

version (WebAssembly)
{
    private __gshared ubyte[32 + 4096 * 24] output;

    // SAFETY: Single-thread fixture with caller-owned static storage and no retained view.
    extern (C) export uint fixture_write() @trusted nothrow @nogc
    {
        return encode(output[]);
    }

    // SAFETY: The fixture builds only for wasm32 and the host checks the offset and byte count.
    extern (C) export uint fixture_ptr() @trusted nothrow @nogc
    {
        static assert(size_t.sizeof == uint.sizeof);
        return cast(uint) output.ptr;
    }

    // SAFETY: The fixed static fixture buffer is owned by the single-threaded guest.
    extern (C) export uint fixture_bench(uint count) @trusted nothrow @nogc
    {
        if (count == 0 || count > 4096)
            return 0;
        auto frame = CommandBuffer.fromStorage(output[]);
        if (!frame.ok)
            return 0;
        frame.value.clear();
        foreach (_; 0 .. count)
            if (frame.value.setText(NodeHandle(0, 1), cast(const(ubyte)[]) "42").code != Status.ok)
                return 0;
        const end = 32 + count * 24;
        if (frame.value.usedBytes != end || output[52] != '4' || output[end - 3] != '2')
            return 0;
        return count + output[52] + output[end - 3];
    }
}
else
{
    import core.stdc.stdio : fwrite, stdout;

    @system extern (C) int main()
    {
        ubyte[4096] bytes;
        const count = encode(bytes[]);
        return count > 0 && fwrite(bytes.ptr, 1, count, stdout) == count ? 0 : 1;
    }
}
