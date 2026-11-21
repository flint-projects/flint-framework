module app;
import flint.arena : Status;
import flint.tui : Event, EventKind, KeyCode, Effects, Frame, run;
import flint.style : Style, Color;
import flint.widgets : TextInput;

@safe:
/// Application state for a bounded single-field terminal form.
struct Model
{
    /// Editable user name, with storage capped during startup.
    TextInput name;
    /// Apply one event and request side effects from the owning runtime.
    void update(Event event, ref Effects effects)
    {
        if (event.kind == EventKind.interrupt || event.kind == EventKind.eof)
        {
            effects.quit();
            return;
        }
        if (event.kind == EventKind.key && event.key.code == KeyCode.escape)
        {
            effects.quit();
            return;
        }
        name.update(event, effects);
    }

    /// Render the current state without modifying the model.
    void view(ref Frame frame) const
    {
        if (frame.clear().code != Status.ok)
            return;
        Style heading;
        heading.bold = true;
        heading.foreground = Color(104, 210, 190);
        if (frame.put(1, 1, "Flint / type your name", heading).code != Status.ok)
            return;
        if (frame.columns > 4 && name.view(frame, 1, 3, frame.columns - 4).code != Status.ok)
            return;
        if (frame.rows > 2)
        {
            if (frame.put(1, frame.rows - 2, "Esc exits and restores your terminal").code != Status.ok)
                return;
        }
    }
}

int main()
{
    Model model;
    model.name.placeholder = "Your name";
    model.name.maxBytes = 256;
    return run!Model(model);
}
