module http_negative.escape_chunk;

import flint.arena : Error, RequestArena;
import flint.conc : Context;
import flint.http : HttpClient, HttpRequest;

private const(ubyte)[] leaked;

private void fails(ref HttpClient client, ref scope RequestArena arena, ref Context context) @safe
{
    HttpRequest request;
    auto escape = delegate Error(scope const(ubyte)[] chunk) @safe nothrow @nogc {
        leaked = chunk;
        return Error.init;
    };
    client.stream(request, arena, context, escape);
}
