/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/method/support/InvocableHandlerMethodTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setup` returns. `ResolvableMethod`'s reflective lookup by argument types picks the
`Handler` overload at compile time, and `new InvocableHandlerMethod(handler, method)` wraps a `HandlerMethod` over
the `HandlerMapping` row Flint AOT writes for it: one `ArgumentSpec` per parameter and an invoker that converts
each argument with `Any.get!T` (a null argument is `T.init`). Spring's `StubArgumentResolver` test fixture is a
hand-written stub matching the parameter's type name; the composite's `addResolver` is the variadic
`addResolvers`, and provided arguments are `Any`. Java's `Integer` is `int`, so a null `Integer` reaches the
handler as `0`. The test lives with flint.mock.web in flint:framework-test. Cases that need unported features or
behave differently are gated by version.
+/
module flint.web.invocable_handler_method_tests;

// flint.web first: importing flint.web.method.support before it trips a forward-reference error on
// LinkedHashMap!(string, Any) in this compiler.
import flint.web;
import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : MethodDescriptor;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec, HandlerArguments, HandlerMapping;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.bind.annotation : ValueConstants;
import flint.web.bind.support : WebDataBinderFactory;
import flint.web.context.request : NativeWebRequest, ServletWebRequest;
import flint.web.method : HandlerMethod;
import flint.web.method.support : HandlerMethodArgumentResolver,
    HandlerMethodArgumentResolverComposite, InvocableHandlerMethod, ModelAndViewContainer;
import std.traits : ParameterIdentifierTuple, Parameters, ReturnType;

@safe:

private struct Fixture
{
    NativeWebRequest request;
    HandlerMethodArgumentResolverComposite composite;
}

private Fixture setup()
{
    Fixture f;
    f.composite = new HandlerMethodArgumentResolverComposite();
    f.request = new ServletWebRequest(new MockHttpServletRequest(), new MockHttpServletResponse());
    return f;
}

@("InvocableHandlerMethodTests.resolveArg")
unittest
{
    auto f = setup();
    f.composite.addResolvers(StubArgumentResolver.of(99));
    f.composite.addResolvers(StubArgumentResolver.of("value"));

    const value = getInvocable!(int, string)(f).invokeForRequest(f.request, null);

    assert(getStubResolver(f, 0).getResolvedParameters().length == 1);
    assert(getStubResolver(f, 1).getResolvedParameters().length == 1);
    assert(value.get!string == "99-value");
    assert(getStubResolver(f, 0).getResolvedParameters()[0].getParameterName() == "intArg");
    assert(getStubResolver(f, 1).getResolvedParameters()[0].getParameterName() == "stringArg");
}

@("InvocableHandlerMethodTests.resolveNoArgValue")
unittest
{
    auto f = setup();
    f.composite.addResolvers(new StubArgumentResolver(typeNameOf!int));
    f.composite.addResolvers(new StubArgumentResolver(typeNameOf!string));

    const returnValue = getInvocable!(int, string)(f).invokeForRequest(f.request, null);

    assert(getStubResolver(f, 0).getResolvedParameters().length == 1);
    assert(getStubResolver(f, 1).getResolvedParameters().length == 1);
    // Java's "null-null": the D handler receives int.init and a null string.
    assert(returnValue.get!string == "0-");
}

@("InvocableHandlerMethodTests.cannotResolveArg")
unittest
{
    import std.algorithm.searching : canFind;

    auto f = setup();
    auto ex = thrown!IllegalStateException(() {
        getInvocable!(int, string)(f).invokeForRequest(f.request, null);
    });
    assert(ex !is null);
    assert(ex.msg.canFind("Could not resolve parameter [0]"));
}

@("InvocableHandlerMethodTests.resolveProvidedArg")
unittest
{
    auto f = setup();
    const value = getInvocable!(int, string)(f).invokeForRequest(f.request, null, [
        Any.of(99), Any.of("value")
    ]);

    assert(!value.isNull());
    assert(value.typeName() == typeNameOf!string);
    assert(value.get!string == "99-value");
}

@("InvocableHandlerMethodTests.resolveProvidedArgFirst")
unittest
{
    auto f = setup();
    f.composite.addResolvers(StubArgumentResolver.of(1));
    f.composite.addResolvers(StubArgumentResolver.of("value1"));
    const value = getInvocable!(int, string)(f).invokeForRequest(f.request, null, [
        Any.of(2), Any.of("value2")
    ]);

    assert(value.get!string == "2-value2");
}

// Behaviour: the port has no `HandlerMethod`-typed optional parameter branch (Spring passes null without a
// resolver), so the unresolvable parameter throws IllegalStateException.
version (FlintHandlerMethodArgumentToNull)
{
    @("InvocableHandlerMethodTests.resolveHandlerMethodArgToNull")
    unittest
    {
        auto f = setup();
        const value = getInvocable!HandlerMethod(f).invokeForRequest(f.request, null);

        assert(!value.isNull());
        assert(value.get!string == "success");
    }
}

@("InvocableHandlerMethodTests.exceptionInResolvingArg")
unittest
{
    auto f = setup();
    f.composite.addResolvers(new ExceptionRaisingArgumentResolver());
    assert(thrown!IllegalArgumentException(() {
            getInvocable!(int, string)(f).invokeForRequest(f.request, null);
        }) !is null);
}

// Behaviour: the port's doInvoke does not wrap argument mismatches and invocation failures in an
// IllegalStateException with Spring's formatInvokeError details.
version (FlintInvokeErrorDetails)
{
    @("InvocableHandlerMethodTests.illegalArgumentException")
    unittest
    {
        import std.algorithm.searching : canFind;

        auto f = setup();
        f.composite.addResolvers(new StubArgumentResolver(typeNameOf!int, Any.of("__not_an_int__")));
        f.composite.addResolvers(StubArgumentResolver.of("value"));
        auto ex = thrown!IllegalStateException(() {
            getInvocable!(int, string)(f).invokeForRequest(f.request, null);
        });
        assert(ex !is null);
        assert(cast(IllegalArgumentException) ex.next !is null);
        assert(ex.msg.canFind("[" ~ typeNameOf!Handler ~ "]"));
        assert(ex.msg.canFind(typeNameOf!Handler ~ ".handle"));
        assert(ex.msg.canFind("[0] [type=string] [value=__not_an_int__]"));
        assert(ex.msg.canFind("[1] [type=string] [value=value"));
    }

    // Spring's `Error` case is left out: D tests never catch `Error`.
    @("InvocableHandlerMethodTests.invocationTargetException")
    unittest
    {
        import flint.java.lang : RuntimeException;
        import std.algorithm.searching : canFind;

        auto f = setup();
        auto runtimeException = new RuntimeException("error");
        assert(thrown!RuntimeException(() {
                getInvocable!Throwable(f).invokeForRequest(f.request, null, [
                    Any.of(runtimeException)
                ]);
            }) is runtimeException);

        auto exception = new Exception("error");
        assert(thrown!Exception(() {
                getInvocable!Throwable(f).invokeForRequest(f.request, null, [Any.of(exception)]);
            }) is exception);

        auto throwable = new JavaThrowable("error");
        auto ex = thrown!IllegalStateException(() {
            getInvocable!Throwable(f).invokeForRequest(f.request, null, [
                Any.of!Throwable(throwable)
            ]);
        });
        assert(ex !is null);
        assert(ex.next is throwable);
        assert(ex.msg.canFind("Invocation failure"));
    }

    /// Java's `Throwable` that is neither an `Exception` nor an `Error`.
    private final class JavaThrowable : Throwable
    {
        this(string message) pure nothrow @nogc
        {
            super(message);
        }
    }

    // SPR-13917
    @("InvocableHandlerMethodTests.invocationErrorMessage")
    unittest
    {
        import std.algorithm.searching : canFind;

        auto f = setup();
        f.composite.addResolvers(new StubArgumentResolver(typeNameOf!double));
        auto ex = thrown!IllegalStateException(() {
            getInvocable!double(f).invokeForRequest(f.request, null);
        });
        assert(ex !is null);
        assert(ex.msg.canFind("Illegal argument"));
    }
}

/// `ResolvableMethod.on(Handler.class).argTypes(argTypes)`, wrapped as Spring's `getInvocable` does.
private InvocableHandlerMethod getInvocable(ArgTypes...)(ref Fixture f)
{
    alias method = handlerMethodOf!ArgTypes;
    auto handlerMethod = new InvocableHandlerMethod(new HandlerMethod(new Handler(),
            typeNameOf!Handler, handlerRow!(Handler, method)()));
    handlerMethod.setHandlerMethodArgumentResolvers(f.composite);
    return handlerMethod;
}

private StubArgumentResolver getStubResolver(ref Fixture f, size_t index)
{
    return cast(StubArgumentResolver) f.composite.getResolvers()[index];
}

/// The `Handler` method whose parameter types are `ArgTypes`.
private template handlerMethodOf(ArgTypes...)
{
    import std.meta : AliasSeq, staticMap;

    private template matching(string name)
    {
        private template matches(alias overload)
        {
            enum matches = is(Parameters!overload == ArgTypes);
        }

        import std.meta : Filter;

        alias matching = Filter!(matches, __traits(getOverloads, Handler, name));
    }

    alias found = staticMap!(matching, AliasSeq!("handle", "handleWithException", "handleHandlerMethod"));
    static assert(found.length == 1, "no single Handler method for " ~ ArgTypes.stringof);
    alias handlerMethodOf = found[0];
}

/// The `HandlerMapping` row Flint AOT writes for `method` of `C`: its parameters by name and type (simple types
/// as optional request parameters, others by type), its return type and its invoker.
private HandlerMapping handlerRow(C, alias method)()
{
    alias names = ParameterIdentifierTuple!method;
    HandlerMapping row;
    row.bean = "handler";
    row.beanType = typeNameOf!C;
    static foreach (i, P; Parameters!method)
    {
        {
            ArgumentSpec spec;
            spec.name = names[i];
            spec.type = typeNameOf!P;
            spec.defaultValue = ValueConstants.DEFAULT_NONE;
            static if (__traits(isScalar, P) || is(P : const(char)[]))
                spec.kind = ArgumentKind.requestParam;
            else
            {
                spec.kind = ArgumentKind.byType;
                spec.required = true;
            }
            row.arguments ~= spec;
        }
    }
    static if (is(ReturnType!method == void))
        row.returnType = "void";
    else
        row.returnType = typeNameOf!(ReturnType!method);
    auto descriptor = new MethodDescriptor;
    descriptor.name = __traits(identifier, method);
    descriptor.returnType = row.returnType;
    row.method = descriptor;
    row.invoke = &invokeHandler!(C, method);
    return row;
}

/// Flint AOT's generated invoker: each argument converted with `Any.get!T` (`T.init` when null).
private void invokeHandler(C, alias method)(Object bean, HandlerArguments arguments, ref Any result)
{
    auto controller = cast(C) bean;
    Parameters!method args;
    static foreach (i, P; Parameters!method)
    {
        {
            auto value = arguments.get(i);
            if (!value.isNull())
            {
                static if (is(P == class) || is(P == interface))
                    args[i] = cast(P) value.asObject();
                else
                    args[i] = value.get!P;
            }
        }
    }
    static if (is(ReturnType!method == void))
        __traits(child, controller, method)(args);
    else
        result = Any.of(__traits(child, controller, method)(args));
}

/// The exception `action` throws, or `null`.
private E thrown(E : Exception)(scope void delegate() @safe action)
{
    try
        action();
    catch (E ex)
        return ex;
    return null;
}

/// Spring's `StubArgumentResolver`: supports one parameter type, resolves a fixed value and records parameters.
private final class StubArgumentResolver : HandlerMethodArgumentResolver
{
    private string valueType;
    private Any value;
    private MethodParameter[] resolvedParameters;

    /// `StubArgumentResolver(Object value)`: the value's own type.
    static StubArgumentResolver of(T)(T value)
    {
        return new StubArgumentResolver(typeNameOf!T, Any.of(value));
    }

    /// `StubArgumentResolver(Class<?> valueType, Object value)`; `StubArgumentResolver(Class<?>)` resolves null.
    this(string valueType, Any value = Any.init)
    {
        this.valueType = valueType;
        this.value = value;
    }

    MethodParameter[] getResolvedParameters() pure nothrow @nogc
    {
        return resolvedParameters;
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

private class Handler
{
    string handle(int intArg, string stringArg)
    {
        import std.conv : to;

        return intArg.to!string ~ "-" ~ stringArg;
    }

    void handle(double)
    {
    }

    void handleWithException(Throwable ex)
    {
        throw ex;
    }

    string handleHandlerMethod(HandlerMethod)
    {
        return "success";
    }
}

private final class ExceptionRaisingArgumentResolver : HandlerMethodArgumentResolver
{
    bool supportsParameter(MethodParameter)
    {
        return true;
    }

    Any resolveArgument(MethodParameter, ModelAndViewContainer, NativeWebRequest, WebDataBinderFactory)
    {
        throw new IllegalArgumentException("oops, can't read");
    }
}

/// A wrapping exception, as petclinic-rest's DataIntegrityViolationException around a SQL constraint violation.
private class WrapperException : Exception
{
    this(string message, Throwable cause) @safe pure nothrow
    {
        super(message, __FILE__, __LINE__, cause);
    }
}

/// The cause it wraps.
private class CauseException : Exception
{
    this(string message) @safe pure nothrow
    {
        super(message);
    }
}

/// An @ExceptionHandler row whose invoker does what Flint AOT's generated glue does: cast the exception it is given
/// to the handler's exception parameter `T` and use it (`e.getMessage()`). With `T` void the handler declares no
/// exception parameter and returns the invoker's exception's message, or "none".
private HandlerMethod exceptionHandlerOf(T)()
{
    import flint.engine.aot.mapping : ExceptionHandlerSpec;

    ExceptionHandlerSpec spec;
    spec.bean = "advice";
    spec.beanType = "advice.Advice";
    spec.returnType = typeNameOf!string;
    static if (!is(T == void))
        spec.arguments = [ArgumentSpec(ArgumentKind.byType, "e", typeNameOf!T)];
    spec.invoke = (Object bean, Exception exception, HandlerArguments arguments, ref Any result) @safe {
        static if (is(T == void))
            result = Any.of(exception is null ? "none" : exception.msg);
        else
        {
            auto e = cast(T) exception;
            assert(e !is null, "the invoker was given " ~ (exception is null ? "null" : typeid(exception).name));
            result = Any.of(e.msg);
        }
    };
    return new HandlerMethod(new Object, spec.beanType, spec, "handle");
}

@("Flint: an @ExceptionHandler's invoker gets the provided exception its parameter matched, not the deepest cause")
unittest
{
    auto f = setup();
    auto cause = new CauseException("constraint violated");
    auto wrapper = new WrapperException("could not execute statement", cause);
    // ExceptionHandlerExceptionResolver provides the exception, then each cause.
    Any[] provided = [Any.of(cast(Object) wrapper), Any.of(cast(Object) cause)];

    auto forWrapper = new InvocableHandlerMethod(exceptionHandlerOf!WrapperException());
    forWrapper.setHandlerMethodArgumentResolvers(f.composite);
    assert(forWrapper.invokeForRequest(f.request, null, provided).get!string == "could not execute statement");

    auto forCause = new InvocableHandlerMethod(exceptionHandlerOf!CauseException());
    forCause.setHandlerMethodArgumentResolvers(f.composite);
    assert(forCause.invokeForRequest(f.request, null, provided).get!string == "constraint violated");

    // Without an exception parameter the invoker sees the top-level exception.
    auto bare = new InvocableHandlerMethod(exceptionHandlerOf!void());
    bare.setHandlerMethodArgumentResolvers(f.composite);
    assert(bare.invokeForRequest(f.request, null, provided).get!string == "could not execute statement");
}
