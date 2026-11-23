/// Reject competing parameter bindings at compilation.
module ambiguous_binding;

import flint.engine.web : Get, PathVariable, QueryParam, RestController, Server, registerController;

@safe:

@RestController("/items")
private struct Items
{
    @Get("/:value") void bad(@PathVariable("value") @QueryParam("value") uint value)nothrow @nogc
    {
        assert(value != 0);
    }
}

/// Instantiate the generated action to check the parameter diagnostic.
void buildRoutes()
{
    Server server;
    Items controller;
    registerController(server, controller);
}
