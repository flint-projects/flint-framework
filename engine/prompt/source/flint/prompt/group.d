/// Synchronous grouped input and explicit cleanup.
module flint.prompt.group;

import flint.arena : Error, Result, Status;
import flint.prompt.internal : cancelled, cancelledBy, drive, maximumFields, maximumInput;
import flint.prompt.types : Answer, Field, FormOptions;
import flint.tui : Effects, Event, EventKind, Frame, KeyCode;
import flint.validate : NotBlank, Violation, validate;
import flint.widgets : TextInput;
import flint.widgets.display : decimal;
import flint.widgets.editing : graphemeCount;

@safe:
package(flint.prompt):

Error validateFields(scope const Field[] fields, FormOptions options)
{
    if (options.maxInputBytes > maximumInput || fields.length > maximumFields)
        return Error(Status.invalidArgument, "prompt input or field count exceeds its limit");
    bool[string] keys;
    size_t secretBytes;
    foreach (ref const field; fields)
    {
        if (field.key.length == 0 || field.key in keys)
            return Error(Status.invalidArgument, "form field keys must be nonempty and unique");
        keys[field.key] = true;
        if (field.secret)
            secretBytes += options.maxInputBytes;
        if (secretBytes > 16 * maximumInput)
            return Error(Status.resourceExhausted, "form secret allocations exceed their total limit");
    }
    return Error.init;
}

private struct Required
{
    @NotBlank string value;
}

Error requiredValue(scope const ref Answer answer)
{
    bool present;
    if (answer.isSecret)
    {
        const checked = answer.secret.read((scope const(ubyte)[] bytes) @safe {
            foreach (byte_; bytes)
                present |= byte_ > ' ';
        });
        if (checked.code != Status.ok)
            return checked;
    }
    else
    {
        Violation[1] violations;
        const value = Required(answer.value);
        present = validate(value, violations[]).valid;
    }
    return present ? Error.init : Error(Status.invalidArgument, "required field is empty: " ~ answer.key);
}

Result!(Answer[]) readGroup(scope const Field[] fields, FormOptions options, string initial = "")
{
    const validated = validateFields(fields, options);
    if (validated.code != Status.ok || fields.length == 0)
        return Result!(Answer[])(null, validated);
    auto model = Group(fields.dup, new Answer[fields.length], options.maxInputBytes);
    bool terminal = options.requireTerminal;
    foreach (index, ref const field; fields)
    {
        model.answers[index].key = field.key;
        model.answers[index].isSecret = field.secret;
        terminal |= field.secret;
    }
    model.defaultInput = model.answers[0].isSecret ? null : initial;
    model.load();
    const outcome = model.done ? model.outcome : drive(model, terminal);
    if (outcome.code != Status.ok)
    {
        wipeAnswers(model.answers);
        return Result!(Answer[])(null, outcome);
    }
    return Result!(Answer[])(model.answers);
}

void wipeAnswers(ref Answer[] answers)
{
    foreach (ref answer; answers)
    {
        answer.secret.clear();
        answer.value = null;
    }
    answers = null;
}

struct Group
{
    Field[] fields;
    Answer[] answers;
    size_t capacity;
    size_t index;
    bool done;
    Error outcome;
    string feedback;
    string defaultInput;
    TextInput text;

    void load()
    {
        text = TextInput.init;
        text.maxBytes = cast(uint) capacity;
        feedback = null;
        ref answer = answers[index];
        if (answer.isSecret)
        {
            if (!answer.secret.open(capacity))
                finish(Error(Status.outOfMemory, "could not allocate native prompt storage"));
        }
        else
        {
            text.value = answer.value;
            if (index == 0)
                text.placeholder = defaultInput;
        }
    }

    void update(Event event, ref Effects effects)
    {
        if (cancelledBy(event))
            finish(cancelled);
        else if (event.kind == EventKind.key && event.key.code == KeyCode.tab && event.key.shift)
            previous();
        else if (event.kind == EventKind.key && (event.key.code == KeyCode.enter || event.key.code == KeyCode.tab))
            submit();
        else
            edit(event, effects);
        if (done)
            effects.quit();
    }

    private void finish(Error result)
    {
        outcome = result;
        done = true;
    }

    private void edit(Event event, ref Effects effects)
    {
        ref answer = answers[index];
        if (answer.isSecret)
            answer.secret.edit(event, capacity);
        else
        {
            text.update(event, effects);
            answer.value = text.value;
        }
    }

    private void submit()
    {
        ref answer = answers[index];
        if (!answer.isSecret)
        {
            if (index == 0 && text.value.length == 0 && defaultInput.length != 0)
                text.value = defaultInput;
            Effects inactive;
            text.update(Event.init, inactive);
            answer.value = text.value;
        }
        if (fields[index].required)
        {
            const verified = requiredValue(answer);
            if (verified.code != Status.ok)
            {
                feedback = verified.message;
                return;
            }
        }
        if (index + 1 == fields.length)
            finish(Error.init);
        else
        {
            ++index;
            load();
        }
    }

    private void previous()
    {
        if (index != 0)
        {
            --index;
            load();
        }
    }

    void view(ref Frame frame) const
    {
        frame.put(0, 0, fields[index].title);
        if (frame.rows < 2)
            return;
        const answer = &answers[index];
        if (answer.isSecret)
        {
            size_t visible;
            const width = frame.columns;
            answer.secret.read((scope const(ubyte)[] bytes) @safe {
                visible = graphemeCount(cast(const(char)[]) bytes, width);
            });
            auto masked = new char[visible];
            masked[] = '*';
            frame.put(0, 1, masked);
        }
        else
            text.view(frame, 0, 1, frame.columns);
        if (frame.rows > 2 && feedback.length != 0)
            frame.put(0, 2, feedback);
        if (frame.rows > 3 && fields.length > 1)
            frame.put(0, 3, decimal(index + 1) ~ "/" ~ decimal(fields.length));
    }
}
