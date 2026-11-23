module http_negative.unannotated;

import flint.arena : RequestArena, Result;
import flint.conc : Context;
import flint.engine.http : HttpClient, HttpExchange, HttpResponse, bindHttpClient;

@HttpExchange("https://example.com")
private interface Malformed
{
    /// Missing the required verb annotation.
    Result!HttpResponse missingAnnotation(ref scope RequestArena arena, ref Context context) @safe nothrow @nogc;
}

private Malformed fails(ref HttpClient client) @safe
{
    return bindHttpClient!Malformed(client);
}
