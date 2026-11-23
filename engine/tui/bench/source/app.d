module flint.engine.tui.render_probe;

import flint.arena : Status;
import flint.term : ColorProfile;
import flint.engine.tui : Effects, Event, EventKind, Frame, Size, run;
import flint.engine.tui.grid : Grid;
import tui_probe : Emit, Model, Paint, benchmark, header, require;

@safe:

private Paint prepare(Size size)
{
    auto grid = new Grid(ColorProfile.none);
    require(grid.resize(size).code == Status.ok);
    return (ref const Model model, scope Emit output) @safe {
        auto frame = Frame(grid, grid.begin());
        require(frame.put(0, 0, header).code == Status.ok);
        require(frame.put(size.columns - 2, size.rows - 2, model.letter()).code == Status.ok);
        grid.end();
        require(grid.diff(output).code == Status.ok);
    };
}

private struct Idle
{
    void update(Event event, ref Effects effects)
    {
        if (event.kind == EventKind.resize)
            require(effects.tick(1_000_000_000L).ok());
        else if (event.kind == EventKind.timer)
            effects.quit();
    }

    void view(ref Frame frame) const
    {
        require(frame.put(0, 0, "IDLE").code == Status.ok);
    }
}

int main(string[] args)
{
    if (args.length > 1 && args[1] == "--idle")
    {
        Idle idle;
        return run(idle);
    }
    benchmark(args.length > 1 && args[1] == "--measure", &prepare);
    return 0;
}
