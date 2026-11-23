/// spring-webmvc: a DispatcherServlet with Spring MVC's default strategies, built by WebMvcConfigurationSupport.
module app;

import flint.web.servlet : DispatcherServlet;
import flint.web.servlet.config.annotation : WebMvcConfigurationSupport;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

int main(string[] args)
{
    auto support = new WebMvcConfigurationSupport(null, null, null);
    auto servlet = new DispatcherServlet(support.build());
    servlet.setDispatchOptionsRequest(args.length <= 1);
    emit(servlet.getServletName() ~ " " ~ (servlet.getHandlerMappings().length != 0 ? "mapped" : "unmapped"));
    return 0;
}
