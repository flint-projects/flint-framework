/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/annotation/
RequestMappingHandlerMappingTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. flint.web.servlet's
`RequestMappingHandlerMapping` is built from Flint AOT's request-mapping rows and a `BeanFactory` instead of
detecting controllers in an application context, so `createMapping()` is a factory over a controller's rows
(`requestMappingsOf!C`, what Flint AOT writes for it, with a `StaticBeanFactory` holding the controller), and
`getMappingForMethod(method, C)` is the `RequestMappingInfo` that mapping registers for the row of that method.
`info.getPatternValues()` and `info.getXxxCondition().getYyy()` read `RequestMappingInfo`'s flat accessors. Each
`@PathPatternsParameterizedTest` is one unittest that loops over the named factories of `pathPatternsArguments()`,
whose `AntPathMatcher` variant waits behind the `PathMatcher` gate. Java's `delete()` handler is `delete_()`, as
`delete` is a D keyword. The test lives with flint.mock.web in flint:framework-test. Cases that need unported
features wait behind version gates.
+/
module flint.web.request_mapping_handler_mapping_tests;

import flint.engine.aot.bean : BeanFactory;
import flint.engine.aot.mapping : AotHandlerMapping = HandlerMapping;
import flint.engine.aot.name : typeNameOf;
import flint.http : MediaType;
import flint.core.annotation : AliasFor;
import flint.java.lang : ClassRef;
import flint.stereotype : Controller;
import flint.test.web.servlet.setup : StaticBeanFactory;
import flint.web.bind.annotation : DeleteMapping, GetMapping, PatchMapping, PostMapping,
    RequestBody, RequestMapping, RequestMethod;
import flint.web.servlet.mvc.method : RequestMappingInfo;
import flint.web.servlet.mvc.method.annotation : RequestMappingHandlerMapping;
import flint.web.servlet.mvc.method.aot : requestMappingsOf;

@safe:

/// A `RequestMappingHandlerMapping` over a controller's AOT rows and the bean factory that holds the controller.
private alias MappingFactory = RequestMappingHandlerMapping delegate(AotHandlerMapping[], BeanFactory) @safe;

private struct NamedMapping
{
    string name;
    MappingFactory create;
}

private NamedMapping[] pathPatternsArguments()
{
    NamedMapping[] result = [
        NamedMapping("PathPatternParser", (rows, beanFactory) => new RequestMappingHandlerMapping(rows, beanFactory))
    ];
    // flint.web.servlet's RequestMappingHandlerMapping matches parsed PathPatterns only (no setPatternParser(null)).
    version (FlintPathMatcher)
        result ~= NamedMapping("AntPathMatcher", (rows, beanFactory) {
            auto mapping = new RequestMappingHandlerMapping(rows, beanFactory);
            mapping.setPatternParser(null);
            return mapping;
        });
    return result;
}

/// `createMapping()`: a mapping with default settings.
private MappingFactory createMapping()
{
    return (rows, beanFactory) => new RequestMappingHandlerMapping(rows, beanFactory);
}

/// `mapping.getMappingForMethod(method, C)`: the info the mapping registers for `C`'s row of `methodName`, or
/// `null` when the method has no request mapping.
private RequestMappingInfo getMappingForMethod(C)(MappingFactory mapping, string methodName)
{
    foreach (row; requestMappingsOf!C("controller"))
    {
        if (row.method.name != methodName)
            continue;
        auto beanFactory = new StaticBeanFactory;
        beanFactory.addBean("controller", new C);
        return mapping([row], beanFactory).getHandlerMethods()[0];
    }
    return null;
}

/// `info.getPatternValues()`.
private string[] getPatternValues(RequestMappingInfo info)
{
    string[] result;
    foreach (pattern; info.getPatterns())
        result ~= pattern.getPatternString();
    return result;
}

/// `info.getMethodsCondition().getMethods()`, as `RequestMethod` names.
private string[] getMethods(RequestMappingInfo info)
{
    string[] result;
    foreach (method; info.getMethods())
        result ~= method.name();
    return result;
}

private RequestMappingInfo assertComposedAnnotationMapping(RequestMethod requestMethod)
{
    import std.uni : toLower;

    auto mapping = createMapping();

    const methodName = requestMethod.name().toLower();
    const path = "/" ~ methodName;

    return assertComposedAnnotationMapping(mapping, methodName, path, requestMethod);
}

private RequestMappingInfo assertComposedAnnotationMapping(MappingFactory mapping, string methodName,
        string path, RequestMethod requestMethod)
{
    // `delete` is a D keyword: the handler is `delete_`.
    auto info = getMappingForMethod!ComposedAnnotationController(mapping, methodName == "delete"
            ? "delete_" : methodName);

    assert(info !is null, methodName);

    const paths = getPatternValues(info);
    assert(paths == [path], methodName);

    const methods = getMethods(info);
    assert(methods == [requestMethod.name()], methodName);

    return info;
}

// RequestMappingHandlerMapping is built from AOT rows: it has no BuilderConfiguration, afterPropertiesSet,
// embedded value resolver or path prefixes.
version (FlintHandlerMappingConfiguration)
{
    import flint.mock.web : MockHttpServletRequest;
    import flint.web.method : HandlerTypePredicate;
    import flint.web.bind.annotation : RestController;

    @("RequestMappingHandlerMappingTests.builderConfiguration")
    unittest
    {
        auto mapping = createMapping()(null, new StaticBeanFactory);

        auto config = mapping.getBuilderConfiguration();
        assert(config !is null);

        mapping.afterPropertiesSet();
        assert(mapping.getBuilderConfiguration() !is null);
        assert(mapping.getBuilderConfiguration() !is config);
    }

    @("RequestMappingHandlerMappingTests.resolveEmbeddedValuesInPatterns")
    unittest
    {
        foreach (named; pathPatternsArguments())
        {
            auto mapping = named.create(null, new StaticBeanFactory);
            mapping.setEmbeddedValueResolver(value => "/${pattern}/bar" == value ? "/foo/bar" : value);

            string[] patterns = ["/foo", "/${pattern}/bar"];
            const result = mapping.resolveEmbeddedValuesInPatterns(patterns);

            assert(result == ["/foo", "/foo/bar"], named.name);
        }
    }

    @("RequestMappingHandlerMappingTests.pathPrefix")
    unittest
    {
        foreach (named; pathPatternsArguments())
        {
            auto beanFactory = new StaticBeanFactory;
            beanFactory.addBean("controller", new UserController);
            auto mapping = named.create(requestMappingsOf!UserController("controller"), beanFactory);
            mapping.setEmbeddedValueResolver(value => "/${prefix}" == value ? "/api" : value);
            mapping.setPathPrefixes([
                "/${prefix}": HandlerTypePredicate.forAnnotation(typeNameOf!RestController)
            ]);
            mapping.afterPropertiesSet();

            auto info = mapping.getHandlerMethods()[0];

            assert(info !is null, named.name);
            assert(getPatternValues(info) == ["/api/user/{id}"], named.name);
        }
    }

    // gh-23907
    @("RequestMappingHandlerMappingTests.pathPrefixPreservesPathMatchingSettings")
    unittest
    {
        foreach (named; pathPatternsArguments())
        {
            auto beanFactory = new StaticBeanFactory;
            beanFactory.addBean("controller", new ComposedAnnotationController);
            AotHandlerMapping[] rows;
            foreach (row; requestMappingsOf!ComposedAnnotationController("controller"))
                if (row.method.name == "get")
                    rows ~= row;
            auto mapping = named.create(rows, beanFactory);
            mapping.setPathPrefixes(["/api": HandlerTypePredicate.forAnyHandlerType()]);
            mapping.afterPropertiesSet();

            auto info = mapping.getHandlerMethods()[0];

            assert(info !is null, named.name);
            assert(info.getActivePatternsCondition() !is null, named.name);

            auto request = new MockHttpServletRequest("GET", "/api/get");
            assert(info.getActivePatternsCondition().getMatchingCondition(request) !is null, named.name);

            request = new MockHttpServletRequest("GET", "/api/get.pdf");
            assert(info.getActivePatternsCondition().getMatchingCondition(request) is null, named.name);
        }
    }

    @RestController
    @RequestMapping("/user")
    private class UserController
    {
        @GetMapping("/{id}")
        Object getUser()
        {
            return null;
        }
    }
}

// flint.web has no API versioning (ApiVersionStrategy, @RequestMapping(version) conditions), nor @HttpExchange.
version (FlintApiVersioning)
{
    import flint.mock.web : MockHttpServletRequest;
    import flint.web.accept : DefaultApiVersionStrategy, HeaderApiVersionResolver,
        InvalidApiVersionException, SemanticApiVersionParser;
    import flint.web.bind.annotation : RestController;
    import flint.web.method : HandlerMethod;
    import flint.web.service.annotation : GetExchange, HttpExchange;
    import std.exception : assertThrown;

    private MockHttpServletRequest initRequestForVersionTest(C)(NamedMapping named,
            out RequestMappingHandlerMapping mapping, string version_)
    {
        auto beanFactory = new StaticBeanFactory;
        beanFactory.addBean("controller", new C);
        mapping = named.create(requestMappingsOf!C("controller"), beanFactory);

        auto versionStrategy = new DefaultApiVersionStrategy([
            new HeaderApiVersionResolver("API-Version")
        ], new SemanticApiVersionParser(), true, null, true, null, null);
        mapping.setApiVersionStrategy(versionStrategy);
        mapping.afterPropertiesSet();

        auto request = new MockHttpServletRequest("GET", "/foo");
        request.addHeader("API-Version", version_);
        return request;
    }

    @("RequestMappingHandlerMappingTests.version")
    unittest
    {
        foreach (named; pathPatternsArguments())
        {
            RequestMappingHandlerMapping mapping;
            auto request = initRequestForVersionTest!VersionController(named, mapping, "1.1");
            auto handlerMethod = cast(HandlerMethod) mapping.getHandler(request).getHandler();
            assert(handlerMethod.getMethodName() == "foo1_1", named.name);
        }
    }

    @("RequestMappingHandlerMappingTests.versionInvalid")
    unittest
    {
        foreach (named; pathPatternsArguments())
        {
            RequestMappingHandlerMapping mapping;
            auto request = initRequestForVersionTest!VersionController(named, mapping, "99");
            assertThrown!InvalidApiVersionException(mapping.getHandler(request), named.name);
        }
    }

    @("RequestMappingHandlerMappingTests.versionWithHttpExchange")
    unittest
    {
        foreach (named; pathPatternsArguments())
        {
            RequestMappingHandlerMapping mapping;
            auto request = initRequestForVersionTest!VersionHttpExchangeController(named, mapping, "1.1");
            auto handlerMethod = cast(HandlerMethod) mapping.getHandler(request).getHandler();
            assert(handlerMethod.getMethodName() == "foo1_1", named.name);
        }
    }

    @("RequestMappingHandlerMappingTests.versionInvalidWithHttpExchange")
    unittest
    {
        foreach (named; pathPatternsArguments())
        {
            RequestMappingHandlerMapping mapping;
            auto request = initRequestForVersionTest!VersionHttpExchangeController(named, mapping, "99");
            assertThrown!InvalidApiVersionException(mapping.getHandler(request), named.name);
        }
    }

    @RestController
    @RequestMapping("/foo")
    private class VersionController
    {
        @GetMapping
        string foo()
        {
            return "foo";
        }

        @GetMapping(version_ : "1.1")
        string foo1_1()
        {
            return "foo1_1";
        }
    }

    @RestController
    @HttpExchange("/foo")
    private class VersionHttpExchangeController
    {
        @GetExchange
        string foo()
        {
            return "foo";
        }

        @GetExchange(version_ : "1.1")
        string foo1_1()
        {
            return "foo1_1";
        }
    }
}

@("RequestMappingHandlerMappingTests.resolveRequestMappingViaComposedAnnotation")
unittest
{
    foreach (named; pathPatternsArguments())
    {
        auto info = assertComposedAnnotationMapping(named.create, "postJson", "/postJson", RequestMethod.POST);

        const consumableMediaTypes = info.getConsumableMediaTypes();
        const producibleMediaTypes = info.getProducibleMediaTypes();

        assert(consumableMediaTypes.length == 1, named.name);
        assert(consumableMediaTypes[0].toString() == MediaType.APPLICATION_JSON_VALUE, named.name);
        assert(producibleMediaTypes.length == 1, named.name);
        assert(producibleMediaTypes[0].toString() == MediaType.APPLICATION_JSON_VALUE, named.name);
    }
}

// SPR-14988
@("RequestMappingHandlerMappingTests.postMappingOverridesConsumesFromTypeLevelAnnotation")
unittest
{
    auto requestMappingInfo = assertComposedAnnotationMapping(RequestMethod.POST);

    assert(requestMappingInfo.getConsumableMediaTypes() == [MediaType.APPLICATION_XML]);
}

// RequestMappingInfo has no ConsumesRequestCondition, so no isBodyRequired from @RequestBody(required = false),
// and @RequestBody on an interface method is not inherited by D implementations.
version (FlintConsumesBodyRequired)
{
    import flint.mock.web : MockHttpServletRequest;
    import flint.web.bind.annotation : RestController;

    // gh-22010
    @("RequestMappingHandlerMappingTests.consumesWithOptionalRequestBody")
    unittest
    {
        foreach (named; pathPatternsArguments())
        {
            auto beanFactory = new StaticBeanFactory;
            beanFactory.addBean("testController", new ComposedAnnotationController);
            auto mapping = named.create(requestMappingsOf!ComposedAnnotationController("testController"), beanFactory);
            RequestMappingInfo result;
            foreach (info; mapping.getHandlerMethods())
                if (getPatternValues(info) == ["/post"])
                {
                    result = info;
                    break;
                }
            assert(result !is null, "No /post");

            assert(!result.getConsumesCondition().isBodyRequired(), named.name);
        }
    }

    // gh-35086
    // Class `==` (AssertJ's `isEqualTo`) goes through Object.opEquals, which is @system.
    @("RequestMappingHandlerMappingTests.requestBodyAnnotationFromInterfaceIsRespected")
    @system unittest
    {
        const path = "/controller/postMapping";
        const mediaType = MediaType.APPLICATION_JSON;

        auto beanFactory = new StaticBeanFactory;
        beanFactory.addBean("controller", new InterfaceControllerImpl);
        auto rows = requestMappingsOf!InterfaceControllerImpl("controller");
        auto mapping = createMapping()(null, beanFactory);

        auto info = mapping.getMappingForMethod(rows[0]);
        assert(info !is null);

        // Original ConsumesCondition
        auto consumesCondition = info.getConsumesCondition();
        assert(consumesCondition !is null);
        assert(consumesCondition.isBodyRequired());
        assert(consumesCondition.getConsumableMediaTypes() == [mediaType]);

        mapping.registerHandlerMethod(new InterfaceControllerImpl, rows[0], info);

        // Updated ConsumesCondition
        consumesCondition = info.getConsumesCondition();
        assert(consumesCondition !is null);
        assert(!consumesCondition.isBodyRequired());
        assert(consumesCondition.getConsumableMediaTypes() == [mediaType]);

        auto request = new MockHttpServletRequest("POST", path);
        request.setContentType(mediaType.toString());

        auto matchingInfo = info.getMatchingCondition(request);
        // Since the request has no body AND the required flag is false, the
        // ConsumesCondition in the matching condition in an EMPTY_CONDITION.
        // In other words, the "consumes" expressions are removed.
        assert(matchingInfo == new RequestMappingInfo([path], ["POST"]));
    }

    // gh-35086
    // Class `==` (AssertJ's `isEqualTo`) goes through Object.opEquals, which is @system.
    @("RequestMappingHandlerMappingTests.requestBodyAnnotationFromImplementationOverridesInterface")
    @system unittest
    {
        const path = "/controller/postMapping";
        const mediaType = MediaType.APPLICATION_JSON;

        auto beanFactory = new StaticBeanFactory;
        beanFactory.addBean("controller", new InterfaceControllerImplOverridesRequestBody);
        auto rows = requestMappingsOf!InterfaceControllerImplOverridesRequestBody("controller");
        auto mapping = createMapping()(null, beanFactory);

        auto info = mapping.getMappingForMethod(rows[0]);
        assert(info !is null);

        // Original ConsumesCondition
        auto consumesCondition = info.getConsumesCondition();
        assert(consumesCondition !is null);
        assert(consumesCondition.isBodyRequired());
        assert(consumesCondition.getConsumableMediaTypes() == [mediaType]);

        mapping.registerHandlerMethod(new InterfaceControllerImplOverridesRequestBody, rows[0], info);

        // Updated ConsumesCondition
        consumesCondition = info.getConsumesCondition();
        assert(consumesCondition !is null);
        assert(consumesCondition.isBodyRequired());
        assert(consumesCondition.getConsumableMediaTypes() == [mediaType]);

        auto request = new MockHttpServletRequest("POST", path);
        request.setContentType(mediaType.toString());

        auto matchingInfo = info.getMatchingCondition(request);
        assert(matchingInfo == new RequestMappingInfo([path], ["POST"], null, null, [
            mediaType.toString()
        ]));
    }

    @RestController
    @RequestMapping(path : ["/controller"], consumes:
            ["application/json"])
    private interface InterfaceController
    {
        @PostMapping("/postMapping")
        void post(@RequestBody(false) Foo foo);
    }

    private class InterfaceControllerImpl : InterfaceController
    {
        override void post(Foo foo)
        {
        }
    }

    private class InterfaceControllerImplOverridesRequestBody : InterfaceController
    {
        override void post(@RequestBody(true) Foo foo)
        {
        }
    }
}

@("RequestMappingHandlerMappingTests.getMapping")
unittest
{
    assertComposedAnnotationMapping(RequestMethod.GET);
}

@("RequestMappingHandlerMappingTests.postMapping")
unittest
{
    assertComposedAnnotationMapping(RequestMethod.POST);
}

@("RequestMappingHandlerMappingTests.putMapping")
unittest
{
    assertComposedAnnotationMapping(RequestMethod.PUT);
}

@("RequestMappingHandlerMappingTests.deleteMapping")
unittest
{
    assertComposedAnnotationMapping(RequestMethod.DELETE);
}

@("RequestMappingHandlerMappingTests.patchMapping")
unittest
{
    assertComposedAnnotationMapping(RequestMethod.PATCH);
}

// flint.web has no @HttpExchange (flint.web.service.annotation), so the mapping reads no HttpExchange metadata.
version (FlintHttpExchange)
{
    import flint.java.lang : IllegalStateException;
    import flint.mock.web : MockHttpServletRequest;
    import flint.web.bind.annotation : RestController;
    import flint.web.service.annotation : HttpExchange, PostExchange, PutExchange;
    import std.algorithm.searching : canFind;

    /// `assertThatIllegalStateException().isThrownBy(...).withMessageContainingAll(...)`.
    private void assertIllegalStateContainingAll(C)(string methodName, string[] fragments...)
    {
        string message;
        try
            getMappingForMethod!C(createMapping(), methodName);
        catch (IllegalStateException ex)
            message = ex.msg;
        assert(message !is null, "IllegalStateException expected");
        foreach (fragment; fragments)
            assert(message.canFind(fragment), message);
    }

    // gh-32049
    @("RequestMappingHandlerMappingTests.httpExchangeWithMultipleAnnotationsAtClassLevel")
    unittest
    {
        assertIllegalStateContainingAll!MultipleClassLevelAnnotationsHttpExchangeController("post",
                "Multiple @HttpExchange annotations found on "
                ~ typeNameOf!MultipleClassLevelAnnotationsHttpExchangeController, "HttpExchange", "ExtraHttpExchange");
    }

    // gh-32049
    @("RequestMappingHandlerMappingTests.httpExchangeWithMultipleAnnotationsAtMethodLevel")
    unittest
    {
        assertIllegalStateContainingAll!MultipleMethodLevelAnnotationsHttpExchangeController("post",
                "Multiple @HttpExchange annotations found on "
                ~ typeNameOf!MultipleMethodLevelAnnotationsHttpExchangeController ~ ".post",
                "PostExchange", "PutExchange");
    }

    // gh-32065
    @("RequestMappingHandlerMappingTests.httpExchangeWithMixedAnnotationsAtClassLevel")
    unittest
    {
        assertIllegalStateContainingAll!MixedClassLevelAnnotationsController("post",
                typeNameOf!MixedClassLevelAnnotationsController,
                "is annotated with @RequestMapping and @HttpExchange annotations, but only one is allowed:",
                "RequestMapping", "HttpExchange");
    }

    // gh-32065
    @("RequestMappingHandlerMappingTests.httpExchangeWithMixedAnnotationsAtMethodLevel")
    unittest
    {
        assertIllegalStateContainingAll!MixedMethodLevelAnnotationsController("post",
                typeNameOf!MixedMethodLevelAnnotationsController ~ ".post",
                "is annotated with @RequestMapping and @HttpExchange annotations, but only one is allowed:",
                "PostMapping", "PostExchange");
    }

    // gh-32065
    @("RequestMappingHandlerMappingTests.httpExchangeAnnotationsOverriddenAtClassLevel")
    unittest
    {
        auto info = getMappingForMethod!ClassLevelOverriddenHttpExchangeAnnotationsController(createMapping(), "post");

        assert(info !is null);
        assert(info.getActivePatternsCondition() !is null);

        auto request = new MockHttpServletRequest("POST", "/service/postExchange");
        assert(info.getActivePatternsCondition().getMatchingCondition(request) is null);

        request = new MockHttpServletRequest("POST", "/controller/postExchange");
        assert(info.getActivePatternsCondition().getMatchingCondition(request) !is null);
    }

    // gh-32065
    @("RequestMappingHandlerMappingTests.httpExchangeAnnotationsOverriddenAtMethodLevel")
    unittest
    {
        auto info = getMappingForMethod!MethodLevelOverriddenHttpExchangeAnnotationsController(createMapping(), "post");

        assert(info !is null);
        assert(info.getActivePatternsCondition() !is null);

        auto request = new MockHttpServletRequest("POST", "/service/postExchange");
        assert(info.getActivePatternsCondition().getMatchingCondition(request) is null);

        request = new MockHttpServletRequest("POST", "/controller/postMapping");
        assert(info.getActivePatternsCondition().getMatchingCondition(request) !is null);
    }

    @("RequestMappingHandlerMappingTests.httpExchangeWithDefaultValues")
    unittest
    {
        auto mappingInfo = getMappingForMethod!HttpExchangeController(createMapping(), "defaultValuesExchange");

        assert(getPatternValues(mappingInfo) == ["/exchange"]);

        assert(mappingInfo.getMethods().length == 0);
        assert(mappingInfo.getParamsCondition().getExpressions().length == 0);
        assert(mappingInfo.getHeadersCondition().getExpressions().length == 0);
        assert(mappingInfo.getConsumesCondition().getExpressions().length == 0);
        assert(mappingInfo.getProducesCondition().getExpressions().length == 0);
    }

    @("RequestMappingHandlerMappingTests.httpExchangeWithCustomValues")
    unittest
    {
        auto mappingInfo = getMappingForMethod!HttpExchangeController(createMapping(), "customValuesExchange");

        assert(getPatternValues(mappingInfo) == ["/exchange/custom"]);

        assert(getMethods(mappingInfo) == [RequestMethod.POST.name()]);
        assert(mappingInfo.getParamsCondition().getExpressions().length == 0);
        assert(mappingInfo.getHeadersCondition().getExpressions().length == 0);

        assert(mappingInfo.getConsumableMediaTypes() == [MediaType.APPLICATION_JSON]);

        assert(mappingInfo.getProducibleMediaTypes() == [
            MediaType.valueOf("text/plain;charset=UTF-8")
        ]);
    }

    @("RequestMappingHandlerMappingTests.httpExchangeWithCustomHeaders")
    unittest
    {
        auto mappingInfo = getMappingForMethod!HttpExchangeController(createMapping(), "customHeadersExchange");

        assert(getPatternValues(mappingInfo) == ["/exchange/headers"]);

        assert(getMethods(mappingInfo) == [RequestMethod.GET.name()]);
        assert(mappingInfo.getParamsCondition().getExpressions().length == 0);

        string[] headers;
        foreach (expression; mappingInfo.getHeadersCondition().getExpressions())
            headers ~= expression.toString();
        assert(headers == ["h1=hv1", "!h2"]);
    }

    @RestController
    @HttpExchange("/exchange")
    private class HttpExchangeController
    {
        @HttpExchange
        void defaultValuesExchange()
        {
        }

        @PostExchange(url : "/custom", contentType:
                "application/json", accept:
                "text/plain;charset=UTF-8")
        void customValuesExchange()
        {
        }

        @HttpExchange(method : "GET", url:
                "/headers", headers:
                ["h1=hv1", "!h2", "Accept=application/ignored"])
        string customHeadersExchange()
        {
            return "info";
        }
    }

    @HttpExchange("/exchange")
    @ExtraHttpExchange
    private class MultipleClassLevelAnnotationsHttpExchangeController
    {
        @PostExchange("/post")
        void post()
        {
        }
    }

    private class MultipleMethodLevelAnnotationsHttpExchangeController
    {
        @PostExchange("/post")
        @PutExchange("/post")
        void post()
        {
        }
    }

    @Controller
    @RequestMapping("/api")
    @HttpExchange("/api")
    private class MixedClassLevelAnnotationsController
    {
        @PostExchange("/post")
        void post()
        {
        }
    }

    @Controller
    @RequestMapping("/api")
    private class MixedMethodLevelAnnotationsController
    {
        @PostMapping("/post")
        @PostExchange("/post")
        void post()
        {
        }
    }

    @HttpExchange("/service")
    private interface Service
    {
        @PostExchange("/postExchange")
        void post();
    }

    @Controller
    @RequestMapping("/controller")
    private class ClassLevelOverriddenHttpExchangeAnnotationsController : Service
    {
        override void post()
        {
        }
    }

    @Controller
    @RequestMapping("/controller")
    private class MethodLevelOverriddenHttpExchangeAnnotationsController : Service
    {
        @PostMapping("/postMapping")
        override void post()
        {
        }
    }

    @HttpExchange
    private struct ExtraHttpExchange
    {
    }
}

// D has no CGLIB proxy classes, and requestMappingsOf (Flint AOT) reads public methods only, so there is no
// private-method or package-private-method check.
version (FlintCglibProxy)
{
    import flint.aop.framework : createProxyClass;
    import flint.java.lang : IllegalStateException;
    import std.format : format;

    /// `assertThatIllegalStateException().isThrownBy(...).withMessage(...)`.
    private void assertIllegalStateMessage(scope void delegate() @safe action, string expected)
    {
        string message;
        try
            action();
        catch (IllegalStateException ex)
            message = ex.msg;
        assert(message == expected, message);
    }

    // gh-35352
    @("RequestMappingHandlerMappingTests.privateMethodOnCglibProxyShouldThrowException")
    unittest
    {
        auto mapping = createMapping();

        const methodName = "privateMethod";
        const proxyClass = createProxyClass!PrivateMethodController();

        assertIllegalStateMessage(() { mapping.getMappingForMethod(methodName, proxyClass); },
                format("Private method [%s] on CGLIB proxy class [%s] cannot be used as a request "
                    ~ "handler method, because private methods cannot be overridden. "
                    ~ "Change the method to non-private visibility, or use interface-based JDK " ~ "proxying instead.",
                    methodName, proxyClass.getName()));
    }

    // gh-35352
    @("RequestMappingHandlerMappingTests.protectedMethodOnCglibProxyShouldNotThrowException")
    unittest
    {
        auto mapping = createMapping();

        const proxyClass = createProxyClass!ProtectedMethodController();

        auto info = mapping.getMappingForMethod("protectedMethod", proxyClass);

        assert(getPatternValues(info) == ["/protected"]);
    }

    // gh-35352
    @("RequestMappingHandlerMappingTests.differentPackagePackagePrivateMethodOnCglibProxyShouldThrowException")
    unittest
    {
        import flint.web.testfixture.method : PackagePrivateMethodController;

        auto mapping = createMapping();

        const declaringClass = typeNameOf!PackagePrivateMethodController;
        const methodName = "packagePrivateMethod";
        const proxyClass = createProxyClass!LocalPackagePrivateMethodControllerSubclass();

        assertIllegalStateMessage(() { mapping.getMappingForMethod(methodName, proxyClass); },
                format("Package-private method [%s] declared in class [%s] cannot be advised by "
                    ~ "CGLIB-proxied handler class [%s], because it is effectively private. Either "
                    ~ "make the method public or protected, or use interface-based JDK proxying instead.",
                    methodName, declaringClass, proxyClass.getName()));
    }

    @Controller
    private class PrivateMethodController
    {
        @RequestMapping("/private")
        private void privateMethod()
        {
        }
    }

    @Controller
    private class ProtectedMethodController
    {
        @RequestMapping("/protected")
        protected void protectedMethod()
        {
        }
    }

    private class LocalPackagePrivateMethodControllerSubclass : PackagePrivateMethodController
    {
    }
}

// gh-31962: The presence of multiple @RequestMappings is intentional.
@Controller
@RequestMapping(consumes : [jsonValue])
@ExtraRequestMapping
private class ComposedAnnotationController
{
    @RequestMapping
    void handle()
    {
    }

    @PostJson("/postJson")
    void postJson()
    {
    }

    @GetMapping("/get")
    void get()
    {
    }

    @PostMapping(path : ["/post"], consumes:
            [MediaType.APPLICATION_XML_VALUE])
    void post(@RequestBody(false) Foo foo)
    {
    }

    // gh-31962: The presence of multiple @RequestMappings is intentional.
    @PatchMapping("/put")
    @RequestMapping(path : ["/put"], method:
            [RequestMethod.PUT])  // local @RequestMapping overrides meta-annotations
    @PostMapping("/put")
    void put()
    {
    }

    @DeleteMapping("/delete")
    void delete_()
    {
    }

    @PatchMapping("/patch")
    void patch()
    {
    }
}

private enum jsonValue = MediaType.APPLICATION_JSON_VALUE;

@RequestMapping
private struct ExtraRequestMapping
{
}

@RequestMapping(method : [RequestMethod.POST], produces:
        [MediaType.APPLICATION_JSON_VALUE],
    consumes:
        [MediaType.APPLICATION_JSON_VALUE])
private struct PostJson
{
    @AliasFor(annotation : ClassRef(typeNameOf!RequestMapping))
    string[] value;

    static PostJson opCall(string value) pure nothrow
    {
        PostJson result;
        result.value = [value];
        return result;
    }
}

private class Foo
{
}
