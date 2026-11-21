module app;

import style_workload : Shape, runWorkload;
import std.array : split;

@safe:

private extern (C) @system nothrow @nogc
{
    int utf8proc_charwidth(int codepoint);
    int utf8proc_category(int codepoint);
    bool utf8proc_grapheme_break_stateful(int previous, int next, int* state);
}

// SAFETY: The provider receives validated scalars and one local state word per row.
private uint directWidth(string row) @trusted
{
    uint width;
    uint cluster;
    int state;
    dchar previous;
    bool first = true;
    foreach (dchar scalar; row)
    {
        if (!first && utf8proc_grapheme_break_stateful(previous, scalar, &state))
        {
            width += cluster;
            cluster = 0;
            first = true;
            state = 0;
        }
        const property = utf8proc_category(scalar);
        auto cells = utf8proc_charwidth(scalar);
        if (first && property >= 6 && property <= 8 && cells == 0)
            cells = 1;
        if (scalar >= 0x1f1e6 && scalar <= 0x1f1ff)
            cells = 2;
        if (cells > cluster)
            cluster = cast(uint) cells;
        previous = scalar;
        first = false;
    }
    return width + cluster;
}

private Shape scan(string input)
{
    Shape result;
    foreach (row; split(input, "\n"))
    {
        const width = directWidth(row);
        if (width > result.width)
            result.width = width;
        ++result.height;
    }
    return result;
}

private string layout(string input, uint width)
{
    char[] output;
    foreach (index, row; split(input, "\n"))
    {
        const used = directWidth(row);
        if (used > width)
            return null;
        if (index != 0)
            output ~= '\n';
        output ~= row;
        foreach (_; used .. width)
            output ~= ' ';
    }
    return output.idup;
}

int main(string[] args)
{
    return runWorkload!(scan, layout)(args.length > 1 && args[1] == "--measure");
}
