module flint.engine.style.style_behavior_test;

import flint.engine.style : Alignment, Border, Color, Insets, Style, TextMetrics, joinHorizontal,
    joinVertical, measure, render, truncateCells;
import flint.engine.style.ffi.unicode : unicodeVersion;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.utf : validate;

@safe:

@("pinned Unicode width and grapheme snapshots")
unittest
{
    assert(unicodeVersion() == "18.0.0");
    assert(measure("A界") == TextMetrics(3, 1));
    assert(measure("e\u0301") == TextMetrics(1, 1));
    assert(measure("👨‍👩‍👧‍👦") == TextMetrics(2, 1));
    assert(measure("🇺🇸1️⃣") == TextMetrics(4, 1));
    assert(measure("·\n界\n") == TextMetrics(2, 2));
    assert(render("\u0301", Style.init, 1) == "◌\u0301");
    assert(truncateCells("abcdef", 4, "…") == "abc…");
    assert(truncateCells("123界字", 4) == "123…");
    assert(truncateCells("👨‍👩‍👧‍👦x", 2) == "…");
    assert(truncateCells("e\u0301X", 2) == "e\u0301X");
}

@("width, box alignment and dimensions are bounded")
unittest
{
    Style style;
    style.border = Border.rounded;
    assert(render("foo", style, 0) == "");
    assert(render("foo", style, 1) == "╭\n│\n╰");
    style.padding = Insets(0, 20, 0, 20);
    assert(render("foo", style, 4) == "╭──╮\n│  │\n╰──╯");
    assert(render("x", style, 16_385) == "");
    assert(render("x", style, 16_384, 16_384) == "");
    style = Style.init;
    style.vertical = Alignment.center;
    style.horizontal = Alignment.center;
    assert(render("x", style, 3, 3) == "   \n x \n   ");
    style.margin.top = uint.max;
    assert(render("x", style, 3) == "");
}

@("raw controls are neutralized and composed SGR style resets at row boundaries")
unittest
{
    const raw = render("\xFF\x1b[2J\x7f", Style.init, 8);
    assert(raw.canFind("\uFFFD\uFFFD[2J\uFFFD"));
    assert(!raw.canFind('\x1b'));
    validate(raw);

    Style style;
    style.bold = true;
    style.foreground = Color(17, 34, 205);
    const painted = render("A", style, 1);
    assert(painted.canFind("\x1b[38;2;17;34;205m") && painted.endsWith("\x1b[0m"));
    Style edges;
    edges.foreground = Color(0, 10, 255);
    edges.background = Color(9, 99, 100);
    assert(render("A", edges, 1).canFind("\x1b[38;2;0;10;255m\x1b[48;2;9;99;100mA"));
    assert(measure(painted).cells == 1);
    const combined = joinHorizontal([painted, "B\nC"], 1);
    assert(measure(combined) == TextMetrics(3, 2));
    assert(combined.canFind("\x1b[0m B\n  C"));
    assert(!joinHorizontal(["\x1b[2J", "B"], 0).canFind("\x1b[2J"));
}

@("joins handle unequal height, empty blocks and exact gaps")
unittest
{
    assert(joinHorizontal(["a\ngg", "x"], 4) == "a     x\ngg     ");
    assert(joinVertical(["a", "", "b\n"], 0) == "a\nb");
    assert(joinVertical(["a", "b"], 4) == "a\n\n\n\n\nb");
    assert(joinVertical(["a", "\n\n"], 4) == "a");
    assert(joinVertical(null, 0) == "");
    assert(joinHorizontal(["a", "b"], uint.max) == "");
}

@("deterministic malformed UTF-8 corpus stays bounded and emits valid UTF-8")
unittest
{
    uint state = 41;
    char[256] buffer;
    foreach (length; 0 .. 257)
    {
        foreach (ref ch; buffer[0 .. length])
        {
            state = state * 1_664_525 + 1_013_904_223;
            ch = cast(char)(state >> 24);
        }
        const rendered = render(buffer[0 .. length], Style.init, 23);
        validate(rendered);
        assert(measure(rendered).cells <= 23);
        assert(!rendered.canFind('\x1b'));
    }
    foreach (length; [1024, 1024 * 1024])
    {
        auto boundary = new char[length];
        boundary[] = cast(char) 0xff;
        const rendered = render(boundary, Style.init, 17);
        validate(rendered);
        assert(measure(rendered).cells == 17);
    }
    const megabyte = (new char[1024 * 1024]).idup;
    string[17] oversized;
    foreach (ref block; oversized)
        block = megabyte;
    assert(joinVertical(oversized[], 0) == "");
}

@("STYLE-02 plain blocks clip at width 1 and oversized padding leaves only blank cells")
unittest
{
    assert(render("foo", Style.init, 1) == "f");
    assert(render("界", Style.init, 1) == " ");
    Style padded;
    padded.padding = Insets(0, 20, 0, 20);
    assert(render("foo", padded, 4) == "    ");
    padded.padding = Insets(uint.max, uint.max, uint.max, uint.max);
    assert(render("foo", padded, 2, 2) == "  \n  ");
}

@("STYLE-03 C1 controls, OSC and non-SGR escapes never reach output")
unittest
{
    const hostile = "\u009b2J\x1b]0;title\x07\x1b[2J\x1b[38;2;1;2m";
    const string[4] outputs = [
        render(hostile, Style.init, 40), truncateCells(hostile, 40), joinHorizontal([hostile], 0),
        joinVertical([hostile, hostile], 1)
    ];
    foreach (output; outputs)
    {
        assert(output.length != 0);
        validate(output);
        assert(!output.canFind('\x1b') && !output.canFind('\x07') && !output.canFind("\u009b"));
        assert(output.canFind("[2J"));
    }
}

@("STYLE-04 nested styled blocks reset SGR state before every row boundary")
unittest
{
    import std.algorithm.iteration : splitter;
    import std.string : lastIndexOf;

    Style inner;
    inner.underline = true;
    inner.border = Border.plain;
    Style outer;
    outer.background = Color(1, 2, 3);
    outer.italic = true;
    const boxed = render("in\nner", inner, 5);
    const filled = render("x", outer, 2, 3);
    const nested = joinVertical([joinHorizontal([boxed, filled], 1), filled], 0);
    assert(measure(nested) == TextMetrics(8, 7));
    size_t styledRows;
    foreach (row; nested.splitter('\n'))
    {
        const last = row.lastIndexOf("\x1b[");
        if (last < 0)
            continue;
        ++styledRows;
        assert(row[last .. $].canFind("\x1b[0m"), row);
    }
    // Frame rows are unpainted; every content row and each filled row carries and resets its style.
    assert(styledRows == 6);
    assert(nested.splitter('\n').front.startsWith("┌───┐ \x1b["));
}

@("STYLE-05 empty joins are empty and gaps never add trailing newlines")
unittest
{
    assert(joinHorizontal(null, 4) == "");
    assert(joinHorizontal(["", ""], 4) == "");
    assert(joinHorizontal(["a", "", "b"], 0) == "ab");
    assert(joinVertical(["", ""], 4) == "");
    assert(!joinVertical(["a\n", "b\n"], 4).endsWith("\n"));
}

@("STYLE-06 oversized counts and widths fail before allocating output")
unittest
{
    assert(truncateCells("abc", 16_385) == "");
    assert(truncateCells("abc", uint.max) == "");
    auto blocks = new string[16_385];
    blocks[] = "a";
    assert(joinHorizontal(blocks, 0) == "");
    assert(joinVertical(blocks, 0) == "");
    assert(joinHorizontal(blocks[0 .. 16_384], 0).length == 16_384);

    auto tall = new char[2 * 16_385];
    foreach (index; 0 .. 16_385)
        tall[2 * index .. 2 * index + 2] = "a\n";
    assert(render(tall, Style.init, 3) == "");
    assert(render(tall, Style.init, 3, 2) == "");
    assert(truncateCells(tall, 3) == "");
    assert(measure(tall) == TextMetrics(1, 16_385));

    auto huge = new char[16 * 1024 * 1024 + 1];
    huge[] = 'a';
    assert(measure(huge) == TextMetrics.init);
    assert(render(huge, Style.init, 4) == "");
    assert(truncateCells(huge, 4) == "");
}
