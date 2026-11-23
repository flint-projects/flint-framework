/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/handler/SimpleUrlHandlerMappingTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; each
`@HandlerMappingsTest` is one unittest that loops over the named mappings of `handlerMappings()`, whose
`AntPathMatcher` variant waits behind the `PathMatcher` gate. flint.web.servlet's `SimpleUrlHandlerMapping`
registers handler objects rather than bean names resolved from an application context, so the
`StaticApplicationContext` singleton `mainController` is a plain object registered under the URL map's pattern
and `setApplicationContext` has nothing left to do. It has no `UrlPathHelper` and matches the still-encoded
lookup path, which is what `setUrlDecode(false)` asks for. `PathPatternsTestUtils.initRequest` only builds the
request, as the port resolves the lookup path from the request itself. The test lives with flint.mock.web's
`MockHttpServletRequest` in flint:framework-test. Cases that need unported features, or where the port gives a
different result, wait behind version gates.
+/
module flint.web.simple_url_handler_mapping_tests;

import flint.engine.aot.any : Any;
import flint.mock.web : MockHttpServletRequest;
import flint.web.servlet : HandlerExecutionChain, HandlerMapping;
import flint.web.servlet.resource : SimpleUrlHandlerMapping;

@safe:

private alias PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE = HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE;
private alias BEST_MATCHING_HANDLER_ATTRIBUTE = HandlerMapping.BEST_MATCHING_HANDLER_ATTRIBUTE;
private alias BEST_MATCHING_PATTERN_ATTRIBUTE = HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE;

private struct NamedMapping
{
    string name;
    SimpleUrlHandlerMapping handlerMapping;
    /// `handlerMapping.getPatternParser() != null`.
    bool usePathPatterns;
}

/// `handlerMappings()`: the `@HandlerMappingsTest` arguments.
private NamedMapping[] handlerMappings()
{
    auto defaultConfig = new SimpleUrlHandlerMapping();
    NamedMapping[] result = [NamedMapping("with PathPattern", defaultConfig, true)];
    // flint.web.servlet's SimpleUrlHandlerMapping matches parsed PathPatterns only (no setPatternParser(null)).
    version (FlintPathMatcher)
    {
        auto antPatternConfig = new SimpleUrlHandlerMapping();
        antPatternConfig.setPatternParser(null);
        result ~= NamedMapping("with AntPathMatcher", antPatternConfig, false);
    }
    return result;
}

/// `PathPatternsTestUtils.initRequest`: Spring also caches the parsed `RequestPath` or the lookup path.
private MockHttpServletRequest initRequest(string method, string contextPath, string path, bool /+ parsedPatterns +/ )
{
    if (contextPath is null)
        return new MockHttpServletRequest(method, path);
    auto request = new MockHttpServletRequest(method, contextPath ~ (path.length != 0 && path[0] == '/' ? "" : "/")
            ~ path);
    request.setContextPath(contextPath);
    return request;
}

/// ditto
private MockHttpServletRequest initRequest(string method, string path, bool usePathPatterns)
{
    return initRequest(method, null, path, usePathPatterns);
}

private HandlerExecutionChain getHandler(HandlerMapping mapping, MockHttpServletRequest request)
{
    auto chain = mapping.getHandler(request);
    assert(chain !is null, "No handler found for request: " ~ request.getRequestURI());
    foreach (interceptor; chain.getInterceptorList())
        interceptor.preHandle(request, null, chain.getHandler());
    return chain;
}

// flint.web.servlet's SimpleUrlHandlerMapping has no URL map of bean names resolved from an application context.
version (FlintSimpleUrlHandlerMappingBeanNames)
{
    import flint.beans.factory : NoSuchBeanDefinitionException;
    import flint.context.support : StaticApplicationContext;

    @("SimpleUrlHandlerMappingTests.shouldFailWhenHandlerBeanNotFound")
    unittest
    {
        auto handlerMapping = new SimpleUrlHandlerMapping(["/welcome.html": "mainController"]);
        bool thrown;
        try
            handlerMapping.setApplicationContext(new StaticApplicationContext());
        catch (NoSuchBeanDefinitionException)
            thrown = true;
        assert(thrown);
    }
}

@("SimpleUrlHandlerMappingTests.newlineInRequestShouldMatch")
unittest
{
    auto controller = new Object();
    // Spring: new SimpleUrlHandlerMapping(Collections.singletonMap("/*/baz", controller)) with a UrlPathHelper
    // that does not decode, then setApplicationContext(new StaticApplicationContext()).
    auto mapping = new SimpleUrlHandlerMapping();
    mapping.registerHandler("/*/baz", controller);

    auto request = new MockHttpServletRequest("GET", "/foo%0a%0dbar/baz");

    auto hec = mapping.getHandler(request);
    assert(hec !is null);
    assert(hec.getHandler() is controller);
}

// Behaviour: the port's SimpleUrlHandlerMapping does not expose BEST_MATCHING_HANDLER_ATTRIBUTE.
version (FlintUrlHandlerMappingBestMatchingHandler)
{
    @("SimpleUrlHandlerMappingTests.resolveFromMap")
    unittest
    {
        foreach (named; handlerMappings())
        {
            auto handlerMapping = named.handlerMapping;
            auto mainController = new Object();
            handlerMapping.registerHandler("/welcome.html", mainController);

            const usePathPatterns = named.usePathPatterns;
            auto request = initRequest("GET", "/welcome.html", usePathPatterns);
            auto chain = getHandler(handlerMapping, request);

            assert(chain.getHandler() is mainController, named.name);
            assert(request.getAttribute(PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE) == Any.of("/welcome.html"), named.name);
            assert(request.getAttribute(BEST_MATCHING_HANDLER_ATTRIBUTE).asObject() is mainController, named.name);
        }
    }
}

// Segments that mix literal text with `*` (Spring's RegexPathElement) are not ported; the parser rejects them.
// (flint.web.servlet's HandlerMapping also has no BEST_MATCHING_PATH_PATTERN_ATTRIBUTE.)
version (FlintPathPatternPartialSegments)
{
    @("SimpleUrlHandlerMappingTests.resolveBestMatchingPathPatternAttribute")
    unittest
    {
        import flint.web.util.pattern : PathPattern;

        foreach (named; handlerMappings())
        {
            auto handlerMapping = named.handlerMapping;
            auto mainController = new Object();
            handlerMapping.registerHandler("/welcome*", mainController);

            const usePathPatterns = named.usePathPatterns;
            auto request = initRequest("GET", "/welcome.x", usePathPatterns);
            auto chain = getHandler(handlerMapping, request);

            assert(chain.getHandler() is mainController, named.name);
            assert(request.getAttribute(BEST_MATCHING_PATTERN_ATTRIBUTE) == Any.of("/welcome*"), named.name);
            if (usePathPatterns)
            {
                auto pattern = cast(PathPattern) request.getAttribute(
                        HandlerMapping.BEST_MATCHING_PATH_PATTERN_ATTRIBUTE).asObject();
                assert(pattern !is null, named.name);
                assert(pattern.getPatternString() == "/welcome*", named.name);
            }
            else
                assert(request.getAttribute(HandlerMapping.BEST_MATCHING_PATH_PATTERN_ATTRIBUTE).isNull(), named.name);
        }
    }

    @("SimpleUrlHandlerMappingTests.resolvePatternFromMap")
    unittest
    {
        foreach (named; handlerMappings())
        {
            auto handlerMapping = named.handlerMapping;
            auto mainController = new Object();
            handlerMapping.registerHandler("/welcome*", mainController);

            const usePathPatterns = named.usePathPatterns;
            auto request = initRequest("GET", "/welcome.x", usePathPatterns);
            auto chain = getHandler(handlerMapping, request);

            assert(chain.getHandler() is mainController, named.name);
            assert(request.getAttribute(PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE) == Any.of("welcome.x"), named.name);
            assert(request.getAttribute(BEST_MATCHING_HANDLER_ATTRIBUTE).asObject() is mainController, named.name);
        }
    }
}

// Behaviour: the port's SimpleUrlHandlerMapping exposes the whole lookup path, path parameters included, as
// PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE (Spring: "/welcome.x"); it also sets no BEST_MATCHING_HANDLER_ATTRIBUTE.
version (FlintUrlHandlerMappingPathWithinMapping)
{
    @("SimpleUrlHandlerMappingTests.resolvePathWithParamFromMap")
    unittest
    {
        foreach (named; handlerMappings())
        {
            auto handlerMapping = named.handlerMapping;
            auto mainController = new Object();
            handlerMapping.registerHandler("/welcome.x", mainController);

            const usePathPatterns = named.usePathPatterns;
            auto request = initRequest("GET", "/welcome.x;jsessionid=123", usePathPatterns);
            auto chain = getHandler(handlerMapping, request);

            assert(chain.getHandler() is mainController, named.name);
            assert(request.getAttribute(PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE) == Any.of("/welcome.x"), named.name);
            assert(request.getAttribute(BEST_MATCHING_HANDLER_ATTRIBUTE).asObject() is mainController, named.name);
        }
    }
}

version (FlintUrlHandlerMappingBestMatchingHandler)
{
    @("SimpleUrlHandlerMappingTests.resolvePathWithContextFromMap")
    unittest
    {
        foreach (named; handlerMappings())
        {
            auto handlerMapping = named.handlerMapping;
            auto mainController = new Object();
            handlerMapping.registerHandler("/welcome.x", mainController);

            const usePathPatterns = named.usePathPatterns;
            auto request = initRequest("GET", "/app", "/welcome.x", usePathPatterns);
            auto chain = getHandler(handlerMapping, request);

            assert(chain.getHandler() is mainController, named.name);
            assert(request.getAttribute(PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE) == Any.of("/welcome.x"), named.name);
            assert(request.getAttribute(BEST_MATCHING_HANDLER_ATTRIBUTE).asObject() is mainController, named.name);
        }
    }
}

// Behaviour: the port's lookup path ignores the include request URI (jakarta.servlet.include.request_uri), so an
// included request finds no handler.
version (FlintLookupPathIncludeRequestUri)
{
    @("SimpleUrlHandlerMappingTests.resolvePathWithIncludeFromMap")
    unittest
    {
        import flint.jakarta.servlet : RequestDispatcher;

        foreach (named; handlerMappings())
        {
            auto handlerMapping = named.handlerMapping;
            auto mainController = new Object();
            handlerMapping.registerHandler("/welcome.html", mainController);

            const usePathPatterns = named.usePathPatterns;
            auto request = initRequest("GET", "/original.html", usePathPatterns);
            // WebUtils.INCLUDE_REQUEST_URI_ATTRIBUTE
            request.setAttribute(RequestDispatcher.INCLUDE_REQUEST_URI, Any.of("/welcome.html"));
            auto chain = getHandler(handlerMapping, request);

            assert(chain.getHandler() is mainController, named.name);
            assert(request.getAttribute(PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE) == Any.of("/welcome.html"), named.name);
            assert(request.getAttribute(BEST_MATCHING_HANDLER_ATTRIBUTE).asObject() is mainController, named.name);
        }
    }
}

// flint.web.servlet's handler mappings have no default handler (setDefaultHandler).
version (FlintHandlerMappingDefaultHandler)
{
    @("SimpleUrlHandlerMappingTests.resolveDefaultPathFromMap")
    unittest
    {
        foreach (named; handlerMappings())
        {
            auto handlerMapping = named.handlerMapping;
            auto mainController = new Object();
            handlerMapping.setDefaultHandler(mainController);

            const usePathPatterns = named.usePathPatterns;
            auto request = initRequest("GET", "/", usePathPatterns);
            auto chain = getHandler(handlerMapping, request);

            assert(chain.getHandler() is mainController, named.name);
            assert(request.getAttribute(PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE) == Any.of("/"), named.name);
            assert(request.getAttribute(BEST_MATCHING_HANDLER_ATTRIBUTE).asObject() is mainController, named.name);
        }
    }
}

// flint.web.servlet has no ParameterizableViewController or RedirectView.
version (FlintParameterizableViewController)
{
    @("SimpleUrlHandlerMappingTests.resolveParameterizedControllerFromMap")
    unittest
    {
        import flint.http : HttpStatus;
        import flint.web.servlet.mvc : ParameterizableViewController;
        import flint.web.servlet.view : RedirectView;

        foreach (named; handlerMappings())
        {
            auto handlerMapping = named.handlerMapping;
            auto viewController = new ParameterizableViewController();
            viewController.setView(new RedirectView("/after/{variable}"));
            viewController.setStatusCode(HttpStatus.PERMANENT_REDIRECT);
            handlerMapping.registerHandler("/before/{variable}", viewController);

            const usePathPatterns = named.usePathPatterns;
            auto request = initRequest("GET", "/before/test", usePathPatterns);
            auto chain = getHandler(handlerMapping, request);

            assert(chain.getHandler() is viewController, named.name);
            auto variables = request.getAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE).get!(string[2][]);
            bool found;
            foreach (variable; variables)
                found = found || (variable[0] == "variable" && variable[1] == "test");
            assert(found, named.name);
            assert(request.getAttribute(BEST_MATCHING_HANDLER_ATTRIBUTE).asObject() is viewController, named.name);
        }
    }
}
