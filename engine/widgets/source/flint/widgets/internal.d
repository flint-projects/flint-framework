/// Checked widget geometry and visible-line layout.
module flint.widgets.internal;

import flint.arena : Error, Result, Status;
import flint.style : Style, visitGraphemes;
import flint.tui : Event, EventKind, Frame, KeyCode;
import std.array : appender;

@safe:
package(flint.widgets):

struct Region
{
    uint columns;
    uint rows;
}

Result!Region fit(ref const Frame frame, uint column, uint row, uint width, uint height)
{
    if (column >= frame.columns || row >= frame.rows)
        return Result!Region(Region.init, Error(Status.invalidArgument, "widget origin is outside the frame"));
    const columns = frame.columns - column;
    const rows = frame.rows - row;
    return Result!Region(Region(width < columns ? width : columns, height < rows ? height : rows));
}

Error paintLine(ref Frame frame, uint column, uint row, uint width, scope const(char)[] text,
        Style style = Style.init, bool pad = false)
{
    if (width == 0)
        return Error.init;
    const prefix = text.length > maxVisibleText ? text[0 .. maxVisibleText] : text;
    uint cells;
    auto shown = appender!string;
    visitGraphemes(prefix, (scope const(char)[] glyph, uint size, bool lineBreak) @safe {
        if (lineBreak || size > width - cells)
            return false;
        shown.put(glyph);
        cells += size;
        return cells < width;
    });
    const drawn = frame.put(column, row, shown.data, style);
    if (drawn.code != Status.ok || !pad)
        return drawn;
    const remaining = width - cells;
    if (remaining == 0)
        return Error.init;
    auto spaces = new char[remaining];
    spaces[] = ' ';
    return frame.put(column + cells, row, spaces, style);
}

private enum maxVisibleText = 1_048_576;

size_t nextLine(scope const(char)[] text, size_t offset) pure nothrow @nogc
{
    while (offset < text.length && text[offset++] != '\n')
    {
    }
    return offset;
}

size_t lineCount(scope const(char)[] text) pure nothrow @nogc
{
    size_t lines = 1;
    foreach (ch; text)
    {
        if (ch == '\n')
            ++lines;
    }
    return lines;
}

size_t navigate(Event event, size_t index, size_t count) pure nothrow @nogc
{
    if (count == 0)
        return 0;
    const last = count - 1;
    if (index > last)
        index = last;
    if (event.kind != EventKind.key)
        return index;
    switch (event.key.code)
    {
    case KeyCode.home:
        return 0;
    case KeyCode.end:
        return last;
    case KeyCode.up:
        return backwards(index, 1);
    case KeyCode.down:
        return forwards(index, last, 1);
    case KeyCode.pageUp:
        return backwards(index, 20);
    case KeyCode.pageDown:
        return forwards(index, last, 20);
    default:
        return index;
    }
}

private size_t backwards(size_t index, size_t step) pure nothrow @nogc
{
    return index < step ? 0 : index - step;
}

private size_t forwards(size_t index, size_t last, size_t step) pure nothrow @nogc
{
    return last - index < step ? last : index + step;
}

Error paintLines(ref Frame frame, uint column, uint row, Region area, scope const(char)[] text, size_t first)
{
    size_t cursor;
    foreach (_; 0 .. first)
    {
        if (cursor == text.length)
            return Error.init;
        cursor = nextLine(text, cursor);
    }
    foreach (visible; 0 .. area.rows)
    {
        if (cursor == text.length)
            break;
        const past = nextLine(text, cursor);
        const result = paintLine(frame, column, row + visible, area.columns, text[cursor .. past]);
        if (result.code != Status.ok)
            return result;
        cursor = past;
    }
    return Error.init;
}
