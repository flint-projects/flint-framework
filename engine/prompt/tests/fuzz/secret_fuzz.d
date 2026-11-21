module flint.prompt.secret_fuzz;

import flint.arena : Status;
import flint.prompt : Secret;
import flint.tui : Event, EventKind, KeyCode;

@safe:

@("Native secret editing stays bounded across arbitrary byte prefixes")
unittest
{
    char[256] bytes;
    uint random = 117;
    foreach (ref ch; bytes)
    {
        random = random * 1_664_525U + 1_013_904_223U;
        ch = cast(char)(random >> 24);
    }
    Event paste;
    paste.kind = EventKind.paste;
    Event delete_;
    delete_.kind = EventKind.key;
    delete_.key.code = KeyCode.backspace;
    foreach (size; 0 .. 257)
    {
        Secret secret;
        assert(secret.open(size));
        paste.paste = bytes[0 .. size].idup;
        secret.edit(paste, size);
        secret.edit(delete_, size);
        const checked = secret.read((scope const(ubyte)[] value) @safe {
            assert(value.length <= size);
        });
        assert(checked.code == Status.ok);
        secret.clear();
    }
}
