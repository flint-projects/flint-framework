/// Full-D allocation requires the explicit worker controller annotation.
module hot_allocation;

import flint.arena : Result;
import flint.web : Get, RestController, Server, registerController;

@safe:

@RestController("")
private struct Hot
{
    @Get("/") Result!size_t allocate()
    {
        auto bytes = new ubyte[16];
        return Result!size_t(bytes.length);
    }
}

/// The generated hot adapter must reject this unannotated full-D method.
void buildRoutes()
{
    Server server;
    Hot controller;
    registerController(server, controller);
}
