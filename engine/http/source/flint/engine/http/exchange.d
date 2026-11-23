/// Compile annotated interface methods into a bounded HTTP client.
module flint.engine.http.exchange;

import flint.arena : Result;
import flint.engine.http.client : HttpClient;
import flint.engine.http.internal.exchange : makeExchange;

@safe:

/// Bind an already opened transport. The adapter shares the transport's owner and lifetime.
Client bindHttpClient(Client)(ref HttpClient transport)
{
    return makeExchange!Client(transport);
}

/// Bind an already opened transport to `baseUrl` in place of the interface's `HttpExchange` base, as a
/// client's base URL does in Spring. The base follows the annotation's rules: HTTP or HTTPS, with an
/// optional path and no query or fragment; otherwise the result is `invalidArgument`.
Result!Client bindHttpClient(Client)(ref HttpClient transport, string baseUrl)
{
    return makeExchange!Client(transport, baseUrl);
}
