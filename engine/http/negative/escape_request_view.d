module escape_request_view;

import flint.http : HttpRequestView;

@safe:

private const(ubyte)[] leaked;

private void escape(scope const ref HttpRequestView request) nothrow @nogc
{
    leaked = request.body;
}
