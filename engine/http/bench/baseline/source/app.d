/// Run the fixed HTTPS probe directly against the pinned provider.
module app;

import curl_reference : Provider;
import http_workload : ObserveBytes, configure, run;
import std.exception : enforce;

@safe:

/// Run the provider control for the same warm verified TLS transfers.
int main()
{
    string[2] urls;
    string ca;
    configure(urls, ca);
    Provider reference;
    enforce(reference.open(urls, ca), "pinned libcurl provider initialization failed");
    scope (exit)
        reference.close();
    return run((size_t index, scope ObserveBytes observe) { return reference.fetch(index, observe); });
}
