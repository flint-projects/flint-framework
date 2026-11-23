/// Scoped Linux terminal prompts and explicitly wiped form answers.
module flint.engine.prompt;

import core.lifetime : move;
import flint.arena : Result, Status;
import flint.engine.prompt.group : readGroup, wipeAnswers;
import flint.engine.prompt.internal : drive, maximumInput;
import flint.engine.prompt.picker : Confirmation, Picker, validateChoices;
public import flint.engine.prompt.secret : Secret;
public import flint.engine.prompt.types : Answer, Choice, Field, FormOptions;

@safe:

/// Ask for a yes or no response.
Result!bool confirm(scope const(char)[] title, bool defaultValue = false)
{
    Confirmation model;
    model.title = title.idup;
    model.result = defaultValue;
    const outcome = drive(model, true);
    return Result!bool(outcome.code == Status.ok && model.result, outcome);
}

/// Read an editable public value.
Result!string input(scope const(char)[] title, scope const(char)[] defaultValue = "",
        FormOptions options = FormOptions.init)
{
    auto received = readGroup([Field("input", title.idup)], options, defaultValue.idup);
    return Result!string(received.ok() ? received.value[0].value : null, received.error);
}

/// Choose one enabled value.
Result!string select(scope const(char)[] title, scope const Choice[] choices)
{
    auto received = pick(title, choices, false, 0);
    return Result!string(received.ok() ? received.value[0] : null, received.error);
}

/// Choose up to the explicit selection limit, in original choice order.
Result!(string[]) multiSelect(scope const(char)[] title, scope const Choice[] choices, uint maxSelections = 64)
{
    return pick(title, choices, true, maxSelections);
}

private Result!(string[]) pick(scope const(char)[] title, scope const Choice[] choices, bool multiple, uint limit)
{
    const checked = validateChoices(choices, limit, multiple);
    if (checked.code != Status.ok)
        return Result!(string[])(null, checked);
    Picker model;
    model.title = title.idup;
    model.choices = choices.dup;
    model.multiple = multiple;
    model.limit = limit;
    model.initialize();
    const outcome = drive(model, true);
    return Result!(string[])(outcome.code == Status.ok ? model.result : null, outcome);
}

/// Read an owned native secret with terminal echo suppressed.
Result!Secret password(scope const(char)[] title, FormOptions options = FormOptions.init)
{
    auto received = readGroup([Field("password", title.idup, false, true)], options);
    if (!received.ok())
        return Result!Secret(Secret.init, received.error);
    auto value = move(received.value[0].secret);
    return Result!Secret(move(value));
}

/// Gather a sequence of independent public and secret fields.
Result!(Answer[]) form(scope const Field[] fields, FormOptions options = FormOptions.init)
{
    return readGroup(fields, options);
}

/// Wipe every secret and release the answer slice.
void clear(ref Answer[] answers)
{
    wipeAnswers(answers);
}
