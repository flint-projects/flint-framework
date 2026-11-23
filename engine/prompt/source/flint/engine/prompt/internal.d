/// Standalone terminal ownership and prompt admission.
module flint.engine.prompt.internal;

import flint.arena : Error, Status;
import flint.term : Options, Session;
import flint.engine.tui : Effects, Event, EventKind, KeyCode, RuntimeOptions, runOnSession;

@safe:
package(flint.engine.prompt):

enum maximumInput = 1_048_576;
enum maximumFields = 4_096;
enum maximumChoices = 1_048_576;
enum cancelled = Error(Status.cancelled, "prompt was cancelled");

bool cancelledBy(Event event) pure nothrow @nogc
{
    return event.kind == EventKind.interrupt || event.kind == EventKind.eof
        || (event.kind == EventKind.key && event.key.code == KeyCode.escape);
}

Error drive(M)(ref M model, bool requireTerminal)
{
    auto session = Session.open();
    if (session.ok())
    {
        scope (exit)
            session.value.close();
        RuntimeOptions settings;
        settings.maxPendingCommands = 0;
        const ran = runOnSession(session.value, model, settings);
        if (model.done)
            return model.outcome;
        return Error(Status.ioError, ran == 0 ? "prompt ended before submission" : "prompt display failed");
    }
    if (requireTerminal || session.error.code != Status.unsupported)
        return session.error;

    Options plain;
    plain.raw = false;
    plain.alternateScreen = false;
    plain.bracketedPaste = false;
    auto fallback = Session.open(plain);
    if (!fallback.ok())
        return fallback.error;
    scope (exit)
        fallback.value.close();
    return fromStream(fallback.value, model);
}

private Error fromStream(M)(ref Session terminal, ref M model)
{
    Effects inactive;
    while (!model.done)
    {
        auto event = terminal.next(-1);
        if (!event.ok())
            return event.error;
        model.update(event.value, inactive);
    }
    return model.outcome;
}
