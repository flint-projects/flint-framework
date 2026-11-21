module prompt_interactive;

import flint.arena : Status;
import flint.prompt : Choice, Field, FormOptions, clear, confirm, form, input, multiSelect, password, select;
import flint.term : Session;
import std.stdio : writeln;

@safe:

private enum expected = "starter-é!";
private immutable Field[] fields = [
    Field("public", "PUBLIC ENTRY", true), Field("secret", "PRIVATE PHRASE", true, true),
    Field("final", "LAST DESCRIPTION", true)
];
private immutable Choice[] choices = [
    Choice("disabled", "Unavailable", true), Choice("one", "École"), Choice("two", "Straße")
];

private int secret()
{
    auto result = password("Password");
    scope (exit)
        result.value.clear();
    if (!result.ok())
    {
        writeln("RESULT=", result.error.code);
        return 0;
    }
    bool okay;
    const read = result.value.read((scope const(ubyte)[] bytes) @safe {
        okay = bytes == cast(const(ubyte)[]) expected;
    });
    assert(read.code == Status.ok && okay);
    writeln("RESULT=ok SECRET");
    return 0;
}

private int fieldsTest()
{
    auto result = form(fields);
    scope (exit)
        clear(result.value);
    if (!result.ok())
    {
        assert(result.value is null);
        writeln("RESULT=", result.error.code);
        return 0;
    }
    assert(result.value.length == 3 && !result.value[0].isSecret && result.value[1].isSecret);
    assert(result.value[0].value == "public" && result.value[1].value.length == 0);
    assert(result.value[2].value == "final");
    bool correct;
    const checked = result.value[1].secret.read((scope const(ubyte)[] bytes) @safe {
        correct = bytes == cast(const(ubyte)[]) "qwerty-secret";
    });
    assert(checked.code == Status.ok && correct);
    writeln("RESULT=ok GROUP");
    return 0;
}

private int choiceTest(bool multiple)
{
    if (multiple)
    {
        const selected = multiSelect("Choose several", choices, 2);
        assert(selected.ok() && selected.value == ["one", "two"]);
    }
    else
    {
        const selected = select("Choose an item", choices);
        assert(selected.ok() && selected.value == "two");
    }
    writeln("RESULT=ok PICK");
    return 0;
}

private int confirmation()
{
    const agreed = confirm("Proceed?", true);
    if (agreed.ok())
        assert(agreed.value);
    else
        assert(!agreed.value && agreed.error.code == Status.cancelled);
    writeln("RESULT=", agreed.error.code);
    return 0;
}

private int nested()
{
    auto outer = Session.open();
    assert(outer.ok());
    {
        scope (exit)
            outer.value.close();
        const refused = password("Inner").error.code;
        assert(refused == Status.conflict);
        assert(outer.value.size().ok());
    }
    writeln("RESULT=ok CONFLICT");
    return 0;
}

private int stream()
{
    FormOptions options;
    options.requireTerminal = false;
    const result = input("Input", "fallback", options);
    assert(result.ok() && result.value == "stream");
    writeln("RESULT=ok STREAM");
    return 0;
}

int main(string[] args)
{
    if (args.length != 2)
        return 64;
    switch (args[1])
    {
    case "password":
        return secret();
    case "form":
        return fieldsTest();
    case "select":
        return choiceTest(false);
    case "multi":
        return choiceTest(true);
    case "confirm":
        return confirmation();
    case "nested":
        return nested();
    case "stream":
        return stream();
    default:
        return 64;
    }
}
