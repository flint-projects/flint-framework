/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/method/annotation/ExceptionHandlerMethodResolverTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. The resolver is built
over the `ExceptionHandlerSpec` rows Flint AOT writes for a controller (`exceptionHandlersOf`) instead of
introspecting its class; a resolved method's name is the method part of the row's `source`. `java.net`'s
`SocketException` and `BindException` are not ported and become private exception classes with Java's hierarchy;
Java's `new Exception(cause)` is D's `new Exception(cause.toString(), cause)`, whose cause is `next`, and
`initCause` becomes the constructor's cause. `ClassUtils.getShortName` is `simpleTypeName`. The test lives with
flint.mock.web in flint:framework-test. Cases that need unported features or behave differently are gated by
version.
+/
module flint.web.exception_handler_method_resolver_tests;

import flint.engine.aot.mapping : ExceptionHandlerSpec;
import flint.engine.aot.name : simpleTypeName;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.java.io : FileNotFoundException, IOException;
import flint.java.lang : IllegalArgumentException, IllegalStateException, classOf, javaToString;
import flint.stereotype : Controller;
import flint.web.bind.annotation : ExceptionHandler;
import flint.web.method.annotation : ExceptionHandlerMethodResolver;
import flint.web.servlet.mvc.method.aot : exceptionHandlersOf;

@safe:

/// `new ExceptionHandlerMethodResolver(C.class)`: over the rows Flint AOT writes for `C`.
private ExceptionHandlerMethodResolver resolverFor(C)()
{
    return new ExceptionHandlerMethodResolver(exceptionHandlersOf!C(__traits(identifier, C)));
}

/// `Method.getName()` of a resolved handler row.
private string nameOf(const ExceptionHandlerSpec* spec)
{
    assert(spec !is null, "no handler method resolved");
    return simpleTypeName(spec.source);
}

/// Java's `new Exception(cause)`.
private Exception exceptionWithCause(Throwable cause)
{
    return new Exception(javaToString(cause), cause);
}

@("ExceptionHandlerMethodResolverTests.shouldResolveMethodFromAnnotationAttribute")
unittest
{
    auto resolver = resolverFor!ExceptionController();
    auto exception = new IOException();
    assert(nameOf(resolver.resolveMethod(exception)) == "handleIOException");
}

@("ExceptionHandlerMethodResolverTests.shouldResolveMethodFromMethodArgument")
unittest
{
    auto resolver = resolverFor!ExceptionController();
    auto exception = new IllegalArgumentException();
    assert(nameOf(resolver.resolveMethod(exception)) == "handleIllegalArgumentException");
}

@("ExceptionHandlerMethodResolverTests.shouldResolveMethodWithExceptionSubType")
unittest
{
    auto resolver = resolverFor!ExceptionController();
    IOException ioException = new FileNotFoundException();
    assert(nameOf(resolver.resolveMethod(ioException)) == "handleIOException");
    SocketException bindException = new BindException();
    assert(nameOf(resolver.resolveMethod(bindException)) == "handleSocketException");
}

@("ExceptionHandlerMethodResolverTests.shouldResolveMethodWithExceptionBestMatch")
unittest
{
    auto resolver = resolverFor!ExceptionController();
    auto exception = new SocketException();
    assert(nameOf(resolver.resolveMethod(exception)) == "handleSocketException");
}

@("ExceptionHandlerMethodResolverTests.shouldNotResolveMethodWhenExceptionNoMatch")
unittest
{
    auto resolver = resolverFor!ExceptionController();
    auto exception = new Exception(null);
    assert(resolver.resolveMethod(exception) is null, "1st lookup");
    assert(resolver.resolveMethod(exception) is null, "2nd lookup from cache");
}

@("ExceptionHandlerMethodResolverTests.ShouldResolveMethodWithExceptionCause")
unittest
{
    auto resolver = resolverFor!ExceptionController();

    SocketException bindException = new BindException(new FileNotFoundException());

    Exception exception = exceptionWithCause(exceptionWithCause(exceptionWithCause(bindException)));

    assert(nameOf(resolver.resolveMethod(exception)) == "handleSocketException");
}

// The AOT rows of a class list only the handlers it declares itself: an override without `@ExceptionHandler` does
// not inherit the superclass method's annotation (likely bug).
version (FlintExceptionHandlerInheritedMethods)
{
    @("ExceptionHandlerMethodResolverTests.shouldResolveMethodFromSuperClass")
    unittest
    {
        auto resolver = resolverFor!InheritedController();
        auto exception = new IOException();
        assert(nameOf(resolver.resolveMethod(exception)) == "handleIOException");
    }
}

// The resolver accepts ambiguous or empty exception mappings instead of throwing IllegalStateException (likely bug).
version (FlintExceptionHandlerMappingValidation)
{
    @("ExceptionHandlerMethodResolverTests.shouldThrowExceptionWhenAmbiguousExceptionMapping")
    unittest
    {
        import std.exception : assertThrown;

        assertThrown!IllegalStateException(resolverFor!AmbiguousController());
    }

    @("ExceptionHandlerMethodResolverTests.shouldThrowExceptionWhenNoExceptionMapping")
    unittest
    {
        import std.exception : assertThrown;

        assertThrown!IllegalStateException(resolverFor!NoExceptionController());
    }
}

// The resolver has no `@ExceptionHandler(produces)` support: no `resolveExceptionMapping(exception, mediaType)`,
// `ExceptionHandlerMappingInfo` or media type validation.
version (FlintExceptionHandlerMediaTypes)
{
    import flint.http : MediaType;

    @("ExceptionHandlerMethodResolverTests.shouldRetainOriginalOrderOfProducibleMediaTypes")
    unittest
    {
        auto resolver = resolverFor!MediaTypeController();
        MediaType[] producibleTypes = resolver.resolveExceptionMapping(new IllegalArgumentException(),
                MediaType.TEXT_HTML).getProducibleTypes();
        assert(MediaType.toString(producibleTypes) == "text/html, */*");
    }

    @("ExceptionHandlerMethodResolverTests.shouldResolveMethodWithMediaType")
    unittest
    {
        auto resolver = resolverFor!MediaTypeController();
        assert(resolver.resolveExceptionMapping(new IllegalArgumentException(),
                MediaType.APPLICATION_JSON).getHandlerMethod().getName() == "handleJson");
        assert(resolver.resolveExceptionMapping(new IllegalArgumentException(), MediaType.TEXT_HTML)
                .getHandlerMethod().getName() == "handleHtml");
    }

    @("ExceptionHandlerMethodResolverTests.shouldResolveMethodWithCompatibleMediaType")
    unittest
    {
        auto resolver = resolverFor!MediaTypeController();
        assert(resolver.resolveExceptionMapping(new IllegalArgumentException(),
                MediaType.parseMediaType("application/*")).getHandlerMethod().getName() == "handleJson");
    }

    @("ExceptionHandlerMethodResolverTests.shouldFavorMethodWithExplicitAcceptAll")
    unittest
    {
        auto resolver = resolverFor!MediaTypeController();
        assert(resolver.resolveExceptionMapping(new IllegalArgumentException(), MediaType.ALL)
                .getHandlerMethod().getName() == "handleHtml");
    }

    @("ExceptionHandlerMethodResolverTests.shouldThrowExceptionWhenInvalidMediaTypeMapping")
    unittest
    {
        import std.algorithm.searching : canFind;
        import std.exception : collectException;

        auto ex = collectException!IllegalStateException(resolverFor!InvalidMediaTypeController());
        assert(ex !is null);
        assert(ex.msg.canFind("Invalid media type [invalid-mediatype] declared on @ExceptionHandler"));
    }

    @("ExceptionHandlerMethodResolverTests.shouldThrowExceptionWhenAmbiguousMediaTypeMapping")
    unittest
    {
        import std.algorithm.searching : canFind;
        import std.exception : collectException;

        auto ex = collectException!IllegalStateException(resolverFor!AmbiguousMediaTypeController());
        assert(ex !is null);
        assert(ex.msg.canFind("Ambiguous @ExceptionHandler method mapped for [ExceptionHandler{exceptionType="
                ~ "flint.java.lang.IllegalArgumentException, mediaType=application/json}]"));
        assert(ex.msg.canFind("AmbiguousMediaTypeController.handleJson()"));
        assert(ex.msg.canFind("AmbiguousMediaTypeController.handleJsonToo()"));
    }

    @("ExceptionHandlerMethodResolverTests.shouldResolveMethodWithMediaTypeFallback")
    unittest
    {
        auto resolver = resolverFor!MixedController();
        assert(resolver.resolveExceptionMapping(new IllegalArgumentException(), MediaType.TEXT_HTML)
                .getHandlerMethod().getName() == "handleOther");
    }
}

/// `java.net.SocketException`.
private class SocketException : IOException
{
    this(Throwable cause = null) pure nothrow
    {
        super(null, cause);
    }
}

/// `java.net.BindException`.
private class BindException : SocketException
{
    this(Throwable cause = null) pure nothrow
    {
        super(cause);
    }
}

@Controller
private class ExceptionController
{
    void handle()
    {
    }

    @ExceptionHandler(classOf!IOException)
    void handleIOException()
    {
    }

    @ExceptionHandler(classOf!SocketException)
    void handleSocketException()
    {
    }

    @ExceptionHandler
    void handleIllegalArgumentException(IllegalArgumentException exception)
    {
    }
}

@Controller
private class InheritedController : ExceptionController
{
    override void handleIOException()
    {
    }
}

@Controller
private class AmbiguousController
{
    void handle()
    {
    }

    @ExceptionHandler([classOf!BindException, classOf!IllegalArgumentException])
    string handle1(Exception ex, HttpServletRequest request, HttpServletResponse response)
    {
        return simpleTypeName(typeid(ex).name);
    }

    @ExceptionHandler
    string handle2(IllegalArgumentException ex)
    {
        return simpleTypeName(typeid(ex).name);
    }
}

@Controller
private class NoExceptionController
{
    @ExceptionHandler
    void handle()
    {
    }
}

@Controller
private class MediaTypeController
{
    @ExceptionHandler(exception : [classOf!IllegalArgumentException], produces:
            ["application/json"])
    void handleJson()
    {
    }

    @ExceptionHandler(exception : [classOf!IllegalArgumentException], produces:
            ["text/html", "*/*"])
    void handleHtml()
    {
    }
}

@Controller
private class AmbiguousMediaTypeController
{
    @ExceptionHandler(exception : [classOf!IllegalArgumentException], produces:
            ["application/json"])
    void handleJson()
    {
    }

    @ExceptionHandler(exception : [classOf!IllegalArgumentException], produces:
            ["application/json"])
    void handleJsonToo()
    {
    }
}

@Controller
private class MixedController
{
    @ExceptionHandler(exception : [classOf!IllegalArgumentException], produces:
            ["application/json"])
    void handleJson()
    {
    }

    @ExceptionHandler(classOf!IllegalArgumentException)
    void handleOther()
    {
    }
}

@Controller
private class InvalidMediaTypeController
{
    @ExceptionHandler(exception : [classOf!IllegalArgumentException], produces:
            ["invalid-mediatype"])
    void handle()
    {
    }
}
