module feature_widget_probe;

import core.time : MonoTime;
import flint.arena : Status;
import flint.engine.tui : Effects, Event, EventKind, Frame, KeyCode;
import flint.engine.tui.widget_display_probe : Screen, require;
import flint.engine.widgets : Column, List, ListItem, Table, TextArea;
import widget_replay : Renderer, matchLabel, maximumText, ordinaryLabel, query, replay, tableOnly;

@safe:

private long prepare(size_t count, out Renderer renderList, out Renderer renderTable)
{
    List list;
    Table table;
    list.items = new ListItem[count];
    table.columns = [Column("Item", 12), Column("Value", 12)];
    table.rows = new string[][](count);
    auto sameRow = new string[2];
    sameRow[] = ["0123456789012345", "bounded"];
    foreach (index; 0 .. count)
    {
        list.items[index] = ListItem(index + 1, index % 10 == 0 ? matchLabel : ordinaryLabel);
        table.rows[index] = sameRow;
    }
    Effects effects;
    list.update(Event.init, effects);
    list.filter = query;
    const start = MonoTime.currTime;
    list.update(Event.init, effects);
    const filtering = (MonoTime.currTime - start).total!"nsecs";
    require(list.selected == 0);
    renderList = (Screen surface) @safe {
        surface.draw((ref Frame frame) @safe {
            require(list.view(frame, 0, 0, frame.columns, frame.rows).code == Status.ok);
        });
    };
    renderTable = (Screen surface) @safe {
        surface.draw((ref Frame frame) @safe {
            require(table.view(frame, 0, 0, frame.columns, frame.rows).code == Status.ok);
        });
    };
    return filtering;
}

private ulong edit()
{
    auto bytes = new char[maximumText];
    bytes[] = 'x';
    TextArea text;
    text.value = bytes.idup;
    Effects effects;
    text.update(Event.init, effects);
    Event event;
    event.kind = EventKind.key;
    foreach (_; 0 .. 32)
    {
        event.key.code = KeyCode.backspace;
        text.update(event, effects);
        event.key.code = KeyCode.character;
        event.key.character = 'x';
        text.update(event, effects);
    }
    require(text.value[$ - 1] == 'x');
    return text.value.length;
}

int main(string[] args)
{
    if (args.length == 3 && args[1] == "--table-only")
        tableOnly(&prepare, args[2]);
    else
        replay(&prepare, &edit, args.length > 1 && args[1] == "--measure");
    return 0;
}
