/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/method/support/ModelAndViewContainerTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the `@BeforeEach`
field becomes the container that `setup` returns. Model values are `Any` (ADR-030 section 5). The test lives in
flint:framework-test with the flint.web.servlet infrastructure ports that use flint.mock.web. Cases that need the
redirect model scenario wait behind a version gate.
+/
module flint.web.model_and_view_container_tests;

// flint.web first: importing flint.web.method.support (directly or through flint.web.servlet.config.annotation)
// before it trips a forward-reference error on LinkedHashMap!(string, Any) in this compiler.
import flint.web;
import flint.engine.aot.any : Any;
import flint.web.method.support : ModelAndViewContainer;

@safe:

private ModelAndViewContainer setup()
{
    return new ModelAndViewContainer();
}

@("ModelAndViewContainerTests.getModel")
unittest
{
    auto mavContainer = setup();
    mavContainer.addAttribute("name", Any.of("value"));
    assert(mavContainer.getModel().size() == 1);
    assert(mavContainer.getModel().get("name") == Any.of("value"));
}

// flint.web.method.support's ModelAndViewContainer has no redirect model (setRedirectModel,
// setRedirectModelScenario) and flint.web no ModelMap.
version (FlintModelAndViewContainerRedirectModel)
{
    import flint.ui : ModelMap;

    @("ModelAndViewContainerTests.redirectScenarioWithRedirectModel")
    unittest
    {
        auto mavContainer = setup();
        mavContainer.addAttribute("name1", Any.of("value1"));
        mavContainer.setRedirectModel(new ModelMap("name2", Any.of("value2")));
        mavContainer.setRedirectModelScenario(true);

        assert(mavContainer.getModel().size() == 1);
        assert(mavContainer.getModel().get("name2") == Any.of("value2"));
    }

    @("ModelAndViewContainerTests.ignoreDefaultModel")
    unittest
    {
        auto mavContainer = setup();
        mavContainer.addAttribute("name", Any.of("value"));
        mavContainer.setRedirectModelScenario(true);

        assert(mavContainer.getModel().isEmpty());
    }

    @("ModelAndViewContainerTests.ignoreDefaultModelAndWithoutRedirectModel")
    unittest
    {
        // SPR-14045
        auto mavContainer = setup();
        mavContainer.setRedirectModelScenario(true);
        mavContainer.addAttribute("name", Any.of("value"));

        assert(mavContainer.getModel().size() == 1);
        assert(mavContainer.getModel().get("name") == Any.of("value"));
    }
}
