/++
Flint's prepared invocables: `RequestMappingHandlerAdapter` makes one `ServletInvocableHandlerMethod` per mapped
handler method on the starting thread, and requests share it instead of copying the handler method each time.
+/
module flint.web.servlet.prepared_invocable_tests;

// flint.web first: importing flint.web.method.support before it trips a forward-reference error on
// LinkedHashMap!(string, Any) in this compiler.
import flint.web;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : MethodDescriptor;
import flint.engine.aot.mapping : HandlerArguments, HandlerMapping;
import flint.engine.aot.name : typeNameOf;
import flint.http.converter : HttpMessageConverter, StringHttpMessageConverter;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.method : HandlerMethod;
import flint.web.servlet.mvc.method.annotation : RequestMappingHandlerAdapter;

@safe:

private final class Greeter
{
    int calls;

    string greet()
    {
        import std.conv : to;

        return "hello " ~ (++calls).to!string;
    }
}

/// The `@ResponseBody String greet()` row Flint AOT writes for `Greeter`.
private HandlerMethod greetMethod(Greeter greeter)
{
    HandlerMapping row;
    row.bean = "greeter";
    row.beanType = typeNameOf!Greeter;
    row.returnType = typeNameOf!string;
    row.responseBody = true;
    auto descriptor = new MethodDescriptor;
    descriptor.name = "greet";
    descriptor.returnType = row.returnType;
    row.method = descriptor;
    row.invoke = (Object bean, HandlerArguments, ref Any result) @safe {
        result = Any.of((cast(Greeter) bean).greet());
    };
    return new HandlerMethod(greeter, typeNameOf!Greeter, row);
}

private RequestMappingHandlerAdapter newAdapter()
{
    HttpMessageConverter[] converters = [new StringHttpMessageConverter];
    return new RequestMappingHandlerAdapter(converters);
}

private string handle(RequestMappingHandlerAdapter adapter, HandlerMethod method)
{
    auto response = new MockHttpServletResponse;
    assert(adapter.handle(new MockHttpServletRequest("GET", "/"), response, method) is null);
    return response.getContentAsString();
}

@("Flint: requests share the adapter's prepared invocable, and a changed configuration stops its use")
unittest
{
    auto method = greetMethod(new Greeter);
    auto adapter = newAdapter();
    adapter.prepareInvocables([method]);
    auto prepared = method.getPreparedInvocable(adapter);
    assert(prepared !is null && prepared !is method);
    // Another adapter's resolvers and handlers are not this one's: it finds nothing prepared.
    auto other = newAdapter();
    assert(method.getPreparedInvocable(other) is null);

    assert(handle(adapter, method) == "hello 1");
    assert(handle(adapter, method) == "hello 2");
    assert(method.getPreparedInvocable(adapter) is prepared);
    assert(handle(other, method) == "hello 3");

    // A new binder factory: requests copy the handler method again, as Spring does, until it is prepared anew.
    adapter.setDescriptors(null);
    assert(handle(adapter, method) == "hello 4");
}
