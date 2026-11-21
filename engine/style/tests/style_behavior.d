module flint.style.style_behavior_test;

import flint.style : Alignment, Border, Color, Insets, Style, TextMetrics, joinHorizontal,
    joinVertical, measure, render, truncateCells;
import flint.style.ffi.unicode : unicodeVersion;
import std.algorithm.searching : canFind, endsWith;
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
