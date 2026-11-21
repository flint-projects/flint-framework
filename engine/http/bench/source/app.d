/// Exercise the production HTTP streaming client over a warm verified TLS connection.
module app;

import flint.arena : Error, RequestArena, Status;
import flint.conc : Context;
import flint.http : ClientOptions, HttpClient, HttpRequest;
import http_workload : ObserveBytes, configure, run;
import std.exception : enforce;

@safe:

/// Run both fixed HTTPS payload workloads.
int main()
{
    string[2] urls;
    ClientOptions options;
    configure(urls, options.caBundle);

    HttpClient transport;
    enforce(transport.open(options).code == Status.ok, "pinned HTTP provider initialization failed");
    scope (exit)
        enforce(transport.close().code == Status.ok, "HTTP transport did not close");
    HttpRequest[2] requests;
    foreach (index, url; urls)
        requests[index].url = url;
    ubyte[1] storage;
    auto arena = RequestArena(storage[]);
    Context context;
    return run((size_t index, scope ObserveBytes observe) {
        const result = transport.stream(requests[index], arena, context, (scope const(ubyte)[] bytes) {
            observe(bytes);
            return Error.init;
        });
        return result.ok && result.value == 200;
    });
}
