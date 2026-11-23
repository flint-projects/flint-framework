/// Minimal typed interactive model.
module model_minimal;

import flint.engine.tui : Effects, Event, EventKind, Frame, run;

@safe:

private struct Counter
{
    void update(Event event, ref Effects effects)
    {
        if (event.kind == EventKind.interrupt)
            effects.quit();
    }

    void view(ref Frame frame) const
    {
        frame.put(0, 0, "Counter");
    }
}

int main()
{
    Counter counter;
    return run(counter);
}
