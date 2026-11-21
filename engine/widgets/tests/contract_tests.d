module flint.widgets.contract_tests;

import flint.arena : Status;
import flint.style : foldGraphemes, visitGraphemeRanges, visitGraphemes;
import flint.tui : Effects, Event, EventKind, Frame, KeyCode;
import flint.widgets : List, ListItem, Paginator, Progress, Spinner, Table, TextArea, TextInput, Viewport;

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
