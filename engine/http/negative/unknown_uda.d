module http_negative.unknown_uda;

import flint.arena : RequestArena, Result;
import flint.conc : Context;
import flint.http : GetExchange, HttpClient, HttpExchange, HttpResponse, bindHttpClient;

private struct Extra
{
}

@HttpExchange("https://example.com")
private interface Malformed
{
@safe nothrow @nogc:

    /// Invalid declaration used to check the generator diagnostic.
    @GetExchange("/info/{id}")
    Result!HttpResponse unknownParameter(ref scope RequestArena arena, ref Context context, @Extra string id);
}

private Malformed fails(ref HttpClient client) @safe
{
    return bindHttpClient!Malformed(client);
}
