/// Reject structurally identical paths with different capture names at compilation.
module duplicate_routes;

import flint.engine.web : Get, RestController, Server, registerController;

@safe:

@RestController("/orders")
private struct Orders
{
    @Get("/:id") void primary() nothrow @nogc
    {
    }

    @Get("/:order") void duplicate() nothrow @nogc
    {
    }
}

/// Instantiate this route table to check the diagnostic.
void buildRoutes()
{
    Server server;
    Orders controller;
    registerController(server, controller);
}
