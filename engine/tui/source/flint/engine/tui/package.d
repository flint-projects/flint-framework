/// Serial model updates, owned effects, and differential terminal rendering.
module flint.engine.tui;

public import flint.term : Event, EventKind, KeyCode, Size;
public import flint.engine.tui.effects : Effects;
public import flint.engine.tui.grid : Frame;
public import flint.engine.tui.types : Cell, Command, CommandId, RuntimeOptions, TimerId;
import flint.term : Session;
import flint.engine.tui.internal : Update, View, runTerminal, runSession;

@safe:

/// Run the supplied model over a terminal session on this caller's thread.
int run(M)(ref M model, RuntimeOptions options = RuntimeOptions.init)
{
    return invokeModel(model, (scope Update update, scope View view) @safe {
        return runTerminal(update, view, options);
    });
}

/// Draw through a caller-owned, already opened terminal session.
package(flint) int runOnSession(M)(ref Session session, ref M model, RuntimeOptions options = RuntimeOptions.init)
{
    return invokeModel(model, (scope Update update, scope View view) @safe {
        return runSession(session, update, view, options);
    });
}

private int invokeModel(M)(ref M model, scope int delegate(scope Update, scope View) @safe launch)
{
    static assert(__traits(compiles, (ref M sample, Event event, ref Effects effects) @safe {
            sample.update(event, effects);
        }), "TUI model requires a safe update(Event, ref Effects)");
    static assert(__traits(compiles, (ref const M sample, ref Frame frame) @safe {
            sample.view(frame);
        }), "TUI model requires a safe const view(ref Frame)");
    return launch((Event event, ref Effects effects) @safe { model.update(event, effects); }, (ref Frame frame) @safe {
        ref const M current = model;
        current.view(frame);
    });
}
