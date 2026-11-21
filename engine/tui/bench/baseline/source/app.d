module flint.tui.reference_probe;

import flint.arena : Status;
import flint.style : visitGraphemes;
import flint.term : Session, Size;
import std.conv : to;
import tui_probe : Emit, Model, Paint, benchmark, header, headerCells, require;

@safe:

private string cursor(uint row, uint column)
{
    return "\x1b[" ~ row.to!string ~ ";" ~ column.to!string ~ "H";
}

private string initial(Size size)
{
    char[] row = new char[size.columns - headerCells];
    row[] = ' ';
    auto output = "\x1b[0m\x1b[2J" ~ cursor(1, 1) ~ header ~ row;
    char[] blank = new char[size.columns];
    blank[] = ' ';
    foreach (number; 2 .. size.rows + 1)
    {
        output ~= cursor(number, 1);
        if (number == size.rows - 1)
        {
            output ~= blank[0 .. $ - 2];
            output ~= "a ";
        }
        else
            output ~= blank;
    }
    return output.idup;
}

private Paint prepare(Size size)
{
    const setup = initial(size);
    auto delta = (cursor(size.rows - 1, size.columns - 1) ~ "?").dup;
    bool started;
    return (ref const Model model, scope Emit output) @safe {
        uint measured;
        visitGraphemes(header, (scope const(char)[], uint cells, bool lineEnd) @safe {
            require(!lineEnd);
            measured += cells;
            return true;
        });
        require(measured == headerCells);
        if (!started)
        {
            started = true;
            require(output(setup).code == Status.ok);
            return;
        }
        delta[$ - 1] = model.letter()[0];
        require(output(delta).code == Status.ok);
    };
}

private int idle()
{
    auto session = Session.open();
    require(session.ok());
    scope (exit)
        session.value.close();
    require(session.value.size().ok());
    require(session.value.write("IDLE").code == Status.ok);
    return session.value.next(1_000_000_000L).error.code == Status.timedOut ? 0 : 1;
}

int main(string[] args)
{
    if (args.length > 1 && args[1] == "--idle")
        return idle();
    benchmark(args.length > 1 && args[1] == "--measure", &prepare);
    return 0;
}
