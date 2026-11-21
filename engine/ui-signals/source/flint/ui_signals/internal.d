module flint.ui_signals.internal;

@safe:
pure:
nothrow:
@nogc:

package(flint.ui_signals) uint decimal(int value, ref scope ubyte[11] output)
{
    const negative = value < 0;
    uint magnitude = negative ? cast(uint)(-cast(long) value) : cast(uint) value;
    uint cursor = cast(uint) output.length;
    do
    {
        output[--cursor] = cast(ubyte)('0' + magnitude % 10);
        magnitude /= 10;
    }
    while (magnitude != 0);
    if (negative)
        output[--cursor] = '-';
    return cursor;
}
