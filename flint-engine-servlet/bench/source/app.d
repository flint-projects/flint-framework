/// The servlet engine: options, a servlet at "/", and the unstarted port.
module app;

import flint.engine.servlet : ServletEngine, ServletEngineOptions;
import flint.jakarta.servlet.http : HttpServlet, HttpServletRequest, HttpServletResponse;
import std.conv : to;
import std.stdio : writeln;

@safe:

private final class Hello : HttpServlet
{
    protected override void doGet(HttpServletRequest, HttpServletResponse response)
    {
        response.getWriter().print("hello");
    }
}

int main(string[] args)
{
    ServletEngineOptions options;
    options.port = args.length > 1 ? 0 : 8080;
    auto engine = new ServletEngine(options);
    engine.addServlet("dispatcherServlet", new Hello);
    writeln("registered " ~ engine.getPort().to!string);
    return 0;
}
