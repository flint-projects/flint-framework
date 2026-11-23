module flint.context.aot_context_test;

import flint.context : ApplicationEvent;
import flint.context.annotation : AnnotationConfigApplicationContext;
import flint.context.event : ContextRefreshedEvent;
import flint.core.env : MapPropertySource, StandardEnvironment;
import flint.engine.aot.any : Any;
import flint.engine.aot.bean : BeanDefinition, BeanFactory;
import flint.engine.aot.condition : ConditionContext;
import flint.engine.aot.event : EventListenerSpec;
import flint.engine.aot.name : typeNameOf;
import flint.engine.aot.registry : AotRegistry;
import flint.java.util : HashMap, Map;

@safe:

// ---- the application

private interface GreetingRepository
{
    string template_();
}

private final class JdbcGreetingRepository : GreetingRepository
{
    string template_()
    {
        return "Hello, %s!";
    }
}

private final class InMemoryGreetingRepository : GreetingRepository
{
    string template_()
    {
        return "Hi %s";
    }
}

private final class GreetingService
{
    GreetingRepository repository;
    int port;
    string[] seen;
    static bool destroyed;

    this(GreetingRepository repository)
    {
        this.repository = repository;
    }

    string greet(string name)
    {
        import std.format : format;

        return format(repository.template_(), name);
    }

    void onRefreshed(ContextRefreshedEvent)
    {
        seen ~= "refreshed:" ~ format(port);
    }

    private static string format(int value)
    {
        import std.conv : to;

        return value.to!string;
    }

    void onPayload(string payload)
    {
        seen ~= "payload:" ~ payload;
    }
}

// ---- what Flint AOT generates for it (contract sections 3, 5 and 6)

private bool condition_jdbcRepository(ConditionContext c) @safe
{
    return c.acceptsProfile("jdbc") && c.property("flint.datasource.url", "", false);
}

private bool condition_memoryRepository(ConditionContext c) @safe
{
    return !c.hasBeanOfType("flint.context.aot_context_test.GreetingRepository");
}

private Object create_jdbcRepository(BeanFactory) @safe
{
    return new JdbcGreetingRepository;
}

private Object create_memoryRepository(BeanFactory) @safe
{
    return new InMemoryGreetingRepository;
}

private Object create_greetingService(BeanFactory f) @safe
{
    return new GreetingService(cast(GreetingRepository) f.getBeanOfType(typeNameOf!GreetingRepository));
}

private void initialize_greetingService(Object bean, BeanFactory f) @safe
{
    (cast(GreetingService) bean).port = f.resolveValue("${server.port:8080}", "int").get!int;
}

private void destroy_greetingService(Object) @safe
{
    GreetingService.destroyed = true;
}

private void listen_refreshed(Object bean, ref Any event) @safe
{
    (cast(GreetingService) bean).onRefreshed(event.get!ContextRefreshedEvent);
}

private void listen_payload(Object bean, ref Any event) @safe
{
    (cast(GreetingService) bean).onPayload(event.get!string);
}

private BeanDefinition repository(string name, string type, Object function(BeanFactory) @safe create,
        bool function(ConditionContext) @safe condition) @safe
{
    BeanDefinition d;
    d.name = name;
    d.type = type;
    d.types = [type, typeNameOf!GreetingRepository];
    d.create = create;
    d.condition = condition;
    return d;
}

private void populate(scope AotRegistry registry) @safe
{
    registry.begin(1, 1);
    registry.bean(repository("jdbcGreetingRepository", typeNameOf!JdbcGreetingRepository,
            &create_jdbcRepository, &condition_jdbcRepository));
    registry.bean(repository("inMemoryGreetingRepository", typeNameOf!InMemoryGreetingRepository,
            &create_memoryRepository, &condition_memoryRepository));
    BeanDefinition service;
    service.name = "greetingService";
    service.type = typeNameOf!GreetingService;
    service.types = [typeNameOf!GreetingService];
    service.dependsOn = ["inMemoryGreetingRepository"];
    service.create = &create_greetingService;
    service.initialize = &initialize_greetingService;
    service.destroy = &destroy_greetingService;
    registry.bean(service);
    registry.listener(EventListenerSpec("greetingService", typeNameOf!ContextRefreshedEvent, null,
            0, &listen_refreshed));
    registry.listener(EventListenerSpec("greetingService", "string", null, 1, &listen_payload));
    registry.end();
}

unittest
{
    // No profile active: the jdbc repository's condition fails, the fallback registers, @Value takes its default.
    GreetingService.destroyed = false;
    auto context = new AnnotationConfigApplicationContext(&populate);
    auto service = context.getBean!GreetingService();
    assert(service.greet("Ada") == "Hi Ada" && service.port == 8080);
    assert(!context.containsBean("jdbcGreetingRepository"));
    context.publishEvent("ping");
    assert(service.seen == ["refreshed:8080", "payload:ping"]);
    context.close();
    assert(GreetingService.destroyed);
}

unittest
{
    // Profile and property decided at startup: the jdbc repository wins and suppresses the fallback.
    auto context = new AnnotationConfigApplicationContext;
    auto environment = context.getConfigurableEnvironment();
    Map!(string, Any) properties = new HashMap!(string, Any)();
    properties.put("flint.profiles.active", Any.of("jdbc"));
    properties.put("spring.datasource.url", Any.of("jdbc:h2:mem:test")); // the spring.* alias of flint.*
    properties.put("server.port", Any.of("9090"));
    environment.getPropertySources().addFirst(new MapPropertySource("test", properties));
    context.loadAotRegistry(&populate);
    context.refresh();
    assert(context.getBean!GreetingService().greet("Ada") == "Hello, Ada!");
    assert(context.getBean!GreetingService().port == 9090);
    assert(!context.containsBean("inMemoryGreetingRepository"));
    context.close();
}
