/// Incremental Unicode scalar validation shared by streaming protocols.
module flint.engine.rpc.utf8;

@safe:
package(flint.engine.rpc):

struct Utf8State
{
    private ubyte left;
    private ubyte low = 0x80;
    private ubyte high = 0xbf;

    bool complete() const scope pure nothrow @nogc
    {
        return left == 0;
    }

    bool accept(ubyte value) scope pure nothrow @nogc
    {
        if (left != 0)
        {
            if (value < low || value > high)
                return false;
            --left;
            low = 0x80;
            high = 0xbf;
            return true;
        }
        if (value < 0x80)
            return true;
        if (value < 0xc2 || value > 0xf4)
            return false;
        if (value < 0xe0)
        {
            left = 1;
        }
        else if (value < 0xf0)
        {
            left = 2;
            if (value == 0xe0)
                low = 0xa0;
            else if (value == 0xed)
                high = 0x9f;
        }
        else
        {
            left = 3;
            if (value == 0xf0)
                low = 0x90;
            else if (value == 0xf4)
                high = 0x8f;
        }
        return true;
    }
}

bool utf8Valid(scope const(ubyte)[] bytes) pure nothrow @nogc
{
    Utf8State scalar;
    foreach (value; bytes)
    {
        if (!scalar.accept(value))
            return false;
    }
    return scalar.complete();
}
