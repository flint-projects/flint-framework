/++
gs-rest-service over real HTTP: the guide's unchanged `GreetingController` (framework-test's port of it), Spring
MVC's default `DispatcherServlet` from `WebMvcConfigurationSupport`, served by `flint.engine.servlet`.

This is the servlet engine's proof fixture, not the gs-rest-service Flint port. The port is a Boot application
under `benchmarks/spring/flint/gs-rest-service/`; it arrives with Boot's web server auto-configuration, which
builds this same servlet and engine. The port comes from `SERVER_PORT`, as for every implementation the harness
scores (`benchmarks/spring/README.md`).
+/
module app;

import com.example.restservice : GreetingController;
import flint.engine.aot.any : Any;
import flint.engine.aot.bean : BeanFactory;
import flint.engine.aot.descriptor : DescriptorTable;
import flint.engine.servlet : ServletEngine, ServletEngineOptions;
import flint.http.converter.json : JacksonJsonHttpMessageConverter;
import flint.java.lang : IllegalStateException;
import flint.web.servlet : DispatcherServlet;
import flint.web.servlet.config.annotation : WebMvcConfigurationSupport;
import flint.web.servlet.mvc.method.aot : exceptionHandlersOf, handlerDescriptorsOf, requestMappingsOf;

@safe:

/// The application's single bean, as the guide's component scan finds it.
private final class Beans : BeanFactory
{
    private Object controller;

    this(Object controller) pure nothrow @nogc
    {
        this.controller = controller;
    }

    Object getBean(string name)
    {
        if (name == "greetingController")
            return controller;
        throw new IllegalStateException("No bean named '" ~ name ~ "' available");
    }

    Object getBeanOfType(string type, string qualifier = null)
    {
        if (auto bean = findBeanOfType(type, qualifier))
            return bean;
        throw new IllegalStateException("No qualifying bean of type '" ~ type ~ "' available");
    }

    Object findBeanOfType(string type, string = null)
    {
        return typeid(controller).name == type ? controller : null;
    }

    Object[] getBeansOfType(string type)
    {
        return typeid(controller).name == type ? [controller] : null;
    }

    Any resolveValue(string, string)
    {
        throw new IllegalStateException("no environment in the servlet engine's proof fixture");
    }

    void bind(string, Any)
    {
    }

    Any bindConstructor(string, string)
    {
        throw new IllegalStateException("no environment in the servlet engine's proof fixture");
    }
}

/// The `DispatcherServlet` Spring Boot's `WebMvcAutoConfiguration` would build for this one controller.
DispatcherServlet dispatcherServlet()
{
    enum name = "greetingController";
    auto controller = new GreetingController();
    auto table = DescriptorTable.withBuiltins();
    auto descriptors = handlerDescriptorsOf!GreetingController();
    foreach (descriptor; descriptors)
        table.add(descriptor);
    auto support = new WebMvcConfigurationSupport(requestMappingsOf!GreetingController(name),
            exceptionHandlersOf!GreetingController(name), new Beans(controller), null, table);
    auto converters = support.getMessageConverters();
    foreach (converter; converters)
        if (auto json = cast(JacksonJsonHttpMessageConverter) converter)
            foreach (descriptor; descriptors)
                json.getMapper().descriptors().add(descriptor);
    support.setMessageConverters(converters);
    return new DispatcherServlet(support.build());
}

void main() @system
{
    import core.thread : Thread;
    import core.time : dur;
    import std.conv : to;
    import std.process : environment;
    import std.stdio : stdout, writeln;

    ServletEngineOptions options;
    options.port = environment.get("SERVER_PORT", "8080").to!ushort;
    auto engine = new ServletEngine(options);
    engine.addServlet("dispatcherServlet", dispatcherServlet());
    engine.start();
    writeln("gs-rest-service proof listening on port ", engine.getPort());
    stdout.flush();
    for (;;)
        Thread.sleep(dur!"seconds"(3600));
}
