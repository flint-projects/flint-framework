/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/annotation/
ModelAndViewMethodReturnValueHandlerTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the `@BeforeEach`
fields become a `Fixture` that `setup` returns. `new MethodParameter(method, -1)` for the test class's own
methods is the return-type `MethodParameter` Flint AOT describes for them (`returnParam`). Model values are `Any`,
and `new ModelAndView(view, name, value)` is `new ModelAndView(view).addObject(name, value)`. The test lives with
flint.mock.web in flint:framework-test. Cases that need unported features or behave differently are gated by
version.
+/
module flint.web.model_and_view_method_return_value_handler_tests;

// flint.web first: importing flint.web.method.support before it trips a forward-reference error on
// LinkedHashMap!(string, Any) in this compiler.
import flint.web;
import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;
import flint.engine.aot.name : typeNameOf;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.context.request : ServletWebRequest;
import flint.web.method.support : ModelAndViewContainer;
import flint.web.servlet : ModelAndView;
import flint.web.servlet.mvc.method.annotation : ModelAndViewMethodReturnValueHandler;

@safe:

private struct Fixture
{
    ModelAndViewMethodReturnValueHandler handler;
    ModelAndViewContainer mavContainer;
    ServletWebRequest webRequest;
    MethodParameter returnParamModelAndView;
}

private Fixture setup()
{
    Fixture f;
    f.handler = new ModelAndViewMethodReturnValueHandler();
    f.mavContainer = new ModelAndViewContainer();
    f.webRequest = new ServletWebRequest(new MockHttpServletRequest(), new MockHttpServletResponse());
    f.returnParamModelAndView = getReturnValueParam(ReturnValue.modelAndView);
    return f;
}

// FragmentsRendering and SmartView are not ported.
version (FlintWebFragmentsRendering)
{
    import flint.java.util : Collection, List;
    import flint.web.servlet : SmartView;
    import flint.web.servlet.view : FragmentsRendering;

    @("ModelAndViewMethodReturnValueHandlerTests.supportsReturnType")
    unittest
    {
        auto f = setup();
        assert(f.handler.supportsReturnType(f.returnParamModelAndView));
        assert(f.handler.supportsReturnType(getReturnValueParam(ReturnValue.fragmentsRendering)));
        assert(f.handler.supportsReturnType(getReturnValueParam(ReturnValue.fragmentsCollection)));

        assert(!f.handler.supportsReturnType(getReturnValueParam(ReturnValue.viewName)));
    }
}

// Behaviour: ModelAndViewContainer.getView() returns only a View object; Spring's returns the view name too.
version (FlintModelAndViewContainerViewNameAsView)
{
    @("ModelAndViewMethodReturnValueHandlerTests.handleViewReference")
    unittest
    {
        auto f = setup();
        auto mav = new ModelAndView("viewName").addObject("attrName", Any.of("attrValue"));
        f.handler.handleReturnValue(Any.of(mav), f.returnParamModelAndView, f.mavContainer, f.webRequest);

        assert(Any.of(f.mavContainer.getView()) == Any.of("viewName"));
        assert(f.mavContainer.getModel().get("attrName") == Any.of("attrValue"));
    }
}

// RedirectView is not ported.
version (FlintWebRedirectView)
{
    import flint.web.servlet.view : RedirectView;

    @("ModelAndViewMethodReturnValueHandlerTests.handleViewInstance")
    unittest
    {
        auto f = setup();
        auto mav = new ModelAndView(new RedirectView()).addObject("attrName", Any.of("attrValue"));
        f.handler.handleReturnValue(Any.of(mav), f.returnParamModelAndView, f.mavContainer, f.webRequest);

        assert(typeid(f.mavContainer.getView()) is typeid(RedirectView));
        assert(f.mavContainer.getModel().get("attrName") == Any.of("attrValue"));
    }
}

version (FlintWebFragmentsRendering)
{
    @("ModelAndViewMethodReturnValueHandlerTests.handleFragmentsRendering")
    unittest
    {
        auto f = setup();
        auto rendering = FragmentsRendering.fragment("viewName").build();

        f.handler.handleReturnValue(Any.of(rendering), f.returnParamModelAndView, f.mavContainer, f.webRequest);
        assert(cast(SmartView) f.mavContainer.getView() !is null);
    }

    @("ModelAndViewMethodReturnValueHandlerTests.handleFragmentsCollection")
    unittest
    {
        auto f = setup();
        Collection!ModelAndView fragments = List!ModelAndView.of(new ModelAndView("viewName"));

        f.handler.handleReturnValue(Any.of(fragments), f.returnParamModelAndView, f.mavContainer, f.webRequest);
        assert(cast(SmartView) f.mavContainer.getView() !is null);
    }
}

@("ModelAndViewMethodReturnValueHandlerTests.handleNull")
unittest
{
    auto f = setup();
    f.handler.handleReturnValue(Any.init, f.returnParamModelAndView, f.mavContainer, f.webRequest);

    assert(f.mavContainer.isRequestHandled());
}

// ModelAndViewContainer has no redirect model (setRedirectModel) and RedirectAttributesModelMap is not ported.
version (FlintModelAndViewContainerRedirectModel)
{
    import flint.ui : ModelMap;
    import flint.web.servlet.mvc.support : RedirectAttributesModelMap;
    import flint.web.servlet.view : RedirectView;

    @("ModelAndViewMethodReturnValueHandlerTests.handleRedirectAttributesWithViewReference")
    unittest
    {
        auto f = setup();
        auto redirectAttributes = new RedirectAttributesModelMap();
        f.mavContainer.setRedirectModel(redirectAttributes);

        auto mav = new ModelAndView(new RedirectView()).addObject("attrName", Any.of("attrValue"));
        f.handler.handleReturnValue(Any.of(mav), f.returnParamModelAndView, f.mavContainer, f.webRequest);

        assert(typeid(f.mavContainer.getView()) is typeid(RedirectView));
        assert(f.mavContainer.getModel().get("attrName") == Any.of("attrValue"));
        assert(f.mavContainer.getModel() is redirectAttributes,
                "RedirectAttributes should be used if controller redirects");
    }

    @("ModelAndViewMethodReturnValueHandlerTests.handleRedirectAttributesWithViewName")
    unittest
    {
        auto f = setup();
        auto redirectAttributes = new RedirectAttributesModelMap();
        f.mavContainer.setRedirectModel(redirectAttributes);

        auto mav = new ModelAndView("redirect:viewName").addObject("attrName", Any.of("attrValue"));
        f.handler.handleReturnValue(Any.of(mav), f.returnParamModelAndView, f.mavContainer, f.webRequest);

        ModelMap model = f.mavContainer.getModel();
        assert(f.mavContainer.getViewName() == "redirect:viewName");
        assert(model.get("attrName") == Any.of("attrValue"));
        assert(model is redirectAttributes);
    }
}

// The handler has no setRedirectPatterns (the case also needs FlintModelAndViewContainerRedirectModel).
version (FlintWebRedirectPatterns)
{
    @("ModelAndViewMethodReturnValueHandlerTests.handleRedirectAttributesWithCustomPrefix")
    unittest
    {
        auto f = setup();
        auto redirectAttributes = new RedirectAttributesModelMap();
        f.mavContainer.setRedirectModel(redirectAttributes);

        auto mav = new ModelAndView("myRedirect:viewName").addObject("attrName", Any.of("attrValue"));
        f.handler.setRedirectPatterns("myRedirect:*");
        f.handler.handleReturnValue(Any.of(mav), f.returnParamModelAndView, f.mavContainer, f.webRequest);

        ModelMap model = f.mavContainer.getModel();
        assert(f.mavContainer.getViewName() == "myRedirect:viewName");
        assert(model.get("attrName") == Any.of("attrValue"));
        assert(model is redirectAttributes);
    }
}

version (FlintModelAndViewContainerRedirectModel)
{
    @("ModelAndViewMethodReturnValueHandlerTests.handleRedirectAttributesWithoutRedirect")
    unittest
    {
        auto f = setup();
        auto redirectAttributes = new RedirectAttributesModelMap();
        f.mavContainer.setRedirectModel(redirectAttributes);

        auto mav = new ModelAndView();
        f.handler.handleReturnValue(Any.of(mav), f.returnParamModelAndView, f.mavContainer, f.webRequest);

        ModelMap model = f.mavContainer.getModel();
        assert(f.mavContainer.getView() is null);
        assert(f.mavContainer.getModel().isEmpty());
        assert(model !is redirectAttributes, "RedirectAttributes should not be used if controller doesn't redirect");
    }
}

version (FlintWebRedirectView)
{
    // SPR-14045
    @("ModelAndViewMethodReturnValueHandlerTests.handleRedirectWithIgnoreDefaultModel")
    unittest
    {
        auto f = setup();
        auto redirectView = new RedirectView();
        auto mav = new ModelAndView(redirectView).addObject("name", Any.of("value"));
        f.handler.handleReturnValue(Any.of(mav), f.returnParamModelAndView, f.mavContainer, f.webRequest);

        auto model = f.mavContainer.getModel();
        assert(f.mavContainer.getView() is redirectView);
        assert(model.size() == 1);
        assert(model.get("name") == Any.of("value"));
    }
}

/// The test class's methods whose return types Spring's `getReturnValueParam` describes.
private enum ReturnValue
{
    modelAndView, /// `ModelAndView modelAndView()`
    viewName, /// `String viewName()`
    fragmentsRendering, /// `FragmentsRendering fragmentsRendering()`
    fragmentsCollection, /// `Collection<ModelAndView> fragmentsCollection()`
}

// FragmentsRendering is not ported: its return type names the type Flint AOT would write for it.
private immutable string[ReturnValue.max + 1] returnTypes = [
    typeNameOf!ModelAndView, typeNameOf!string, "flint.web.servlet.view.FragmentsRendering",
    "flint.java.util.Collection!(" ~ typeNameOf!ModelAndView ~ ")"
];

/// `new MethodParameter(getClass().getDeclaredMethod(methodName), -1)`.
private MethodParameter getReturnValueParam(ReturnValue method)
{
    import std.conv : to;

    ArgumentSpec returnSpec;
    returnSpec.kind = ArgumentKind.byType;
    returnSpec.type = returnTypes[method];
    return new MethodParameter(returnSpec, -1, "ModelAndViewMethodReturnValueHandlerTests." ~ method.to!string);
}
