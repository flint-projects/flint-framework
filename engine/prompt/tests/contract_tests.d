module flint.engine.prompt.contract_tests;

import flint.arena : Status;
import flint.engine.prompt : Answer, Choice, Field, FormOptions, Secret, clear, form, input,
    multiSelect, password, select;
import flint.engine.prompt.group : Group, requiredValue, wipeAnswers;
import flint.engine.tui : Effects, Event, EventKind, Frame, KeyCode, Size;
import flint.engine.tui.prompt_test_display : capture;
import std.string : indexOf;

@safe:

@("Native secrets erase deleted graphemes and retire safely after a reentrant close")
unittest
{
    Secret secret;
    assert(secret.open(32));
    Event event;
    event.kind = EventKind.paste;
    event.paste = "é👩‍🔬";
    secret.edit(event, 32);
    event.kind = EventKind.key;
    event.key.code = KeyCode.backspace;
    secret.edit(event, 32);
    bool visited;
    const read = secret.read((scope const(ubyte)[] raw) @safe {
        assert(raw == cast(const(ubyte)[]) "é");
        secret.clear();
        assert(secret.read((scope const(ubyte)[]) @safe {}).code == Status.invalidArgument);
        assert(raw == cast(const(ubyte)[]) "é");
        visited = true;
    });
    assert(read.code == Status.ok && visited);
    secret.clear();
    assert(secret.read((scope const(ubyte)[]) @safe {}).code == Status.invalidArgument);
}

@("A scoped consumer exception releases native storage before a later clear")
unittest
{
    Secret secret;
    assert(secret.open(4));
    Event event;
    event.kind = EventKind.paste;
    event.paste = "éxx!";
    secret.edit(event, 4);
    try
    {
        secret.read((scope const(ubyte)[] bytes) @safe {
            assert(bytes == cast(const(ubyte)[]) "éxx");
            secret.clear();
            throw new Exception("fixture");
        });
        assert(0);
    }
    catch (Exception error)
    {
        assert(error.msg == "fixture");
    }
    assert(secret.read((scope const(ubyte)[]) @safe {}).code == Status.invalidArgument);
}

@("Duplicate or over-limit choices and field keys fail before terminal admission")
unittest
{
    const choices = [Choice("same", "first"), Choice("same", "second")];
    assert(select("title", choices).error.code == Status.invalidArgument);
    assert(multiSelect("title", [Choice("one", "one")], 2).error.code == Status.invalidArgument);
    assert(form([Field("same", "first"), Field("same", "second")]).error.code == Status.invalidArgument);
    assert(form([Field("", "title")]).error.code == Status.invalidArgument);
}

@("Grouped response cleanup clears secret owners and empty required fields are keyed")
unittest
{
    auto answers = new Answer[2];
    auto observer = answers;
    answers[0].key = "plain";
    answers[0].value = "   ";
    assert(requiredValue(answers[0]).message == "required field is empty: plain");
    answers[0].value = "hello";
    assert(requiredValue(answers[0]).code == Status.ok);
    answers[1].key = "secret";
    answers[1].isSecret = true;
    assert(answers[1].secret.open(16));
    assert(requiredValue(answers[1]).message == "required field is empty: secret");
    clear(answers);
    assert(answers is null && observer[0].value.length == 0);
    assert(observer[1].secret.read((scope const(ubyte)[]) @safe {}).code == Status.invalidArgument);
    clear(answers);
}

private Event typed(KeyCode code, dchar character = 0)
{
    Event event;
    event.kind = EventKind.key;
    event.key.code = code;
    event.key.character = character;
    return event;
}

private Event pasted(string text)
{
    Event event;
    event.kind = EventKind.paste;
    event.paste = text;
    return event;
}

private Event signalled(EventKind kind)
{
    Event event;
    event.kind = kind;
    return event;
}

private Group wizard(scope const Field[] fields, size_t capacity = 64)
{
    auto model = Group(fields.dup, new Answer[fields.length], capacity);
    foreach (index, ref const field; fields)
    {
        model.answers[index].key = field.key;
        model.answers[index].isSecret = field.secret;
    }
    model.load();
    return model;
}

private bool secretClosed(scope const ref Answer answer)
{
    return answer.secret.read((scope const(ubyte)[]) @safe {}).code == Status.invalidArgument;
}

private immutable Field[] steps = [
    Field("public", "Public", true), Field("secret", "Secret", true, true),
    Field("final", "Final", true)
];

@("PROMPT-01 interrupt, Escape and EOF cancel every wizard page and the cleanup wipes partial secrets")
unittest
{
    Effects effects;
    foreach (stop; [EventKind.interrupt, EventKind.eof, EventKind.key])
    {
        foreach (page; 0 .. steps.length)
        {
            auto model = wizard(steps);
            auto observer = model.answers;
            if (page > 0)
            {
                model.update(pasted("pub"), effects);
                model.update(typed(KeyCode.enter), effects);
            }
            if (page > 1)
            {
                model.update(pasted("partial-secret"), effects);
                model.update(typed(KeyCode.enter), effects);
            }
            if (page == 2)
                model.update(pasted("fin"), effects);
            if (page == 1)
                model.update(pasted("partial"), effects);
            assert(model.index == page && !model.done);
            model.update(stop == EventKind.key ? typed(KeyCode.escape) : signalled(stop), effects);
            assert(model.done && model.outcome.code == Status.cancelled);
            assert(model.outcome.message.indexOf("partial") < 0);
            wipeAnswers(model.answers);
            assert(model.answers is null && secretClosed(observer[1]));
            foreach (ref answer; observer)
                assert(answer.value.length == 0);
        }
    }
}

@("PROMPT-02 pasted and edited secrets never reach rendered output, feedback or diagnostics")
unittest
{
    Effects effects;
    auto model = wizard([Field("secret", "Secret", true, true)]);
    model.update(typed(KeyCode.enter), effects);
    assert(!model.done && model.feedback == "required field is empty: secret");
    model.update(pasted("hunter2-é👩‍🔬"), effects);
    model.update(typed(KeyCode.backspace), effects);
    model.update(typed(KeyCode.character, '!'), effects);
    const screen = capture(Size(40, 4), (ref Frame frame) @safe { model.view(frame); });
    assert(screen.indexOf("hunter") < 0 && screen.indexOf("\x1b[2;1H**********") >= 0, screen);
    model.update(typed(KeyCode.enter), effects);
    assert(model.done && model.outcome.code == Status.ok && model.outcome.message.length == 0);
    assert(model.answers[0].value.length == 0 && model.answers[0].isSecret);
    bool matches;
    assert(model.answers[0].secret.read((scope const(ubyte)[] bytes) @safe {
            matches = bytes == cast(const(ubyte)[]) "hunter2-é!";
        }).code == Status.ok && matches);
    clear(model.answers);
}

@("PROMPT-04 duplicate values, keys and selection limits fail before any terminal is opened")
unittest
{
    assert(multiSelect("t", [Choice("a", "A"), Choice("a", "B")], 1).error.code == Status.invalidArgument);
    assert(multiSelect("t", [Choice("a", "A"), Choice("b", "B")]).error.code == Status.invalidArgument);
    assert(select("t", []).error.code == Status.invalidArgument);
    assert(form([Field("k", "public"), Field("k", "secret", false, true)]).error.code == Status.invalidArgument);
    FormOptions oversized;
    oversized.maxInputBytes = 1_048_577;
    assert(password("t", oversized).error.code == Status.invalidArgument);
    assert(input("t", "", oversized).error.code == Status.invalidArgument);
}

@("PROMPT-06 a mixed wizard returns public values only and clear wipes the secret answer")
unittest
{
    Effects effects;
    auto model = wizard(steps);
    auto observer = model.answers;
    model.update(pasted("pub"), effects);
    model.update(typed(KeyCode.tab), effects);
    model.update(pasted("s3cret"), effects);
    model.update(typed(KeyCode.enter), effects);
    model.update(pasted("fin"), effects);
    model.update(typed(KeyCode.enter), effects);
    assert(model.done && model.outcome.code == Status.ok);
    auto answers = model.answers;
    assert(answers[0].value == "pub" && !answers[0].isSecret);
    assert(answers[1].value.length == 0 && answers[1].isSecret);
    assert(answers[2].value == "fin" && !answers[2].isSecret);
    bool matches;
    assert(answers[1].secret.read((scope const(ubyte)[] bytes) @safe {
            matches = bytes == cast(const(ubyte)[]) "s3cret";
        }).code == Status.ok && matches);
    clear(answers);
    assert(answers is null && secretClosed(observer[1]));
    assert(observer[0].value.length == 0 && observer[2].value.length == 0);
}
