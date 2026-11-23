module flint.engine.style.internal.text;

import flint.engine.style.ffi.unicode : breakBetween, mark, pictograph, properties, widthMask;

@safe:

package(flint.engine.style) enum size_t maximumBytes = 16 * 1024 * 1024;
package(flint.engine.style) enum uint maximumCells = 16_384;
package(flint.engine.style) enum reset = "\x1b[0m";

package(flint.engine.style) struct Output
{
    private char[] bytes;
    bool ok = true;

    void add(scope const(char)[] part)
    {
        if (!ok)
            return;
        if (part.length > maximumBytes - bytes.length)
        {
            ok = false;
            return;
        }
        bytes ~= part[];
    }

    void repeat(string glyph, uint count)
    {
        foreach (index; 0 .. count)
            add(glyph);
    }

    void spaces(uint count)
    {
        enum blanks = "                                                                ";
        while (count != 0 && ok)
        {
            const chunk = count > blanks.length ? blanks.length : count;
            add(blanks[0 .. chunk]);
            count -= cast(uint) chunk;
        }
    }

    string finish()
    {
        return ok ? bytes.idup : null;
    }
}

private enum Kind : ubyte
{
    grapheme,
    replaced,
    lineEnd,
    markup
}

package(flint.engine.style) struct Token
{
    size_t start;
    size_t end;
    uint width;
    private Kind kind;
    private bool dotted;

    bool newline() const pure nothrow @nogc
    {
        return kind == Kind.lineEnd;
    }

    bool styled() const pure nothrow @nogc
    {
        return kind == Kind.markup;
    }

    void append(scope const(char)[] input, ref Output output) const
    {
        if (kind == Kind.replaced)
            output.add("\uFFFD");
        else
        {
            if (dotted)
                output.add("\u25CC");
            output.add(input[start .. end]);
        }
    }
}

private bool control(dchar scalar) pure nothrow @nogc
{
    return scalar < 32 || (scalar >= 0x7f && scalar <= 0x9f);
}

private dchar readScalar(scope const(char)[] text, ref size_t cursor) pure nothrow @nogc
{
    const first = cast(ubyte) text[cursor++];
    if (first < 0x80)
        return first;
    uint scalar;
    uint extra;
    uint minimum;
    if (first >= 0xc2 && first <= 0xdf)
    {
        scalar = first & 0x1f;
        extra = 1;
        minimum = 0x80;
    }
    else if (first >= 0xe0 && first <= 0xef)
    {
        scalar = first & 0x0f;
        extra = 2;
        minimum = 0x800;
    }
    else if (first >= 0xf0 && first <= 0xf4)
    {
        scalar = first & 7;
        extra = 3;
        minimum = 0x10000;
    }
    else
        return '\uFFFD';
    if (extra > text.length - cursor)
        return '\uFFFD';
    foreach (index; 0 .. extra)
    {
        const next = cast(ubyte) text[cursor + index];
        if ((next & 0xc0) != 0x80)
            return '\uFFFD';
        scalar = (scalar << 6) | (next & 0x3f);
    }
    if (!validScalar(scalar, minimum))
        return '\uFFFD';
    cursor += extra;
    return cast(dchar) scalar;
}

private bool validScalar(uint scalar, uint minimum) pure nothrow @nogc
{
    return scalar >= minimum && scalar <= 0x10ffff && (scalar < 0xd800 || scalar > 0xdfff);
}

private size_t sgrLength(scope const(char)[] text) pure nothrow @nogc
{
    if (text.length < 4 || text[0 .. 2] != "\x1b[")
        return 0;
    if (text[3] == 'm')
    {
        switch (text[2])
        {
        case '0':
        case '1':
        case '3':
        case '4':
            return 4;
        default:
            return 0;
        }
    }
    if (text.length < 12 || (text[2 .. 7] != "38;2;" && text[2 .. 7] != "48;2;"))
        return 0;
    return sgrRgbLength(text);
}

private size_t sgrRgbLength(scope const(char)[] text) pure nothrow @nogc
{
    size_t index = 7;
    foreach (separator; ";;m")
    {
        const start = index;
        uint value;
        while (index < text.length && index < start + 3 && text[index] >= '0' && text[index] <= '9')
            value = value * 10 + (text[index++] - '0');
        if (index == start || value > 255 || index == text.length || text[index] != separator)
            return 0;
        ++index;
    }
    return index;
}

private bool emoji(dchar scalar) pure nothrow @nogc
{
    return (scalar >= 0x1f1e6 && scalar <= 0x1f1ff) || scalar == 0x20e3;
}

package(flint.engine.style) struct Scanner
{
    private const(char)[] text;
    private bool allowMarkup;
    private size_t cursor;

    this(return scope const(char)[] text, bool allowMarkup) nothrow @nogc
    {
        this.text = text;
        this.allowMarkup = allowMarkup;
    }

    bool next(out Token token) scope nothrow @nogc
    {
        if (cursor == text.length)
            return false;
        token.start = cursor;
        if (allowMarkup && text[cursor] == '\x1b')
        {
            const length = sgrLength(text[cursor .. $]);
            if (length != 0)
            {
                token.kind = Kind.markup;
                cursor += length;
                token.end = cursor;
                return true;
            }
        }

        const scalar = readScalar(text, cursor);
        if (scalar == '\n')
            token.kind = Kind.lineEnd;
        else if (control(scalar) || scalar == 0xfffd)
        {
            token.kind = Kind.replaced;
            token.width = 1;
        }
        else
            cluster(scalar, token);
        token.end = cursor;
        return true;
    }

    private void cluster(dchar first, ref Token token) scope nothrow @nogc
    {
        const initial = properties(first);
        token.width = initial & widthMask;
        token.dotted = (initial & mark) != 0;
        bool pictorial = (initial & pictograph) != 0;
        bool wide = emoji(first);
        dchar previous = first;
        int state;
        while (cursor < text.length)
        {
            size_t end = cursor;
            const next = readScalar(text, end);
            if (control(next) || next == 0xfffd || breakBetween(previous, next, state))
                break;
            const flags = properties(next);
            const width = flags & widthMask;
            if (width > token.width)
                token.width = width;
            pictorial = pictorial || (flags & pictograph) != 0;
            wide = wide || emoji(next) || (pictorial && next == 0xfe0f);
            cursor = end;
            previous = next;
        }
        if (wide)
            token.width = 2;
        else if (token.dotted && token.width == 0)
            token.width = 1;
    }
}

package(flint.engine.style) void visitText(scope const(char)[] text,
        scope bool delegate(scope const(char)[], uint, bool) @safe visit)
{
    if (visit is null || text.length > maximumBytes)
        return;
    scope scanner = Scanner(text, false);
    Token token;
    while (scanner.next(token))
    {
        const bytes = text[token.start .. token.end];
        final switch (token.kind)
        {
        case Kind.replaced:
            if (!visit("\uFFFD", 1, false))
                return;
            break;
        case Kind.lineEnd:
            if (!visit(null, 0, true))
                return;
            break;
        case Kind.grapheme:
            if (!visit(token.dotted ? "\u25CC" ~ bytes : bytes, token.width, false))
                return;
            break;
        case Kind.markup:
            assert(0, "display-only grapheme walker cannot consume markup");
        }
    }
}

package(flint.engine.style) void visitRanges(scope const(char)[] text,
        scope bool delegate(scope const(char)[], bool, bool) @safe visit)
{
    if (visit is null || text.length > maximumBytes)
        return;
    scope scanner = Scanner(text, false);
    Token token;
    while (scanner.next(token))
    {
        const raw = text[token.start .. token.end];
        if (raw == "\r")
        {
            if (token.end < text.length && text[token.end] == '\n')
                ++scanner.cursor;
            if (!visit(text[token.start .. scanner.cursor], true, false))
                return;
        }
        else if (!visit(raw, token.newline(), token.kind == Kind.replaced && raw != "\uFFFD"))
            return;
    }
}

package(flint.engine.style) struct Row
{
    string text;
    uint cells;
    bool styled;
}

package(flint.engine.style) Row clip(scope const(char)[] line, uint limit, bool markup)
{
    if (line.length > maximumBytes || limit == 0)
        return Row.init;
    Row row;
    Output output;
    scope scanner = Scanner(line, markup);
    Token token;
    while (scanner.next(token))
    {
        if (token.newline || token.width > limit - row.cells)
            break;
        row.cells += token.width;
        row.styled = row.styled || token.styled;
        token.append(line, output);
    }
    if (row.styled)
        output.add(reset);
    row.text = output.finish();
    return output.ok ? row : Row.init;
}

package(flint.engine.style) Row[] rows(scope const(char)[] input, uint maximum, bool markup)
{
    if (input.length == 0 || input.length > maximumBytes)
        return null;
    Row[] lines;
    size_t start;
    size_t bytes;
    foreach (index, ch; input)
    {
        if (ch != '\n')
            continue;
        if (!pushRow(lines, clip(input[start .. index], maximum, markup), bytes))
            return null;
        start = index + 1;
    }
    if (start < input.length)
    {
        if (!pushRow(lines, clip(input[start .. $], maximum, markup), bytes))
            return null;
    }
    return lines;
}

private bool pushRow(ref Row[] rows, Row row, ref size_t bytes)
{
    if (rows.length == maximumCells || row.text.length > maximumBytes - bytes)
        return false;
    rows ~= row;
    bytes += row.text.length;
    return true;
}
