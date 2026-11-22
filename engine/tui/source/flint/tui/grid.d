/// Checked frame writes and differential terminal spans.
module flint.tui.grid;

import core.thread : Thread;
import flint.arena : Error, Status;
import flint.style : Color, Style, visitGraphemes;
import flint.term : ColorProfile, Size;
import flint.tui.types : Cell;

@safe:
package(flint.tui):

private enum maximumCells = 1_048_576;
private enum maximumText = 1_048_576;
private enum maximumGlyphBytes = 65_536;
private enum maximumFrameText = 4_194_304;
private enum expired = Error(Status.invalidArgument, "frame is outside its view callback");

private struct Pixel
{
    Cell cell;
    string glyph;
    ubyte width = 1;
}

private struct Surface
{
    Pixel[] cells;
    bool[] usedRows;
    size_t textBytes;

    void allocate(Size size)
    {
        cells = new Pixel[cast(size_t) size.columns * size.rows];
        usedRows = new bool[size.rows];
        textBytes = 0;
    }

    void reset(uint columns) nothrow @nogc
    {
        foreach (row, ref used; usedRows)
        {
            if (!used)
                continue;
            cells[row * columns .. (row + 1) * columns] = Pixel.init;
            used = false;
        }
        textBytes = 0;
    }
}

alias Sink = Error delegate(scope const(char)[] bytes) @safe;

final class Grid
{
    private Thread owner;
    private Size dimensions;
    private ColorProfile profile;
    private Surface[2] surfaces;
    private bool exchanged;
    private uint generation;
    private uint active;
    private bool full;
    private Output output;

    this(ColorProfile profile)
    {
        owner = Thread.getThis();
        this.profile = profile;
    }

    private ref Surface front() return nothrow @nogc
    {
        return surfaces[exchanged ? 1 : 0];
    }

    private ref Surface back() return nothrow @nogc
    {
        return surfaces[exchanged ? 0 : 1];
    }

    Size size() const pure nothrow @nogc
    {
        return dimensions;
    }

    Error resize(Size next)
    {
        if (next.columns == 0 || next.rows == 0 || next.columns > maximumCells / next.rows)
            return Error(Status.invalidArgument, "terminal dimensions exceed the frame limit");
        if (next == dimensions)
            return Error.init;
        Surface first;
        Surface second;
        first.allocate(next);
        second.allocate(next);
        front = first;
        back = second;
        dimensions = next;
        full = true;
        return Error.init;
    }

    /// Repaint every cell on the next diff, for example after the terminal reflowed its contents.
    void invalidate() nothrow @nogc
    {
        full = true;
    }

    uint begin()
    {
        if (generation == uint.max)
            return 0;
        back.reset(dimensions.columns);
        active = ++generation;
        return active;
    }

    void end() nothrow @nogc
    {
        active = 0;
    }

    void close() nothrow @nogc
    {
        end();
        front = Surface.init;
        back = Surface.init;
        output = Output.init;
    }

    Error put(uint epoch, uint column, uint row, scope const(char)[] text, Style style)
    {
        if (Thread.getThis() !is owner || epoch == 0 || epoch != active)
            return expired;
        if (column >= dimensions.columns || row >= dimensions.rows)
            return Error(Status.invalidArgument, "frame coordinate is outside the terminal");
        if (text.length > maximumText)
            return Error(Status.resourceExhausted, "frame text exceeds its byte limit");
        Cell paint = styleCell(style, profile);
        if (printableAscii(text))
        {
            // Each printable ASCII byte is its own one-cell grapheme, so no segmentation is needed.
            const end = text.length < dimensions.columns - column ? column + text.length : dimensions.columns;
            foreach (index; column .. end)
                place(cast(uint) index, row, text[index - column .. index - column + 1], 1, paint);
            return Error.init;
        }
        Drawing drawing = Drawing(column, row, column, paint);
        visitGraphemes(text, (scope const(char)[] bytes, uint cells, bool lineEnd) @safe {
            return drawGlyph(drawing, bytes, cells, lineEnd);
        });
        return drawing.error;
    }

    private bool drawGlyph(ref Drawing cursor, scope const(char)[] text, uint cells, bool lineEnd)
    {
        if (lineEnd)
        {
            cursor.column = cursor.left;
            ++cursor.row;
            return cursor.row < dimensions.rows;
        }
        if (cells == 0)
            return true;
        if (cells > dimensions.columns - cursor.column)
        {
            cursor.column = dimensions.columns;
            return true;
        }
        cursor.error = place(cursor.column, cursor.row, text, cells, cursor.paint);
        cursor.column += cells;
        return cursor.error.code == Status.ok;
    }

    private Error place(uint column, uint row, scope const(char)[] text, uint width, Cell paint)
    {
        if (text.length != 1 && (text.length > maximumGlyphBytes || text.length > maximumFrameText - back.textBytes))
            return Error(Status.resourceExhausted, "frame grapheme storage is full");
        const index = cast(size_t) row * dimensions.columns + column;
        const single = text.length == 1;
        paint.rune = single ? text[0] : firstScalar(text);
        erase(index, column);
        if (width == 2)
            erase(index + 1, column + 1);
        const previous = front.cells[index].glyph;
        const glyph = single ? null : previous == text ? previous : text.idup;
        back.cells[index] = Pixel(paint, glyph, cast(ubyte) width);
        if (width == 2)
            back.cells[index + 1] = Pixel(paint, null, 0);
        back.textBytes += glyph.length;
        back.usedRows[row] = true;
        return Error.init;
    }

    private void erase(size_t index, uint column) nothrow @nogc
    {
        const width = back.cells[index].width;
        const start = width == 0 && column != 0 ? index - 1 : index;
        const count = back.cells[start].width == 2 ? 2 : 1;
        back.textBytes -= back.cells[start].glyph.length;
        back.cells[start .. start + count] = Pixel.init;
    }

    Error clear(uint epoch, Style style)
    {
        if (Thread.getThis() !is owner || epoch == 0 || epoch != active)
            return expired;
        auto cell = styleCell(style, profile);
        if (cell == Cell.init)
            back.reset(dimensions.columns);
        else
        {
            back.cells[] = Pixel(cell);
            back.usedRows[] = true;
            back.textBytes = 0;
        }
        return Error.init;
    }

    Error diff(scope Sink write)
    {
        output.used = 0;
        if (full)
            output.add("\x1b[0m\x1b[2J");
        Cell current;
        foreach (row; 0 .. dimensions.rows)
        {
            if (full || front.usedRows[row] || back.usedRows[row])
                drawRow(row, current);
        }
        if (!sameStyle(current, Cell.init))
            output.add("\x1b[0m");
        if (output.used != 0)
        {
            const saved = write(output.bytes[0 .. output.used]);
            if (saved.code != Status.ok)
                return saved;
        }
        exchanged = !exchanged;
        full = false;
        return Error.init;
    }

    private void drawRow(uint row, ref Cell current)
    {
        const width = dimensions.columns;
        const start = cast(size_t) row * width;
        auto previous = front.cells[start .. start + width];
        auto next = back.cells[start .. start + width];
        uint column;
        while (column < width)
        {
            if (!full && !changed(previous, next, column))
            {
                ++column;
                continue;
            }
            const first = column;
            do
                ++column;
            while (column < width && (full || changed(previous, next, column)));
            output.cursor(row + 1, first + 1);
            foreach (ref const pixel; next[first .. column])
                output.pixel(pixel, current, profile);
        }
    }
}

/// Writable view target, valid only within the callback that receives it.
public struct Frame
{
    /// Current terminal width.
    uint columns;
    /// Current terminal height.
    uint rows;
    private Grid grid;
    private uint epoch;

    package(flint.tui) this(Grid grid, uint epoch)
    {
        const dimensions = grid.size();
        columns = dimensions.columns;
        rows = dimensions.rows;
        this.grid = grid;
        this.epoch = epoch;
    }

    /// Write sanitized graphemes starting at a zero-based cell coordinate.
    Error put(uint column, uint row, scope const(char)[] text, Style style = Style.init)
    {
        return grid is null ? expired : grid.put(epoch, column, row, text, style);
    }

    /// Replace the view with spaces in the supplied style.
    Error clear(Style style = Style.init)
    {
        return grid is null ? expired : grid.clear(epoch, style);
    }
}

private struct Drawing
{
    uint column;
    uint row;
    uint left;
    Cell paint;
    Error error;
}

private bool sameStyle(Cell left, Cell right) pure nothrow @nogc
{
    return left.attributes == right.attributes && left.foreground == right.foreground
        && left.background == right.background;
}

private bool equal(ref scope const Pixel left, ref scope const Pixel right) pure nothrow @nogc
{
    return left.width == right.width && left.cell.rune == right.cell.rune && sameStyle(left.cell,
            right.cell) && left.glyph == right.glyph;
}

private bool changed(scope const(Pixel)[] before, scope const(Pixel)[] after, uint column) pure nothrow @nogc
{
    if (!equal(before[column], after[column]))
        return true;
    if (column > 0 && (before[column].width == 0 || after[column].width == 0))
        return !equal(before[column - 1], after[column - 1]);
    if (column + 1 < before.length && (before[column].width == 2 || after[column].width == 2))
        return !equal(before[column + 1], after[column + 1]);
    return false;
}

private bool printableAscii(scope const(char)[] text) pure nothrow @nogc
{
    foreach (ch; text)
        if (ch < ' ' || ch > '~')
            return false;
    return true;
}

private dchar firstScalar(scope const(char)[] utf8) pure nothrow @nogc
{
    const first = cast(ubyte) utf8[0];
    if (first < 128)
        return first;
    const width = first < 0xe0 ? 2 : first < 0xf0 ? 3 : 4;
    uint value = first & ((1 << (7 - width)) - 1);
    foreach (index; 1 .. width)
        value = (value << 6) | (cast(ubyte) utf8[index] & 0x3f);
    return cast(dchar) value;
}

private uint rgb(Color color) pure nothrow @nogc
{
    return cast(uint) color.red << 16 | cast(uint) color.green << 8 | color.blue;
}

private Cell styleCell(Style style, ColorProfile profile) pure nothrow @nogc
{
    Cell result;
    if (profile != ColorProfile.none)
    {
        result.foreground = rgb(style.foreground);
        result.background = rgb(style.background);
    }
    result.attributes = cast(ushort)(style.bold | (cast(uint) style.italic << 1) | (cast(uint) style.underline << 2));
    return result;
}

private struct Output
{
    char[] bytes;
    size_t used;

    void add(scope const(char)[] text)
    {
        const needed = used + text.length;
        if (needed > bytes.length)
            bytes.length = needed > bytes.length * 2 ? needed : bytes.length * 2;
        bytes[used .. needed] = text;
        used = needed;
    }

    void digit(uint number)
    {
        char[10] digits;
        size_t cursor = digits.length;
        do
        {
            digits[--cursor] = cast(char)('0' + number % 10);
            number /= 10;
        }
        while (number != 0);
        add(digits[cursor .. $]);
    }

    void cursor(uint row, uint column)
    {
        add("\x1b[");
        digit(row);
        add(";");
        digit(column);
        add("H");
    }

    void pixel(ref scope const Pixel next, ref Cell current, ColorProfile profile)
    {
        if (next.width == 0)
            return;
        if (!sameStyle(next.cell, current))
        {
            paint(next.cell, profile);
            current = next.cell;
        }
        if (next.glyph.length != 0)
            add(next.glyph);
        else
        {
            const char[1] ascii = [cast(char) next.cell.rune];
            add(ascii[]);
        }
    }

    private void paint(Cell next, ColorProfile profile)
    {
        add("\x1b[0");
        if (next.attributes & 1)
            add(";1");
        if (next.attributes & 2)
            add(";3");
        if (next.attributes & 4)
            add(";4");
        color(next.foreground, true, profile);
        color(next.background, false, profile);
        add("m");
    }

    private void color(uint rgb, bool foreground, ColorProfile profile)
    {
        if (rgb == 0 || profile == ColorProfile.none)
            return;
        const r = (rgb >> 16) & 0xff;
        const g = (rgb >> 8) & 0xff;
        const b = rgb & 0xff;
        if (profile == ColorProfile.ansi16)
        {
            const index = (r >= 128 ? 1 : 0) | (g >= 128 ? 2 : 0) | (b >= 128 ? 4 : 0);
            add(";");
            digit((foreground ? 30 : 40) + index);
            return;
        }
        add(foreground ? ";38;" : ";48;");
        if (profile == ColorProfile.ansi256)
        {
            add("5;");
            digit(16 + rgbCube(r) * 36 + rgbCube(g) * 6 + rgbCube(b));
        }
        else
        {
            add("2;");
            digit(r);
            add(";");
            digit(g);
            add(";");
            digit(b);
        }
    }
}

private uint rgbCube(uint component) pure nothrow @nogc
{
    return (component * 5 + 127) / 255;
}
