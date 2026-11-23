/// spring-webmvc: a DispatcherServlet with Spring MVC's default strategies, built by WebMvcConfigurationSupport.
module app;

import flint.web.servlet : DispatcherServlet;
import flint.web.servlet.config.annotation : WebMvcConfigurationSupport;
import std.stdio : writeln;

@safe:

int main(string[] args)
{
    auto support = new WebMvcConfigurationSupport(null, null, null);
    auto servlet = new DispatcherServlet(support.build());
    servlet.setDispatchOptionsRequest(args.length <= 1);
    writeln(servlet.getServletName() ~ " " ~ (servlet.getHandlerMappings().length != 0 ? "mapped" : "unmapped"));
    return 0;
}
