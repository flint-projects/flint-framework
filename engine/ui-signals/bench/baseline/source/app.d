module app;

import flint.arena : Error, Status;
import flint.wasm_bridge : CommandBuffer, NodeHandle;
import signals_probe : measure;

@safe:

private bool run(uint count)
{
    auto values = new int[count];
    auto pending = new uint[count];
    uint used;
    return measure(count, (uint first, uint changes, int value) @safe nothrow @nogc {
        foreach (index; first .. first + changes)
        {
            if (values[index] == value)
                continue;
            values[index] = value;
            pending[used++] = index;
        }
        return Error.init;
    }, (ref scope CommandBuffer output) @safe nothrow @nogc {
        foreach (index; pending[0 .. used])
        {
            const ubyte[1] text = [cast(ubyte)('0' + values[index])];
            auto written = output.setText(NodeHandle(index + 1, 1), text[]);
            if (written.code != Status.ok)
                return written;
        }
        used = 0;
        return Error.init;
    });
}

int main()
{
    foreach (count; [1U, 1000U, 10_000U])
        if (!run(count))
            return 1;
    return 0;
}
