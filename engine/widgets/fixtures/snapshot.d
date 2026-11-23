module widgets_snapshot;

import flint.arena : Status;
import flint.engine.tui : Effects, Event, EventKind, Frame, KeyCode, run;
import flint.engine.widgets : Column, Paginator, Progress, Spinner, Table, TextInput;

@safe:

private struct Model
{
    Table table;
    TextInput secret;
    Spinner activity;

    void update(Event event, ref Effects effects)
    {
        if (event.kind == EventKind.interrupt || (event.kind == EventKind.key && event.key.code == KeyCode.escape))
            effects.quit();
        else if (event.kind == EventKind.key && event.key.character == 't')
            activity.tick();
        else
            table.update(event, effects);
    }

    void view(ref Frame frame) const
    {
        assert(frame.put(0, 0, "WIDGET GRID").code == Status.ok);
        assert(secret.view(frame, 0, 1, 5).code == Status.ok);
        assert(table.view(frame, 0, 3, 7, 4).code == Status.ok);
        assert(Table.init.view(frame, 0, 7, 7, 1).code == Status.ok);
        assert(Progress(-1).view(frame, 0, 8, 5).code == Status.ok);
        assert(Progress(2).view(frame, 0, 9, 5).code == Status.ok);
        assert(Progress(double.nan).view(frame, 0, 10, 5).code == Status.invalidArgument);
        assert(Paginator(0, 0).view(frame, 0, 11).code == Status.ok);
        assert(Paginator(9, 4).view(frame, 0, 12).code == Status.ok);
        assert(activity.view(frame, 0, 13).code == Status.ok);
        assert(table.view(frame, frame.columns, 0, 3, 3).code == Status.invalidArgument);
    }
}

int main()
{
    Model model;
    model.secret.password = true;
    model.secret.value = "sensitive 👩‍🔬";
    model.table.columns = [Column("First", 3), Column("Last", 4)];
    model.table.rows = [[], ["q"], ["0123456789", "Z"]];
    return run(model);
}
