/// The one call boundary from the engine's `nothrow @nogc` task code into a fiber route's full-D handler.
module flint.engine.web.sys.fiber;

import flint.engine.web.fiber : FiberHandler, FiberResponse;
import flint.engine.web.types : Request, RequestContext;

@safe:

// dfmt off
private alias Invoker = bool function(FiberHandler, ref scope Request, ref scope RequestContext,
        FiberResponse) @safe nothrow @nogc;
// dfmt on

// Only RuntimeDriver.dispatchFiber calls this, from a request task that the reactor runs on a druntime Fiber of
// a druntime Thread. The GC scans that fiber's stack and can suspend that thread, so the handler's GC allocations
// are sound there; @nogc is a static property of the engine's own code, not a runtime limit of the fiber.
// SAFETY: the conversion adds only @nogc. callFiber is @safe and nothrow, catches every Exception, and lets an
// Error escape as any nothrow function may; arguments pass through unchanged, so their scope checks stand.
@trusted package(flint.engine.web) bool invokeFiber(FiberHandler handler, ref scope Request request,
        ref scope RequestContext context, FiberResponse response) nothrow @nogc
{
    return (cast(Invoker)&callFiber)(handler, request, context, response);
}

/// Run the handler, reporting whether it returned rather than threw.
private bool callFiber(FiberHandler handler, ref scope Request request, ref scope RequestContext context,
        FiberResponse response) nothrow
{
    try
    {
        handler(request, context, response);
        return true;
    }
    catch (Exception)
        return false;
}
