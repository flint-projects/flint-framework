/// Grapheme-aware single-line and multiline editing.
module flint.widgets.editing;

import flint.arena : Error, Status;
import flint.style : visitGraphemeRanges;
import flint.tui : Effects, Event, EventKind, Frame, KeyCode;
import flint.widgets.internal : fit, nextLine, paintLine, paintLines;

@safe:

/// An editable one-line field with optional display masking.
struct TextInput
{
    /// Current text.
    string value;
    /// Hint shown while the value is empty.
    string placeholder;
    /// Display a mask for each grapheme.
    bool password;
    /// Maximum UTF-8 value bytes.
    uint maxBytes = 4_096;
    private Editor cursor;

    /// Edit the value using key and paste events.
    void update(Event event, ref Effects)
    {
        cursor.update(value, event, maxBytes, false);
    }

    /// Draw either the editable text, password mask, or placeholder.
    Error view(ref Frame frame, uint column, uint row, uint width) const
    {
        const area = fit(frame, column, row, width, 1);
        if (!area.ok())
            return area.error;
        const text = value.length == 0 ? placeholder : password ? mask(value, area.value.columns) : value;
        return paintLine(frame, column, row, area.value.columns, text);
    }
}

/// An editable multiline field with a bounded UTF-8 value.
struct TextArea
{
    /// Current multiline value.
    string value;
    /// Maximum UTF-8 value bytes.
    uint maxBytes = 1_048_576;
    private Editor cursor;

    /// Apply keyboard editing and multiline paste.
    void update(Event event, ref Effects)
    {
        cursor.update(value, event, maxBytes, true);
    }

    /// Draw the visible lines around the current caret.
    Error view(ref Frame frame, uint column, uint row, uint width, uint height) const
    {
        const area = fit(frame, column, row, width, height);
        if (!area.ok() || area.value.rows == 0)
            return area.error;
        const caret = cursor.observed is value ? cursor.offset : value.length;
        size_t line;
        foreach (ch; value[0 .. caret])
            line += ch == '\n';
        const first = line >= area.value.rows ? line - area.value.rows + 1 : 0;
        return paintLines(frame, column, row, area.value, value, first);
    }
}

private struct Editor
{
    string observed;
    size_t offset;
    size_t anchor;

    void update(ref string value, Event event, size_t maxBytes, bool multiline)
    {
        if (observed !is value || value.length > maxBytes)
        {
            value = normalized(value, maxBytes, multiline);
            offset = value.length;
            anchor = offset;
        }
        if (event.error.code == Status.ok)
        {
            if (event.kind == EventKind.paste)
                insert(value, event.paste, maxBytes, multiline);
            else if (event.kind == EventKind.key)
                editKey(value, event, maxBytes, multiline);
        }
        observed = value;
    }

    private void editKey(ref string value, Event event, size_t capacity, bool multiline)
    {
        switch (event.key.code)
        {
        case KeyCode.character:
            if (event.key.control && event.key.character == 'a')
            {
                anchor = 0;
                offset = value.length;
            }
            else if (!event.key.control && !event.key.alt && printable(event.key.character))
            {
                char[4] buffer;
                const length = encodeScalar(buffer, event.key.character);
                insert(value, buffer[0 .. length], capacity, multiline);
            }
            break;
        case KeyCode.enter:
            if (multiline)
                insert(value, "\n", capacity, true);
            break;
        case KeyCode.backspace:
            if (offset == anchor)
                anchor = priorBoundary(value, offset);
            erase(value);
            break;
        case KeyCode.delete_:
            if (offset == anchor)
                anchor = following(value, offset);
            erase(value);
            break;
        default:
            move(value, event, multiline);
            break;
        }
    }

    private void move(scope const(char)[] value, Event event, bool multiline)
    {
        switch (event.key.code)
        {
        case KeyCode.left:
            offset = !event.key.shift && offset != anchor ? lesser(offset,
                    anchor) : priorBoundary(value, offset);
            break;
        case KeyCode.right:
            offset = !event.key.shift && offset != anchor ? greater(offset,
                    anchor) : following(value, offset);
            break;
        case KeyCode.home:
            offset = multiline ? lineStart(value, offset) : 0;
            break;
        case KeyCode.end:
            offset = multiline ? lineEnd(value, offset) : value.length;
            break;
        case KeyCode.up:
            if (multiline)
                offset = vertical(value, offset, false);
            break;
        case KeyCode.down:
            if (multiline)
                offset = vertical(value, offset, true);
            break;
        default:
            return;
        }
        if (!event.key.shift)
            anchor = offset;
    }

    private void erase(ref string value)
    {
        const start = offset < anchor ? offset : anchor;
        const end = offset < anchor ? anchor : offset;
        if (start != end)
            value = value[0 .. start] ~ value[end .. $];
        offset = boundaryAt(value, start);
        anchor = offset;
    }

    private void insert(ref string value, scope const(char)[] raw, size_t maximum, bool multiline)
    {
        const start = offset < anchor ? offset : anchor;
        const end = offset < anchor ? anchor : offset;
        const retained = value.length - (end - start);
        if (retained >= maximum)
            return;
        const added = normalized(raw, maximum - retained, multiline);
        if (added.length == 0)
            return;
        value = value[0 .. start] ~ added ~ value[end .. $];
        offset = boundaryAt(value, start + added.length);
        anchor = offset;
    }
}

private size_t lesser(size_t left, size_t right) pure nothrow @nogc
{
    return left < right ? left : right;
}

private size_t greater(size_t left, size_t right) pure nothrow @nogc
{
    return left > right ? left : right;
}

private string normalized(scope const(char)[] text, size_t limit, bool multiline)
{
    if (text.length == 0 || limit == 0)
        return null;
    string output;
    visitGraphemeRanges(text, (scope const(char)[] raw, bool lineBreak, bool bad) @safe {
        const glyph = lineBreak ? (multiline ? "\n" : " ") : bad ? "\uFFFD" : raw;
        if (glyph.length > limit - output.length)
            return false;
        output ~= glyph;
        return true;
    });
    return output;
}

private size_t boundaryAt(scope const(char)[] text, size_t offset)
{
    if (offset == 0 || offset == text.length)
        return offset;
    return following(text, offset - 1);
}

private size_t following(scope const(char)[] text, size_t offset)
{
    if (offset >= text.length)
        return text.length;
    if ((offset == 0 || text[offset - 1] < 128) && text[offset] < 128 && (offset + 1 == text.length
            || text[offset + 1] < 128))
        return offset + (text[offset] == '\r' && offset + 1 < text.length && text[offset + 1] == '\n' ? 2 : 1);
    size_t end;
    visitGraphemeRanges(text, (scope const(char)[] raw, bool, bool) @safe {
        end += raw.length;
        return end <= offset;
    });
    return end;
}

/// Find the previous original UTF-8 grapheme boundary in a bounded edit buffer.
package(flint) size_t priorBoundary(scope const(char)[] text, size_t offset)
{
    if (offset == 0)
        return 0;
    if (offset <= text.length && text[offset - 1] < 128 && (offset == 1 || text[offset - 2] < 128))
        return offset - (offset >= 2 && text[offset - 2] == '\r' && text[offset - 1] == '\n' ? 2 : 1);
    size_t start;
    visitGraphemeRanges(text, (scope const(char)[] raw, bool, bool) @safe {
        if (raw.length >= offset - start)
            return false;
        start += raw.length;
        return true;
    });
    return start;
}

/// Count the accepted prefix of one-line input without copying its bytes.
package(flint) size_t acceptedInput(scope const(char)[] text, size_t maxBytes)
{
    size_t used;
    visitGraphemeRanges(text, (scope const(char)[] raw, bool breakLine, bool bad) @safe {
        if (breakLine || bad || raw.length > maxBytes - used)
            return false;
        used += raw.length;
        return true;
    });
    return used;
}

/// Check a Unicode scalar for direct insertion into a terminal text field.
// UTF-8 code units of a scalar that `printable` accepted, as std.utf.encode writes them.
private size_t encodeScalar(ref char[4] buffer, dchar scalar) pure nothrow @nogc
{
    if (scalar < 0x80)
    {
        buffer[0] = cast(char) scalar;
        return 1;
    }
    if (scalar < 0x800)
    {
        buffer[0] = cast(char)(0xC0 | (scalar >> 6));
        buffer[1] = cast(char)(0x80 | (scalar & 0x3F));
        return 2;
    }
    if (scalar < 0x10000)
    {
        buffer[0] = cast(char)(0xE0 | (scalar >> 12));
        buffer[1] = cast(char)(0x80 | ((scalar >> 6) & 0x3F));
        buffer[2] = cast(char)(0x80 | (scalar & 0x3F));
        return 3;
    }
    buffer[0] = cast(char)(0xF0 | (scalar >> 18));
    buffer[1] = cast(char)(0x80 | ((scalar >> 12) & 0x3F));
    buffer[2] = cast(char)(0x80 | ((scalar >> 6) & 0x3F));
    buffer[3] = cast(char)(0x80 | (scalar & 0x3F));
    return 4;
}

package(flint) bool printable(dchar scalar) pure nothrow @nogc
{
    return scalar >= ' ' && scalar <= 0x10ffff && !(scalar >= 0x7f && scalar <= 0x9f)
        && !(scalar >= 0xd800 && scalar <= 0xdfff);
}

private size_t lineStart(scope const(char)[] value, size_t offset) pure nothrow @nogc
{
    while (offset > 0 && value[offset - 1] != '\n')
        --offset;
    return offset;
}

private size_t lineEnd(scope const(char)[] value, size_t offset) pure nothrow @nogc
{
    while (offset < value.length && value[offset] != '\n')
        ++offset;
    return offset;
}

private size_t vertical(scope const(char)[] value, size_t offset, bool down)
{
    const first = lineStart(value, offset);
    size_t next;
    if (down)
    {
        next = nextLine(value, offset);
        if (next == value.length && (value.length == 0 || value[$ - 1] != '\n'))
            return offset;
    }
    else
    {
        if (first == 0)
            return offset;
        next = lineStart(value, first - 1);
    }
    size_t count;
    visitGraphemeRanges(value[first .. offset], (scope const(char)[], bool, bool) @safe {
        ++count;
        return true;
    });
    visitGraphemeRanges(value[next .. lineEnd(value, next)], (scope const(char)[] raw, bool, bool) @safe {
        if (count == 0)
            return false;
        --count;
        next += raw.length;
        return true;
    });
    return next;
}

/// Count original graphemes up to a display limit without retaining the input.
package(flint) size_t graphemeCount(scope const(char)[] value, size_t limit)
{
    size_t cells;
    visitGraphemeRanges(value, (scope const(char)[], bool, bool) @safe {
        if (cells == limit)
            return false;
        ++cells;
        return true;
    });
    return cells;
}

private string mask(scope const(char)[] value, uint limit)
{
    auto text = new char[graphemeCount(value, limit)];
    text[] = '*';
    return text.idup;
}
