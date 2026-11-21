/// Confirmation and selectable list controllers.
module flint.prompt.picker;

import flint.arena : Error, Status;
import flint.prompt.internal : cancelled, cancelledBy, maximumChoices;
import flint.prompt.types : Choice;
import flint.tui : Effects, Event, EventKind, Frame, KeyCode;
import flint.widgets : List, ListItem, TextInput;

@safe:
package(flint.prompt):

Error validateChoices(scope const Choice[] choices, size_t maximum, bool multiple)
{
    if (choices.length == 0 || choices.length > maximumChoices || (multiple && maximum > choices.length))
        return Error(Status.invalidArgument, "invalid prompt choice or selection count");
    bool[string] seen;
    foreach (ref const item; choices)
    {
        if (item.value in seen)
            return Error(Status.invalidArgument, "duplicate choice value");
        seen[item.value] = true;
    }
    return Error.init;
}

struct Confirmation
{
    string title;
    bool result;
    bool done;
    Error outcome;

    void update(Event event, ref Effects effects)
    {
        if (cancelledBy(event))
        {
            done = true;
            outcome = cancelled;
        }
        else if (event.kind == EventKind.key)
        {
            switch (event.key.code)
            {
            case KeyCode.enter:
                done = true;
                break;
            case KeyCode.left:
            case KeyCode.right:
            case KeyCode.tab:
                result = !result;
                break;
            case KeyCode.character:
                const answer = event.key.character;
                if (answer == 'y' || answer == 'Y' || answer == 'n' || answer == 'N')
                {
                    result = answer == 'y' || answer == 'Y';
                    done = true;
                }
                break;
            default:
                break;
            }
        }
        if (done)
            effects.quit();
    }

    void view(ref Frame frame) const
    {
        frame.put(0, 0, title);
        if (frame.rows > 1)
            frame.put(0, 1, result ? "[Yes]  No " : " Yes  [No]");
    }
}

struct Picker
{
    string title;
    Choice[] choices;
    List list;
    TextInput query;
    bool multiple;
    uint limit;
    bool[] marked;
    uint count;
    bool done;
    Error outcome;
    string[] result;

    void initialize()
    {
        list.items = new ListItem[choices.length];
        if (multiple)
            marked = new bool[choices.length];
        foreach (index, ref const item; choices)
            list.items[index] = ListItem(index + 1, item.label, item.disabled);
        query.placeholder = multiple ? "Type to filter. Tab marks a choice." : "Type to filter";
    }

    void update(Event event, ref Effects effects)
    {
        if (cancelledBy(event))
        {
            outcome = cancelled;
            done = true;
        }
        else if (event.kind == EventKind.key && event.key.code == KeyCode.enter)
            submit();
        else if (multiple && toggled(event))
            toggle();
        else
        {
            query.update(event, effects);
            list.filter = query.value;
            list.update(event, effects);
        }
        if (done)
            effects.quit();
    }

    private bool toggled(Event event) const pure nothrow @nogc
    {
        return event.kind == EventKind.key && (event.key.code == KeyCode.tab || event.key.character == ' ');
    }

    private void toggle()
    {
        const index = list.selected;
        if (index >= choices.length || choices[index].disabled)
            return;
        if (marked[index])
        {
            marked[index] = false;
            --count;
        }
        else if (count < limit)
        {
            marked[index] = true;
            ++count;
        }
    }

    private void submit()
    {
        const index = list.selected;
        if (!multiple)
        {
            if (index >= choices.length || choices[index].disabled)
                return;
            result = [choices[index].value];
        }
        else
        {
            result = new string[count];
            size_t next;
            foreach (position, selected; marked)
            {
                if (selected && !choices[position].disabled)
                    result[next++] = choices[position].value;
            }
            result = result[0 .. next];
        }
        done = true;
    }

    void view(ref Frame frame) const
    {
        frame.put(0, 0, title);
        if (frame.rows > 1)
            query.view(frame, 0, 1, frame.columns);
        if (frame.rows > 2)
            list.viewMarked(frame, 0, 2, frame.columns, frame.rows - 2, marked);
    }
}
