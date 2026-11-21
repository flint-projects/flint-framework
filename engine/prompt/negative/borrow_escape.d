module borrow_escape;

import flint.prompt : Secret;

@safe:

private const(ubyte)[] escape(ref Secret secret)
{
    const(ubyte)[] stored;
    secret.read((scope const(ubyte)[] bytes) @safe { stored = bytes; });
    return stored;
}
