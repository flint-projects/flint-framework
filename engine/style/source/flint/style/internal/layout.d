module flint.style.internal.layout;

import flint.style.internal.text : Output, Row, Scanner, Token, clip, maximumBytes, maximumCells, reset, rows;
import flint.style.types : Alignment, Border, Color, Style, TextMetrics;

@safe:

package(flint.style) TextMetrics metrics(scope const(char)[] input)
{
    TextMetrics result;
    if (input.length == 0 || input.length > maximumBytes)
        return result;
    scope scanner = Scanner(input, true);
    Token token;
    uint cells;
    bool linePresent;
    while (scanner.next(token))
    {
        if (token.newline)
        {
            if (cells > result.cells)
                result.cells = cells;
            ++result.lines;
            cells = 0;
            linePresent = false;
        }
        else
        {
            cells += token.width;
            linePresent = true;
        }
    }
    if (linePresent)
        ++result.lines;
    if (cells > result.cells)
        result.cells = cells;
    return result;
}

private struct Canvas
{
    Output output;
    uint height;

    void beginRow()
    {
        if (height != 0)
            output.add("\n");
        ++height;
    }

    void blank(uint width, uint count)
    {
        foreach (_; 0 .. count)
        {
            beginRow();
            output.spaces(width);
        }
    }
}

private struct Axis
{
    uint outerStart;
    uint outerEnd;
    uint borderStart;
    uint borderEnd;
    uint padStart;
    uint padEnd;
    uint content;
}

private uint take(ref uint remaining, uint requested) pure nothrow @nogc
{
    const reserved = requested <= remaining ? requested : remaining;
    remaining -= reserved;
    return reserved;
}

private Axis divide(uint size, uint left, uint right, uint start, uint end, bool border) pure nothrow @nogc
{
    Axis axis;
    axis.outerStart = take(size, left);
    axis.outerEnd = take(size, right);
    if (border)
    {
        axis.borderStart = take(size, 1);
        axis.borderEnd = take(size, 1);
    }
    axis.padStart = take(size, start);
    axis.padEnd = take(size, end);
    axis.content = size;
    return axis;
}

private uint leading(uint free, Alignment alignment) pure nothrow @nogc
{
    if (alignment == Alignment.end)
        return free;
    return alignment == Alignment.center ? free / 2 : 0;
}

private struct Glyphs
{
    string topLeft;
    string topRight;
    string bottomLeft;
    string bottomRight;
    string horizontal;
    string vertical;
}

private Glyphs glyphs(Border border) pure nothrow @nogc
{
    switch (border)
    {
    case Border.plain:
        return Glyphs("┌", "┐", "└", "┘", "─", "│");
    case Border.rounded:
        return Glyphs("╭", "╮", "╰", "╯", "─", "│");
    case Border.double_:
        return Glyphs("╔", "╗", "╚", "╝", "═", "║");
    default:
        return Glyphs.init;
    }
}

/// Decimal text of one colour channel, as `%s` formats it.
private string decimal(ubyte value) pure nothrow
{
    char[3] digits;
    size_t start = digits.length;
    uint rest = value;
    do
    {
        digits[--start] = cast(char)('0' + rest % 10);
        rest /= 10;
    }
    while (rest != 0);
    return digits[start .. $].idup;
}

private string paint(Style style)
{
    string ansi;
    if (style.foreground != Color.init || style.background != Color.init)
    {
        const fg = style.foreground;
        const bg = style.background;
        ansi = "\x1b[38;2;" ~ decimal(fg.red) ~ ";" ~ decimal(fg.green) ~ ";" ~ decimal(
                fg.blue) ~ "m\x1b[48;2;" ~ decimal(bg.red) ~ ";" ~ decimal(bg.green) ~ ";" ~ decimal(bg.blue) ~ "m";
    }
    if (style.bold)
        ansi ~= "\x1b[1m";
    if (style.italic)
        ansi ~= "\x1b[3m";
    if (style.underline)
        ansi ~= "\x1b[4m";
    return ansi;
}

private void frame(ref Canvas canvas, Axis axis, Glyphs border, bool bottom)
{
    canvas.beginRow();
    auto output = &canvas.output;
    output.spaces(axis.outerStart);
    if (axis.borderStart != 0)
        output.add(bottom ? border.bottomLeft : border.topLeft);
    output.repeat(border.horizontal, axis.padStart + axis.content + axis.padEnd);
    if (axis.borderEnd != 0)
        output.add(bottom ? border.bottomRight : border.topRight);
    output.spaces(axis.outerEnd);
}

private void body(ref Canvas canvas, Axis axis, Glyphs border, string ansi, Row row, Alignment alignment)
{
    canvas.beginRow();
    auto output = &canvas.output;
    const available = axis.content - row.cells;
    const before = leading(available, alignment);
    output.spaces(axis.outerStart);
    output.add(ansi);
    if (axis.borderStart != 0)
        output.add(border.vertical);
    output.spaces(axis.padStart + before);
    output.add(row.text);
    output.spaces(axis.padEnd + available - before);
    if (axis.borderEnd != 0)
        output.add(border.vertical);
    if (ansi.length != 0)
        output.add(reset);
    output.spaces(axis.outerEnd);
}

// Resolve a zero height to the natural block height, rejecting heights above the cell limit.
private bool fitHeight(Style style, size_t lines, bool framed, ref uint height) pure nothrow @nogc
{
    if (height != 0)
        return true;
    const natural = cast(ulong) style.margin.top + style.margin.bottom + style.padding.top
        + style.padding.bottom + lines + (framed ? 2 : 0);
    if (natural > maximumCells)
        return false;
    height = cast(uint) natural;
    return true;
}

package(flint.style) string renderBlock(scope const(char)[] input, Style style, uint width, uint height)
{
    if (width == 0 || width > maximumCells || height > maximumCells || input.length > maximumBytes)
        return null;
    const border = glyphs(style.border);
    const framed = border.vertical.length != 0;
    const x = divide(width, style.margin.left, style.margin.right, style.padding.left, style.padding.right, framed);
    const lines = rows(input, x.content, false);
    // Over-tall or oversized text is rejected rather than drawn as an empty block.
    if (lines is null && input.length != 0)
        return null;
    if (!fitHeight(style, lines.length, framed, height) || cast(ulong) width * height > maximumBytes)
        return null;
    const y = divide(height, style.margin.top, style.margin.bottom, style.padding.top, style.padding.bottom, framed);
    const visible = lines.length < y.content ? cast(uint) lines.length : y.content;
    const spare = y.content - visible;
    const upper = y.padStart + leading(spare, style.vertical);
    const ansi = paint(style);

    Canvas canvas;
    canvas.blank(width, y.outerStart);
    if (y.borderStart != 0)
        frame(canvas, x, border, false);
    foreach (_; 0 .. upper)
        body(canvas, x, border, ansi, Row.init, style.horizontal);
    foreach (line; lines[0 .. visible])
        body(canvas, x, border, ansi, line, style.horizontal);
    foreach (_; upper .. y.padStart + y.padEnd + spare)
        body(canvas, x, border, ansi, Row.init, style.horizontal);
    if (y.borderEnd != 0)
        frame(canvas, x, border, true);
    canvas.blank(width, y.outerEnd);
    return canvas.output.finish();
}

private struct Block
{
    Row[] lines;
    uint width;
}

private bool prepare(scope const(char[])[] input, out Block[] blocks)
{
    if (input.length > maximumCells)
        return false;
    size_t remaining = maximumBytes;
    foreach (text; input)
    {
        if (text.length > remaining)
            return false;
        remaining -= text.length;
    }
    foreach (text; input)
    {
        if (text.length == 0)
            continue;
        const span = metrics(text);
        if (span.lines == 0 || span.lines > maximumCells || span.cells > maximumCells)
            return false;
        auto clean = rows(text, maximumCells, true);
        if (clean.length != span.lines)
            return false;
        blocks ~= Block(clean, span.cells);
    }
    return true;
}

package(flint.style) string horizontal(scope const(char[])[] input, uint gap)
{
    Block[] blocks;
    if (gap > maximumCells || !prepare(input, blocks))
        return null;
    ulong width;
    uint height;
    foreach (ref block; blocks)
    {
        width += block.width;
        if (block.lines.length > height)
            height = cast(uint) block.lines.length;
    }
    if (blocks.length > 1)
    {
        auto gaps = blocks.length;
        width += cast(ulong) gap * --gaps;
    }
    if (width > maximumCells || width * height > maximumBytes)
        return null;

    Canvas canvas;
    foreach (index; 0 .. height)
    {
        canvas.beginRow();
        foreach (column, ref block; blocks)
        {
            if (column != 0)
                canvas.output.spaces(gap);
            const row = index < block.lines.length ? block.lines[index] : Row.init;
            canvas.output.add(row.text);
            canvas.output.spaces(block.width - row.cells);
        }
    }
    return canvas.output.finish();
}

package(flint.style) string vertical(scope const(char[])[] input, uint gap)
{
    Block[] blocks;
    if (gap > maximumCells || !prepare(input, blocks))
        return null;
    Canvas canvas;
    foreach (index, ref block; blocks)
    {
        const before = index == 0 ? 0 : gap;
        if (cast(ulong) canvas.height + before + block.lines.length > maximumCells)
            return null;
        canvas.blank(0, before);
        foreach (line; block.lines)
        {
            canvas.beginRow();
            canvas.output.add(line.text);
        }
    }
    const text = canvas.output.finish();
    size_t end = text.length;
    while (end != 0 && text[end - 1] == '\n')
        --end;
    return text[0 .. end];
}

package(flint.style) string truncate(scope const(char)[] input, uint limit, scope const(char)[] suffix)
{
    if (limit == 0 || limit > maximumCells || input.length > maximumBytes || suffix.length > maximumBytes)
        return null;
    const tail = clip(suffix, limit, false);
    const lines = rows(input, uint.max, true);
    Canvas canvas;
    foreach (line; lines)
    {
        canvas.beginRow();
        if (line.cells <= limit)
            canvas.output.add(line.text);
        else
        {
            canvas.output.add(clip(line.text, limit - tail.cells, true).text);
            canvas.output.add(tail.text);
        }
    }
    return canvas.output.finish();
}
