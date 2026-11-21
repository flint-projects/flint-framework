module reference_prompt_probe;

import core.stdc.stdlib : calloc, free;
import core.stdc.string : memcpy, memcmp;
import flint.arena : Status;
import flint.tui : Effects, Event, EventKind, Frame, KeyCode;
import flint.tui.widget_display_probe : Screen, require;
import flint.validate : NotBlank, Violation, validate;
import flint.widgets : List, ListItem, TextInput;
import prompt_replay : capacity, choices, fields, filter, replay, sample, secrets, title;
import std.conv : to;

@safe:

private struct Required
{
    @NotBlank string value;
}

private ulong form()
{
    bool[string] present;
    size_t verified;
    foreach (index; 0 .. fields)
    {
        const key = "field-" ~ index.to!string;
        require(key !in present);
        present[key] = true;
        Violation[1] errors;
        const answer = Required("supplied");
        require(validate(answer, errors[]).valid);
        ++verified;
    }
    return verified;
}

private ulong pick(Screen terminal)
{
    List list;
    list.items = new ListItem[choices];
    auto values = new string[choices];
    bool[string] known;
    foreach (index, ref item; list.items)
    {
        values[index] = index.to!string;
        require(values[index]!in known);
        known[values[index]] = true;
        item = ListItem(index + 1, index % 10 == 7 ? "Straße" : "Catalog");
    }
    TextInput input;
    input.placeholder = "Type to filter";
    Effects effects;
    list.update(Event.init, effects);
    void draw(ref Frame frame) @safe
    {
        require(frame.put(0, 0, title).code == Status.ok);
        require(input.view(frame, 0, 1, frame.columns).code == Status.ok);
        require(list.view(frame, 0, 2, frame.columns, frame.rows - 2).code == Status.ok);
    }

    terminal.draw(&draw);
    Event event;
    event.kind = EventKind.paste;
    event.paste = filter;
    input.update(event, effects);
    list.filter = input.value;
    list.update(event, effects);
    terminal.draw(&draw);
    event.kind = EventKind.key;
    event.key.code = KeyCode.down;
    list.update(event, effects);
    terminal.draw(&draw);
    return values[list.selected].to!ulong;
}

private extern (C) void explicit_bzero(void*, size_t) @system nothrow @nogc;

private ulong password(Screen terminal) @system
{
    ulong consumed;
    foreach (_; 0 .. secrets)
    {
        auto buffer = calloc(1, capacity);
        require(buffer !is null);
        memcpy(buffer, sample.ptr, sample.length);
        terminal.draw((ref Frame frame) @safe {
            require(frame.put(0, 0, "Password").code == Status.ok);
            enum mask = "*********";
            require(frame.put(0, 1, mask).code == Status.ok);
        });
        require(memcmp(buffer, sample.ptr, sample.length) == 0);
        consumed += sample.length;
        explicit_bzero(buffer, capacity);
        free(buffer);
    }
    return consumed;
}

int main(string[] args) @system
{
    replay(args, &form, &pick, &password);
    return 0;
}
