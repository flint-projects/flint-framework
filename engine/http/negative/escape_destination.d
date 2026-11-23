module http_negative.escape_destination;

import flint.engine.http : DestinationPolicy;

private const(char)[] leaked;

private DestinationPolicy fails() @safe
{
    return delegate bool(scope const(char)[] target) @safe nothrow @nogc {
        leaked = target;
        return true;
    };
}
