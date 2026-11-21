module widget_edit_fuzz;

import flint.tui : Effects, Event, EventKind, KeyCode;
import flint.widgets : TextArea, TextInput;

@safe:

@("Widget paste handles malformed prefixes and the 1 MiB boundary")
unittest
{
    Effects effects;
    Event pasted;
    pasted.kind = EventKind.paste;
    Event erase;
    erase.kind = EventKind.key;
    erase.key.code = KeyCode.backspace;
    char[256] raw;
    uint random = 7;
    foreach (ref ch; raw)
    {
        random = random * 1_664_525U + 1_013_904_223U;
        ch = cast(char)(random >> 24);
    }
    foreach (length; 0 .. 257)
    {
        TextInput widget;
        widget.maxBytes = 256;
        pasted.paste = raw[0 .. length].idup;
        widget.update(pasted, effects);
        widget.update(erase, effects);
        assert(widget.value.length <= widget.maxBytes);
    }
    auto buffer = new char[1_048_577];
    buffer[] = 'x';
    buffer[$ - 1] = cast(char) 0xc2;
    foreach (length; [1_023, 1_024, 1_025, 1_048_575, 1_048_576, 1_048_577])
    {
        TextArea widget;
        pasted.paste = buffer[0 .. length].idup;
        widget.update(pasted, effects);
        assert(widget.value.length <= widget.maxBytes);
    }
}
