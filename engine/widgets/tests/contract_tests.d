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
