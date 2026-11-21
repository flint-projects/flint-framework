module app;

import bridge_probe : measure, observe;

@safe:

private void word(scope ubyte[] output, size_t offset, uint value) pure nothrow @nogc
{
    foreach (index; 0 .. 4)
        output[offset + index] = cast(ubyte)(value >> (index * 8));
}

int main()
{
    auto storage = new ubyte[32 + 4096 * 24];
    uint sequence;
    const success = measure((uint count) @safe nothrow @nogc {
        const size = 32 + count * 24;
        storage[0 .. 32] = 0;
        word(storage, 0, 0x544e4c46);
        word(storage, 4, 1);
        word(storage, 8, size);
        word(storage, 12, count);
        word(storage, 16, ++sequence);
        word(storage, 20, 1);
        foreach (index; 0 .. count)
        {
            const start = 32 + index * 24;
            auto record = storage[start .. start + 24];
            record[] = 0;
            word(record, 0, 2);
            word(record, 4, 24);
            word(record, 12, 1);
            word(record, 16, 2);
            record[20] = '4';
            record[21] = '2';
        }
        return observe(storage[0 .. size], count);
    });
    return success ? 0 : 1;
}
