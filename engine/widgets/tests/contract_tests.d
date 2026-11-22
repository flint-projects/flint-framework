module flint.widgets.contract_tests;

import flint.arena : Status;
import flint.style : foldGraphemes, visitGraphemeRanges, visitGraphemes;
import flint.tui : Effects, Event, EventKind, Frame, KeyCode;
import flint.widgets : Column, List, ListItem, Paginator, Progress, Spinner, Table, TextArea, TextInput, Viewport;
import flint.tui : Size;
import flint.tui.widget_test_display : capture;
import std.string : indexOf;

@safe:

private Event key(KeyCode code, dchar character = 0, bool shift = false)
{
    Event event;
    event.kind = EventKind.key;
    event.key.code = code;
    event.key.character = character;
    event.key.shift = shift;
    return event;
}

private Event paste(string text)
{
    Event event;
    event.kind = EventKind.paste;
    event.paste = text;
    return event;
}

@("Widget editing removes, navigates, and selects complete graphemes")
unittest
{
    Effects effects;
    TextInput field;
    field.value = "ae\u0301👩‍🔬";
    field.update(key(KeyCode.backspace), effects);
    assert(field.value == "ae\u0301");
    field.update(key(KeyCode.backspace), effects);
    assert(field.value == "a");
    field.update(paste("👩‍🔬🇨🇦"), effects);
    field.update(key(KeyCode.left, 0, true), effects);
    field.update(key(KeyCode.character, 'b'), effects);
    assert(field.value == "a👩‍🔬b");
    field.update(key(KeyCode.home), effects);
    field.update(key(KeyCode.right), effects);
    field.update(key(KeyCode.delete_), effects);
    assert(field.value == "ab");
}

@("The byte cap rejects incomplete paste clusters and normalizes CRLF")
unittest
{
    Effects effects;
    TextInput input;
    auto prefix = new char[4_094];
    prefix[] = 'a';
    input.value = prefix.idup;
    input.update(paste("界x"), effects);
    assert(input.value == prefix);
    input.update(paste("éx"), effects);
    assert(input.value.length == 4_096 && input.value[$ - 2 .. $] == "é");
    input.update(key(KeyCode.backspace), effects);
    assert(input.value == prefix);

    TextArea multiline;
    multiline.update(paste("\u0301\r\n👩‍🔬\rX\xc2"), effects);
    assert(multiline.value == "\u0301\n👩‍🔬\nX\uFFFD");
    multiline.update(key(KeyCode.up), effects);
    multiline.update(key(KeyCode.backspace), effects);
    assert(multiline.value == "\u0301\n\nX\uFFFD");
}

@("Raw Style visitor preserves leading marks, CRLF and malformed spans")
unittest
{
    string[] original;
    bool[] breaks;
    bool[] replacements;
    visitGraphemeRanges("\u0301\r\n\xe2\x82X", (scope const(char)[] bytes, bool lineBreak, bool bad) @safe {
        original ~= bytes.idup;
        breaks ~= lineBreak;
        replacements ~= bad;
        return true;
    });
    assert(original[0] == "\u0301" && original[1] == "\r\n");
    assert(breaks[1] && replacements[2]);
    assert(original[$ - 1] == "X");
    string first;
    visitGraphemes("\u0301", (scope const(char)[] glyph, uint cells, bool) @safe {
        assert(cells == 1);
        first = glyph.idup;
        return false;
    });
    assert(first == "\u25CC\u0301");
    string normalized;
    assert(foldGraphemes("École Straße", normalized) && normalized == "école strasse");
    assert(!foldGraphemes("\xf0\x80", normalized));
}

@("List filtering preserves stable identity and guards disabled submissions")
unittest
{
    Effects effects;
    List list;
    list.items = [ListItem(11, "Straße"), ListItem(12, "École"), ListItem(13, "ÉCOLE", true)];
    list.update(key(KeyCode.down), effects);
    assert(list.selected == 1);
    list.items = [list.items[1], list.items[0], list.items[2]];
    list.update(Event.init, effects);
    assert(list.selected == 0 && list.items[list.selected].id == 12);
    list.filter = "STRASSE";
    list.update(Event.init, effects);
    assert(list.selected == 1 && list.items[list.selected].id == 11);

    list.items = [ListItem(20, "E\u0301cole", true)];
    list.filter = "école";
    list.update(key(KeyCode.enter), effects);
    assert(list.selected == size_t.max);
    list.update(key(KeyCode.down), effects);
    assert(list.selected == size_t.max);
}

@("Navigation and indicator edge cases remain bounded")
unittest
{
    Effects effects;
    Viewport viewport;
    viewport.text = "one\ntwo";
    viewport.update(key(KeyCode.end), effects);
    viewport.update(key(KeyCode.pageDown), effects);
    assert(viewport.firstLine == 1);
    Table table;
    table.selected = size_t.max;
    table.update(key(KeyCode.pageDown), effects);
    assert(table.selected == 0);
    Spinner spinner;
    assert(spinner.frame == 0);
    spinner.tick();
    assert(spinner.frame == 1);
    Frame inactive;
    assert(Progress(double.nan).view(inactive, 0, 0, 1).code == Status.invalidArgument);
    assert(Progress(double.infinity).view(inactive, 0, 0, 1).code == Status.invalidArgument);
    assert(Paginator(0, 0).page == 0);
}

@("Table cells clip printable ASCII without splitting a trailing mark and pad every column")
unittest
{
    Table table;
    table.columns = [Column("Name", 4), Column("Value", 6), Column("", 0), Column("Tail", 9)];
    table.rows = [["abcd\u0301", "line\nnext", "hidden", "z"], ["abcdef", "x"], []];
    const output = capture(Size(14, 4), (ref Frame frame) @safe {
        assert(table.view(frame, 0, 0, frame.columns, frame.rows).code == Status.ok);
    });
    assert(output == "\x1b[0m\x1b[2J\x1b[1;1H\x1b[0;1mNameValue Tail\x1b[2;1Habcd\u0301line  z   "
            ~ "\x1b[3;1H\x1b[0mabcdx         \x1b[4;1H              ", output);
}

@("ASCII and Unicode labels filter exactly as their provider case folds")
unittest
{
    Effects effects;
    immutable labels = [
        "Stra\u00DFe", "STRASSE street", "strasse", "XSTRASSEX", "Stras", "", "\u00C9COLE", "ecole",
        "E\u0301COLE", "Kelvin", "\u212Aelvin", "tab\there", "TAB\tHERE", "a\x00b", "A\x00B"
    ];
    immutable queries = [
        "STRASSE", "stra\u00DFe", "\u00E9cole", "ECOLE", "kelvin", "\u212A", "\t", "B\tH", "\x00",
        "a\x00B", "s", "Z"
    ];
    List list;
    foreach (index, label; labels)
        list.items ~= ListItem(index + 1, label);
    foreach (query; queries)
    {
        string keyword;
        assert(foldGraphemes(query, keyword));
        size_t[] expected;
        foreach (index, label; labels)
        {
            string name;
            if (foldGraphemes(label, name) && name.indexOf(keyword) >= 0)
                expected ~= index;
        }
        list.filter = query;
        list.update(Event.init, effects);
        list.update(key(KeyCode.home), effects);
        size_t[] shown;
        while (list.selected != size_t.max && (shown.length == 0 || shown[$ - 1] != list.selected))
        {
            shown ~= list.selected;
            list.update(key(KeyCode.down), effects);
        }
        assert(shown == expected, query);
    }
}

@("WIDGET-02 a grapheme crossing the byte cap is rejected whole, including typed input")
unittest
{
    Effects effects;
    TextInput input;
    auto prefix = new char[4_095];
    prefix[] = 'a';
    input.value = prefix.idup;
    input.update(paste("é"), effects);
    assert(input.value == prefix, "a combining sequence must not be split at the cap");
    input.update(paste("\xe7\x95"), effects);
    assert(input.value.length <= 4_096 && input.value[0 .. 4_095] == prefix);
    input.value = prefix[0 .. 4_093].idup;
    input.update(paste("éz"), effects);
    assert(input.value.length == 4_096 && input.value[$ - 3 .. $] == "é");
    input.update(key(KeyCode.character, 'q'), effects);
    assert(input.value.length == 4_096 && input.value[$ - 3 .. $] == "é");
    input.maxBytes = 3;
    input.value = null;
    input.update(paste("👩‍🔬"), effects);
    assert(input.value.length == 0);
}

@("WIDGET-03 filtering away the selection over disabled survivors leaves no selection")
unittest
{
    Effects effects;
    List list;
    list.items = [ListItem(1, "alpha"), ListItem(2, "beta x", true), ListItem(3, "gamma x", true)];
    list.update(Event.init, effects);
    assert(list.selected == 0);
    list.filter = "x";
    list.update(Event.init, effects);
    assert(list.selected == size_t.max);
    static immutable keys = [
        KeyCode.enter, KeyCode.down, KeyCode.up, KeyCode.home, KeyCode.end, KeyCode.pageDown
    ];
    foreach (code; keys)
    {
        list.update(key(code), effects);
        assert(list.selected == size_t.max);
    }
    const drawn = capture(Size(12, 3), (ref Frame frame) @safe {
        assert(list.view(frame, 0, 0, frame.columns, frame.rows).code == Status.ok);
    });
    assert(drawn.indexOf("- beta x") >= 0 && drawn.indexOf("- gamma x") >= 0 && drawn.indexOf(">") < 0);
    list.filter = "";
    list.update(Event.init, effects);
    assert(list.selected == 0 && list.items[list.selected].id == 1);
}

@("WIDGET-04 tables without columns, narrower areas and stale selections stay in bounds")
unittest
{
    Table empty;
    empty.rows = [["ignored"]];
    assert(capture(Size(6, 2), (ref Frame frame) @safe {
            assert(empty.view(frame, 0, 0, frame.columns, frame.rows).code == Status.ok);
        }) == "\x1b[0m\x1b[2J\x1b[1;1H      \x1b[2;1H      ");

    Table table;
    table.columns = [Column("Wide", 40), Column("Gone", 3)];
    table.rows = [["界界界界", "x"], [], ["0123456789"]];
    table.selected = 99;
    const clipped = capture(Size(5, 3), (ref Frame frame) @safe {
        assert(table.view(frame, 0, 0, 5, 9).code == Status.ok);
        assert(table.view(frame, 5, 0, 1, 1).code == Status.invalidArgument);
        assert(table.view(frame, 0, 3, 1, 1).code == Status.invalidArgument);
    });
    assert(clipped == "\x1b[0m\x1b[2J\x1b[1;1H\x1b[0;1mWide \x1b[2;1H\x1b[0m     \x1b[3;1H\x1b[0;1m01234\x1b[0m",
            clipped);
}

@("WIDGET-05 progress clamps finite values, rejects NaN, and zero pages draw nothing")
unittest
{
    const drawn = capture(Size(5, 6), (ref Frame frame) @safe {
        assert(Progress(-1).view(frame, 0, 0, 5).code == Status.ok);
        assert(Progress(2).view(frame, 0, 1, 5).code == Status.ok);
        assert(Progress(0.5).view(frame, 0, 2, 4).code == Status.ok);
        assert(Progress(double.nan).view(frame, 0, 3, 5).code == Status.invalidArgument);
        assert(Progress(-double.infinity).view(frame, 0, 3, 5).code == Status.invalidArgument);
        assert(Progress(0.5).view(frame, 0, 3, 0).code == Status.ok);
        assert(Paginator(0, 0).view(frame, 0, 4).code == Status.ok);
        assert(Paginator(7, 0).view(frame, 0, 4).code == Status.ok);
        assert(Paginator(9, 4).view(frame, 0, 5).code == Status.ok);
        assert(Paginator(0, 0).view(frame, 5, 0).code == Status.invalidArgument);
    });
    assert(drawn == "\x1b[0m\x1b[2J\x1b[1;1H-----\x1b[2;1H=====\x1b[3;1H==-- \x1b[4;1H     "
            ~ "\x1b[5;1H     \x1b[6;1H4/4  ", drawn);
}

version (linux)
{
    import core.sys.posix.sys.mman : MAP_ANON, MAP_FAILED, MAP_PRIVATE, PROT_NONE, PROT_READ,
        PROT_WRITE, mmap, mprotect, munmap;

    private enum pageBytes = 4_096;

    // SAFETY: The anonymous private mapping is owned by this test, sized for exactly `count` slices and
    // returned as a slice of that length. Every element is initialized before return. The rows reference
    // `cells`, which the caller keeps alive on its stack, so the unscanned mapping never owns GC data.
    private string[][] mapRows(size_t count, string[] cells) @trusted
    {
        auto memory = mmap(null, count * (string[]).sizeof, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        assert(memory != MAP_FAILED);
        auto rows = (cast(string[]*) memory)[0 .. count];
        foreach (ref row; rows)
            row = cells;
        return rows;
    }

    // SAFETY: Only page-aligned subranges of the mapping created by mapRows change protection. Readable
    // pages always cover rows[first .. first + count]; any other access faults and fails the test run.
    private void guard(string[][] rows, size_t first, size_t count) @trusted
    {
        const base = cast(size_t) rows.ptr;
        const end = base + rows.length * (string[]).sizeof;
        const open = (base + first * (string[]).sizeof) / pageBytes * pageBytes;
        const close = (base + (first + count) * (string[]).sizeof + pageBytes - 1) / pageBytes * pageBytes;
        assert(mprotect(rows.ptr, end - base, PROT_READ) == 0);
        if (open > base)
            assert(mprotect(rows.ptr, open - base, PROT_NONE) == 0);
        if (count == 0)
            assert(mprotect(cast(void*) open, close - open, PROT_NONE) == 0);
        if (close < end)
            assert(mprotect(cast(void*) close, end - close, PROT_NONE) == 0);
    }

    // SAFETY: Releases the whole mapping created by mapRows after the final guarded access.
    private void unmapRows(string[][] rows) @trusted
    {
        assert(munmap(rows.ptr, rows.length * (string[]).sizeof) == 0);
    }

    @("WIDGET-06 a million-row table touches only visible row pages per frame")
    unittest
    {
        enum total = 1_000_000;
        enum visible = 20;
        auto cells = ["0123456789012345", "bounded"];
        auto rows = mapRows(total, cells);
        scope (exit)
            unmapRows(rows);
        Table table;
        table.columns = [Column("Item", 12), Column("Value", 12)];
        table.rows = rows;
        foreach (selected; [0, total / 2, total - 1])
        {
            table.selected = selected;
            const first = selected >= visible ? selected - visible + 1 : 0;
            guard(rows, first, visible);
            const drawn = capture(Size(24, visible + 1), (ref Frame frame) @safe {
                assert(table.view(frame, 0, 0, frame.columns, frame.rows).code == Status.ok);
            });
            size_t painted;
            for (ptrdiff_t at = drawn.indexOf("012345678901"); at >= 0; at = drawn.indexOf("012345678901", at + 1))
                ++painted;
            assert(painted == visible);
        }
        guard(rows, 0, 0);
        Effects effects;
        table.selected = total / 2;
        table.update(key(KeyCode.pageDown), effects);
        table.update(key(KeyCode.end), effects);
        assert(table.selected == total - 1);
    }
}
