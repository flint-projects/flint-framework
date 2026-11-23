module mutable_view;

import flint.engine.tui : Effects, Event, Frame, run;

@safe:

private struct Model
{
    void update(Event, ref Effects)
    {
    }

    void view(ref Frame frame)
    {
    }
}

private int invalid()
{
    Model model;
    return run(model);
}
