module style_workload;

import core.memory : GC;
import core.time : MonoTime, msecs;
import std.array : join;
import std.stdio : writeln;

@safe:

/// Measured width and height used by both probe executables.
struct Shape
{
    /// Width of the widest row in cells.
    uint width;
    /// Number of rows.
    uint height;
}

private string copies(string input, uint count, string separator = "")
{
    auto parts = new string[count];
    parts[] = input;
    return join(parts, separator);
}

// SAFETY: The test-side counter reads allocation bytes for this registered druntime thread.
private ulong allocatedBytes() @trusted
{
    return GC.allocatedInCurrentThread();
}

private ulong hash(string input) pure nothrow @nogc
{
    ulong result = 0xcbf29ce484222325;
    foreach (ch; input)
        result = (result ^ cast(ubyte) ch) * 0x100000001b3;
    return result;
}

private ulong sample(alias scan, alias layout)(string name, string input, Shape wanted, bool measure, bool paint)
{
    const allocations = allocatedBytes();
    const start = MonoTime.currTime;
    size_t runs;
    ulong checksum;
    do
    {
        const shape = scan(input);
        if (shape != wanted)
            return 0;
        if (paint)
        {
            const output = layout(input, shape.width);
            if (output != input)
                return 0;
            checksum = hash(output);
        }
        else
            checksum = (cast(ulong) shape.width << 32) | shape.height;
        ++runs;
    }
    while (measure && MonoTime.currTime - start < 150.msecs);
    if (measure)
    {
        const elapsed = MonoTime.currTime - start;
        writeln("input=", name, " layout=", paint, " cells=",
                cast(ulong) wanted.width * wanted.height * runs, " ns=", elapsed.total!"nsecs",
                " allocated_bytes=", allocatedBytes() - allocations);
    }
    return checksum;
}

/// Execute the fixed ASCII, CJK and grapheme workloads and validate their outputs.
int runWorkload(alias scan, alias layout)(bool measure)
{
    const ascii = copies("x", 1024);
    const cjk = copies("界", 341) ~ "x";
    const graphemes = copies("e\u0301 👨‍👩‍👧‍👦 🇺🇸", 1000, "\n");
    ulong checksum;
    foreach (paint; [false, true])
    {
        const first = sample!(scan, layout)("ascii-1kiB", ascii, Shape(1024, 1), measure, paint);
        const second = sample!(scan, layout)("cjk-1kiB", cjk, Shape(683, 1), measure, paint);
        const third = sample!(scan, layout)("grapheme-1000", graphemes, Shape(7, 1000), measure, paint);
        if (first == 0 || second == 0 || third == 0)
            return 1;
        checksum = checksum * 31 + first * 7 + second * 5 + third;
    }
    writeln("checksum=", checksum);
    return 0;
}
