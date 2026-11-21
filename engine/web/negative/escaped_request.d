/// A scoped handler cannot persist the request's internal connection reference.
module escaped_request;

import flint.arena : Result;
import flint.web : Request, RequestContext, Response;

@safe:

private Request retained;

/// This assignment must fail before an escaped request could be used.
Result!Response reject(ref scope Request request, ref scope RequestContext context) nothrow @nogc
{
    retained = request;
    return Result!Response(Response.init);
}
