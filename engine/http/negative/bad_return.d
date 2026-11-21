module http_negative.bad_return;

import flint.arena : RequestArena, Result;
import flint.conc : Context;
import flint.http : GetExchange, HttpClient, HttpExchange, bindHttpClient;

@HttpExchange("https://example.com")
private interface Malformed
{
    /// Invalid declaration used to check the generator diagnostic.
    @GetExchange("/info")
    Result!int scalarResponse(ref scope RequestArena arena, ref Context context) @safe nothrow @nogc;
}

private Malformed fails(ref HttpClient client) @safe
{
    return bindHttpClient!Malformed(client);
}
