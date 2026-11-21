module borrowed_command;

import flint.tui : Effects, Event;

@safe:

private void enqueue(ref Effects effects, scope const(ubyte)[] borrowed)
{
    effects.submit(() @safe { Event event; event.payload = borrowed.dup; return event; });
}
