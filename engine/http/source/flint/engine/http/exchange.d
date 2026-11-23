/// Compile annotated interface methods into a bounded HTTP client.
module flint.engine.http.exchange;

import flint.engine.http.client : HttpClient;
import flint.engine.http.internal.exchange : makeExchange;

@safe:

/// Bind an already opened transport. The adapter shares the transport's owner and lifetime.
Client bindHttpClient(Client)(ref HttpClient transport)
{
    return makeExchange!Client(transport);
}
