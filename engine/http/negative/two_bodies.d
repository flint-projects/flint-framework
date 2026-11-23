module http_negative.two_bodies;

import flint.arena : RequestArena, Result;
import flint.conc : Context;
import flint.engine.http : HttpClient, HttpExchange, HttpResponse, PostExchange, bindHttpClient;

private struct Payload
{
    /// Body field.
    int quantity;
}

@HttpExchange("https://example.com")
private interface Malformed
{
@safe nothrow @nogc:

    /// Invalid declaration used to check the generator diagnostic.
    @PostExchange("/info")
    Result!HttpResponse duplicateBodies(ref scope RequestArena arena, ref Context context, Payload a, Payload b);
}

private Malformed fails(ref HttpClient client) @safe
{
    return bindHttpClient!Malformed(client);
}
