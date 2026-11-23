/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/annotation/
ViewNameMethodReturnValueHandlerTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the `@BeforeEach`
fields become a `Fixture` that `setup` returns. `new MethodParameter(method, -1)` for the test class's `String
viewName()` is the return-type `MethodParameter` Flint AOT describes for it, and return values are `Any`. The test
lives with flint.mock.web in flint:framework-test. Cases that need unported features wait behind version gates.
+/
module flint.web.view_name_method_return_value_handler_tests;

// flint.web first: importing flint.web.method.support before it trips a forward-reference error on
// LinkedHashMap!(string, Any) in this compiler.
import flint.web;
import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;
import flint.engine.aot.name : typeNameOf;
import flint.mock.web : MockHttpServletRequest;
import flint.web.context.request : ServletWebRequest;
import flint.web.method.support : ModelAndViewContainer;
import flint.web.servlet.mvc.method.annotation : ViewNameMethodReturnValueHandler;

@safe:

private struct Fixture
{
    ViewNameMethodReturnValueHandler handler;
    ModelAndViewContainer mavContainer;
    ServletWebRequest webRequest;
    MethodParameter param;
}

private Fixture setup()
{
    Fixture f;
    f.handler = new ViewNameMethodReturnValueHandler();
    f.mavContainer = new ModelAndViewContainer();
    f.webRequest = new ServletWebRequest(new MockHttpServletRequest());

    // String viewName()
    ArgumentSpec returnSpec;
    returnSpec.kind = ArgumentKind.byType;
    returnSpec.type = typeNameOf!string;
    f.param = new MethodParameter(returnSpec, -1, "ViewNameMethodReturnValueHandlerTests.viewName");
    return f;
}

@("ViewNameMethodReturnValueHandlerTests.supportsReturnType")
unittest
{
    auto f = setup();
    assert(f.handler.supportsReturnType(f.param));
}

@("ViewNameMethodReturnValueHandlerTests.returnViewName")
unittest
{
    auto f = setup();
    f.handler.handleReturnValue(Any.of("testView"), f.param, f.mavContainer, f.webRequest);
    assert(f.mavContainer.getViewName() == "testView");
}

// ModelAndViewContainer has no redirect model (setRedirectModel) and RedirectAttributesModelMap is not ported.
version (FlintModelAndViewContainerRedirectModel)
{
    import flint.ui : ModelMap;
    import flint.web.servlet.mvc.support : RedirectAttributesModelMap;

    @("ViewNameMethodReturnValueHandlerTests.returnViewNameRedirect")
    unittest
    {
        auto f = setup();
        ModelMap redirectModel = new RedirectAttributesModelMap();
        f.mavContainer.setRedirectModel(redirectModel);
        f.handler.handleReturnValue(Any.of("redirect:testView"), f.param, f.mavContainer, f.webRequest);
        assert(f.mavContainer.getViewName() == "redirect:testView");
        assert(f.mavContainer.getModel() is redirectModel);
    }
}

// The handler has no setRedirectPatterns (the cases also need FlintModelAndViewContainerRedirectModel).
version (FlintWebRedirectPatterns)
{
    @("ViewNameMethodReturnValueHandlerTests.returnViewCustomRedirect")
    unittest
    {
        auto f = setup();
        ModelMap redirectModel = new RedirectAttributesModelMap();
        f.mavContainer.setRedirectModel(redirectModel);
        f.handler.setRedirectPatterns("myRedirect:*");
        f.handler.handleReturnValue(Any.of("myRedirect:testView"), f.param, f.mavContainer, f.webRequest);
        assert(f.mavContainer.getViewName() == "myRedirect:testView");
        assert(f.mavContainer.getModel() is redirectModel);
    }

    @("ViewNameMethodReturnValueHandlerTests.returnViewRedirectWithCustomRedirectPattern")
    unittest
    {
        auto f = setup();
        ModelMap redirectModel = new RedirectAttributesModelMap();
        f.mavContainer.setRedirectModel(redirectModel);
        f.handler.setRedirectPatterns("myRedirect:*");
        f.handler.handleReturnValue(Any.of("redirect:testView"), f.param, f.mavContainer, f.webRequest);
        assert(f.mavContainer.getViewName() == "redirect:testView");
        assert(f.mavContainer.getModel() is redirectModel);
    }
}
