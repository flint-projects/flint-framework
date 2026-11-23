module flint.engine.web.router_behavior;

import flint.arena : Error, Result, Status;
import flint.engine.web : ApiVersion, Get, Handler, Method, PathVariable, Request, RequestContext,
    Response, RestController, RouteRegistration, Server, registerController;
import flint.engine.web.router : RouteTable;

@safe:

@("radix matching respects literal, named and final wildcard order and preserves trailing slash")
unittest
{
    Handler prefix = (ref scope Request, ref scope RequestContext) @safe nothrow @nogc {
        return Result!Response(Response.init);
    };
    Handler literal = (ref scope Request, ref scope RequestContext) @safe nothrow @nogc {
        return Result!Response(Response(201));
    };
    Handler wildcard = (ref scope Request, ref scope RequestContext) @safe nothrow @nogc {
        return Result!Response(Response(202));
    };
    auto table = new RouteTable;
    assert(table.insert(Method.get, "/shop/:category", prefix).code == Status.ok);
    assert(table.insert(Method.get, "/shop/books", literal).code == Status.ok);
    assert(table.insert(Method.get, "/shop/*remainder", wildcard).code == Status.ok);
    assert(table.insert(Method.get, "/shop/:name", prefix).code == Status.conflict);
    assert(table.insert(Method.get, "/shop/*category/last", prefix).code == Status.invalidArgument);

    assert(table.find(Method.get, cast(const(ubyte)[]) "/shop/b%6foks").handler == literal);
    auto single = table.find(Method.get, cast(const(ubyte)[]) "/shop/food");
    assert(single.handler == prefix && single.count == 1 && single.captures[0].name == "category");
    auto multiple = table.find(Method.get, cast(const(ubyte)[]) "/shop/food/");
    assert(multiple.handler == wildcard && multiple.count == 1 && multiple.captures[0].name == "remainder");
    assert(table.find(Method.get, cast(const(ubyte)[]) "/shop/food/%2F").error.code == Status.invalidArgument);
    assert(table.find(Method.get, cast(const(ubyte)[]) "/shop").error.code == Status.notFound);
}

@RestController("/typed")
@ApiVersion(2)
private struct Checked
{
    @Get("/:number")
    Error path(@PathVariable("number") uint number, ref scope RequestContext context)nothrow @nogc
    {
        assert(number != 0 && !context.cancellation.cancelled());
        return Error.init;
    }
}

@("the compiler generates typed route bindings for an explicit versioned controller")
unittest
{
    Server server;
    Checked controller;
    // The bound code is generated, but admission requires an initialized server.
    assert(registerController(server, controller).code == Status.conflict);
}

@("borrowed handler parameters retain ordinary ref syntax")
unittest
{
    Handler action = (ref scope Request request, ref scope RequestContext context) @safe nothrow @nogc {
        assert(request.path().error.code == Status.invalidArgument);
        assert(!context.cancellation.cancelled());
        return Result!Response(Response(204));
    };
    Request request;
    RequestContext context;
    assert(action(request, context).value.status == 204);
}

@("a rejected route batch leaves the startup table intact")
unittest
{
    Handler action = (ref scope Request, ref scope RequestContext) @safe nothrow @nogc {
        return Result!Response(Response.init);
    };
    auto table = new RouteTable;
    assert(table.insert(Method.get, "/existing/:id", action).code == Status.ok);
    RouteRegistration[2] rejected = [
        RouteRegistration(Method.get, "/new", action),
        RouteRegistration(Method.get, "/existing/:name", action)
    ];
    assert(table.insertBatch(rejected[]).code == Status.conflict);
    assert(table.find(Method.get, cast(const(ubyte)[]) "/new").error.code == Status.notFound);
    rejected[1].path = "/other";
    assert(table.insertBatch(rejected[]).code == Status.ok);
    assert(table.find(Method.get, cast(const(ubyte)[]) "/new").handler == action);
    assert(table.find(Method.get, cast(const(ubyte)[]) "/other").handler == action);
}

@("an unmatched method on an existing path reports every method its matching routes serve")
unittest
{
    Handler handler = (ref scope Request, ref scope RequestContext) @safe nothrow @nogc {
        return Result!Response(Response.init);
    };
    auto table = new RouteTable;
    assert(table.insert(Method.post, "/items/new", handler).code == Status.ok);
    assert(table.insert(Method.get, "/items/:id", handler).code == Status.ok);
    assert(table.insert(Method.delete_, "/items/:id", handler).code == Status.ok);

    enum bit = (Method method) => cast(ubyte)(1 << method);
    // Backtracking still finds GET through the parameter route.
    auto backtracked = table.find(Method.get, cast(const(ubyte)[]) "/items/new");
    assert(backtracked.handler == handler && backtracked.allowed == 0);
    auto refused = table.find(Method.put, cast(const(ubyte)[]) "/items/new");
    assert(refused.error.code == Status.notFound && refused.handler is null);
    assert(refused.allowed == (bit(Method.post) | bit(Method.get) | bit(Method.head) | bit(Method.delete_)));
    auto parameter = table.find(Method.post, cast(const(ubyte)[]) "/items/7");
    assert(parameter.allowed == (bit(Method.get) | bit(Method.head) | bit(Method.delete_)));
    // HEAD is served by GET, so it never produces 405 here.
    assert(table.find(Method.head, cast(const(ubyte)[]) "/items/7").handler == handler);
    auto missing = table.find(Method.get, cast(const(ubyte)[]) "/items");
    assert(missing.error.code == Status.notFound && missing.allowed == 0);
    assert(table.find(Method.get, cast(const(ubyte)[]) "/other").allowed == 0);
}
