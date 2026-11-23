/// The servlet engine: options, a servlet at "/", and the unstarted port.
module app;

import flint.engine.servlet : ServletEngine, ServletEngineOptions;
import flint.jakarta.servlet.http : HttpServlet, HttpServletRequest, HttpServletResponse;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

/// Decimal text of a small non-negative number, without std.conv.
private string digits(long value) pure nothrow
{
    if (value < 0)
        return "-" ~ digits(-value);
    return value < 10 ? [cast(char)('0' + value)] : digits(value / 10) ~ cast(char)('0' + value % 10);
}

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
    emit("registered " ~ digits(engine.getPort()));
    return 0;
}
