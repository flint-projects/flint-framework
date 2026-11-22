module flint.prompt.budget_probe;

import flint.arena : Status;
import flint.prompt : Answer, Choice, Field, FormOptions, clear;
import flint.prompt.group : Group, requiredValue, validateFields;
import flint.prompt.picker : Picker, validateChoices;
import flint.tui : Effects, Event, EventKind, Frame, KeyCode;
import flint.tui.widget_display_probe : Screen, require;
import prompt_replay : capacity, choices, decimal, fields, filter, parseDecimal, replay, sample, secrets, title;

@safe:

private ulong form()
{
    auto inputs = new Field[fields];
    auto answers = new Answer[fields];
    foreach (index; 0 .. fields)
    {
        inputs[index] = Field("field-" ~ decimal(index), "Field", true);
        answers[index].key = inputs[index].key;
        answers[index].value = "supplied";
    }
    require(validateFields(inputs, FormOptions.init).code == Status.ok);
    uint verified;
    foreach (ref answer; answers)
    {
        require(requiredValue(answer).code == Status.ok);
        ++verified;
    }
    return verified;
}

private ulong pick(Screen terminal)
{
    Picker model;
    model.title = title;
    model.choices = new Choice[choices];
    foreach (index, ref item; model.choices)
        item = Choice(decimal(index), index % 10 == 7 ? "Straße" : "Catalog");
    require(validateChoices(model.choices, 0, false).code == Status.ok);
    model.initialize();
    Effects effects;
    model.update(Event.init, effects);
    terminal.draw(&model.view);
    Event event;
    event.kind = EventKind.paste;
    event.paste = filter;
    model.update(event, effects);
    terminal.draw(&model.view);
    event.kind = EventKind.key;
    event.key.code = KeyCode.down;
    model.update(event, effects);
    terminal.draw(&model.view);
    event.key.code = KeyCode.enter;
    model.update(event, effects);
    require(model.done && model.result.length == 1);
    return parseDecimal(model.result[0]);
}

private ulong password(Screen terminal)
{
    auto descriptors = [Field("secret", "Password", true, true)];
    auto answers = new Answer[1];
    Effects effects;
    Event paste;
    paste.kind = EventKind.paste;
    paste.paste = sample;
    ulong consumed;
    foreach (_; 0 .. secrets)
    {
        Group model = Group(descriptors, answers, capacity);
        model.answers[0].key = "secret";
        model.answers[0].isSecret = true;
        model.load();
        require(!model.done);
        model.update(paste, effects);
        terminal.draw(&model.view);
        const read = model.answers[0].secret.read((scope const(ubyte)[] bytes) @safe {
            require(bytes == cast(const(ubyte)[]) sample);
            consumed += bytes.length;
        });
        require(read.code == Status.ok);
        clear(model.answers);
    }
    return consumed;
}

int main(string[] args) @system
{
    replay(args, &form, &pick, &password);
    return 0;
}
