/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/method/support/HandlerMethodArgumentResolverCompositeTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the `@BeforeEach`
fields become a `Fixture` that `setup` returns. The `handle(Integer, String)` parameters that Spring looks up by
reflection are described by their AOT `ArgumentSpec`s; Spring's `StubArgumentResolver` test fixture is a
hand-written stub here, matching the parameter's type name. flint.web.method.support's composite has only the
variadic `addResolvers`, which takes the single resolver Spring passes to `addResolver`; resolved values are `Any`.
The test lives in flint:framework-test with the flint.web.servlet infrastructure ports that use flint.mock.web.
The case where the port throws a different exception type waits behind a version gate.
+/
module flint.web.handler_method_argument_resolver_composite_tests;

// flint.web first: importing flint.web.method.support before it trips a forward-reference error on
// LinkedHashMap!(string, Any) in this compiler.
import flint.web;
import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;
import flint.web.bind.support : WebDataBinderFactory;
import flint.web.context.request : NativeWebRequest;
import flint.web.method.support : HandlerMethodArgumentResolver,
    HandlerMethodArgumentResolverComposite, ModelAndViewContainer;

@safe:

/// Spring's `StubArgumentResolver`: supports one parameter type and resolves a fixed value.
private final class StubArgumentResolver : HandlerMethodArgumentResolver
{
    private string valueType;
    private Any value;
    private MethodParameter[] resolvedParameters;

    /// `StubArgumentResolver(Object value)`: the value's own type.
    static StubArgumentResolver of(T)(T value)
    {
        return new StubArgumentResolver(T.stringof, Any.of(value));
    }

    /// `StubArgumentResolver(Class<?> valueType, Object value)`.
    this(string valueType, Any value = Any.init)
    {
        this.valueType = valueType;
        this.value = value;
    }

    bool supportsParameter(MethodParameter parameter)
    {
        return parameter.getParameterType() == valueType;
    }

    Any resolveArgument(MethodParameter parameter, ModelAndViewContainer, NativeWebRequest, WebDataBinderFactory)
    {
        resolvedParameters ~= parameter;
        return value;
    }
}

private struct Fixture
{
    HandlerMethodArgumentResolverComposite resolverComposite;
    MethodParameter paramInt;
    MethodParameter paramStr;
}

private Fixture setup()
{
    Fixture f;
    f.resolverComposite = new HandlerMethodArgumentResolverComposite();

    // private void handle(Integer arg1, String arg2)
    enum method = "HandlerMethodArgumentResolverCompositeTests.handle";
    f.paramInt = new MethodParameter(ArgumentSpec(ArgumentKind.byType, "arg1", "int"), 0, method);
    f.paramStr = new MethodParameter(ArgumentSpec(ArgumentKind.byType, "arg2", "string"), 1, method);
    return f;
}

@("HandlerMethodArgumentResolverCompositeTests.supportsParameter")
unittest
{
    auto f = setup();
    f.resolverComposite.addResolvers(new StubArgumentResolver("int"));

    assert(f.resolverComposite.supportsParameter(f.paramInt));
    assert(!f.resolverComposite.supportsParameter(f.paramStr));
}

@("HandlerMethodArgumentResolverCompositeTests.resolveArgument")
unittest
{
    auto f = setup();
    f.resolverComposite.addResolvers(StubArgumentResolver.of(55));
    const resolvedValue = f.resolverComposite.resolveArgument(f.paramInt, null, null, null);

    assert(resolvedValue == Any.of(55));
}

@("HandlerMethodArgumentResolverCompositeTests.checkArgumentResolverOrder")
unittest
{
    auto f = setup();
    f.resolverComposite.addResolvers(StubArgumentResolver.of(1));
    f.resolverComposite.addResolvers(StubArgumentResolver.of(2));
    const resolvedValue = f.resolverComposite.resolveArgument(f.paramInt, null, null, null);

    assert(resolvedValue == Any.of(1), "Didn't use the first registered resolver");
}

import flint.java.lang : IllegalArgumentException;

@("HandlerMethodArgumentResolverCompositeTests.noSuitableArgumentResolver")
unittest
{
    auto f = setup();
    bool thrown;
    try
        f.resolverComposite.resolveArgument(f.paramStr, null, null, null);
    catch (IllegalArgumentException)
        thrown = true;
    assert(thrown);
}
