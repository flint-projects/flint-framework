module flint.style;

import flint.style.internal.layout : horizontal, metrics, renderBlock, truncate, vertical;
import flint.style.internal.text : maximumBytes, visitText, visitRanges;
import flint.style.ffi.unicode : caseFold;
public import flint.style.types : Alignment, Border, Color, Insets, Style, TextMetrics;

@safe:

/// Measure terminal cells and logical lines in UTF-8 display text.
TextMetrics measure(scope const(char)[] utf8)
{
    return metrics(utf8);
}

/// Render raw UTF-8 at the given total width using the natural height.
string render(scope const(char)[] utf8, Style style, uint width)
{
    return renderBlock(utf8, style, width, 0);
}

/// Render at explicit width and height, with vertical alignment within the content area.
string render(scope const(char)[] utf8, Style style, uint width, uint height)
{
    return height == 0 ? null : renderBlock(utf8, style, width, height);
}

/// Place display blocks side by side, padding shorter rows and filling missing rows.
string joinHorizontal(scope const(char[])[] blocks, uint gap)
{
    return horizontal(blocks, gap);
}

/// Stack display blocks with an optional gap in rows.
string joinVertical(scope const(char[])[] blocks, uint gap)
{
    return vertical(blocks, gap);
}

/// Truncate each row at a grapheme boundary and fit the supplied ellipsis into the same width.
string truncateCells(scope const(char)[] utf8, uint maxCells, scope const(char)[] ellipsis = "…")
{
    return truncate(utf8, maxCells, ellipsis);
}

/// Visit sanitized terminal graphemes. The callback can stop by returning false.
package(flint) void visitGraphemes(scope const(char)[] utf8,
        scope bool delegate(scope const(char)[] text, uint cells, bool lineBreak) @safe visit)
{
    visitText(utf8, visit);
}

/// Visit original grapheme bytes, including one logical break for CRLF and a flag for damaged text.
package(flint) void visitGraphemeRanges(scope const(char)[] utf8,
        scope bool delegate(scope const(char)[] original, bool lineBreak, bool replacement) @safe visit)
{
    visitRanges(utf8, visit);
}

/// Normalize and fold bounded UTF-8 using the pinned Unicode provider.
package(flint) bool foldGraphemes(scope const(char)[] utf8, out string folded)
{
    return utf8.length <= maximumBytes && caseFold(utf8, folded);
}
