module http_negative.ambiguous_header;

import flint.arena : RequestArena, Result;
import flint.conc : Context;
import flint.engine.http : GetExchange, HeaderParam, HttpClient, HttpExchange, HttpResponse, bindHttpClient;

@HttpExchange("https://example.com")
private interface Malformed
{
    /// Invalid declaration used to check the generator diagnostic.
    @GetExchange("/info")
    Result!HttpResponse conflictingHeaders(ref scope RequestArena arena, ref Context context,
            @HeaderParam("X-Id") string id, @HeaderParam("x-id") string secondId)@safe nothrow @nogc;
}

private Malformed fails(ref HttpClient client) @safe
{
    return bindHttpClient!Malformed(client);
}
