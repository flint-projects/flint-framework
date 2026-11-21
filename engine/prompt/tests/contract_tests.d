module flint.prompt.contract_tests;

import flint.arena : Status;
import flint.prompt : Answer, Choice, Field, Secret, clear, form, multiSelect, select;
import flint.prompt.group : requiredValue;
import flint.tui : Event, EventKind, KeyCode;

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
