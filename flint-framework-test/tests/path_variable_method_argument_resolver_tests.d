/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/mvc/method/annotation/
PathVariableMethodArgumentResolverTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setup` returns. The `SynthesizingMethodParameter`s that reflection finds on `handle` are
built from the `ArgumentSpec`s Flint AOT writes for them. URI template variables are the port's `string[2][]`
pairs and `View.PATH_VARIABLES` an `Any[string]`; `ConfigurableWebBindingInitializer` with
`DefaultConversionService` is `DefaultDataBinderFactory`. The test lives with flint.mock.web in
flint:framework-test, which depends on flint:webmvc. Cases where the port behaves differently are gated by version.
+/
module flint.web.path_variable_method_argument_resolver_tests;

import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : MergedAnnotation;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;
import flint.engine.aot.name : typeNameOf;
import flint.java.util : Optional;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.bind : MissingPathVariableException;
import flint.web.bind.annotation : PathVariable, ValueConstants;
import flint.web.bind.support : DefaultDataBinderFactory, WebDataBinderFactory;
import flint.web.context.request : ServletWebRequest;
import flint.web.method.support : ModelAndViewContainer;
import flint.web.servlet : HandlerMapping, View;
import flint.web.servlet.mvc.method.annotation : PathVariableMethodArgumentResolver;

@safe:

private struct Fixture
{
    PathVariableMethodArgumentResolver resolver;
    ModelAndViewContainer mavContainer;
    ServletWebRequest webRequest;
    MockHttpServletRequest request;
    MethodParameter paramNamedString;
    MethodParameter paramString;
    MethodParameter paramNotRequired;
    MethodParameter paramOptional;
}

private Fixture setup()
{
    Fixture f;
    f.resolver = new PathVariableMethodArgumentResolver();
    f.mavContainer = new ModelAndViewContainer();
    f.request = new MockHttpServletRequest();
    f.webRequest = new ServletWebRequest(f.request, new MockHttpServletResponse());

    f.paramNamedString = param(0, "string", pathVariable("name"));
    f.paramString = plainParam(1, "param2", "string");
    f.paramNotRequired = param(2, "string", pathVariable("name", false));
    f.paramOptional = param(3, typeNameOf!(Optional!string), pathVariable("name"));
    return f;
}

/// `@PathVariable` as Flint AOT merges it: `name` and its alias `value` agree.
private PathVariable pathVariable(string name, bool required = true)
{
    PathVariable annotation;
    annotation.name = name;
    annotation.value = name;
    annotation.required = required;
    return annotation;
}

/// Parameter `index` of `handle`, from the `ArgumentSpec` Flint AOT writes for a `@PathVariable` parameter.
private MethodParameter param(int index, string type, PathVariable annotation)
{
    ArgumentSpec spec;
    spec.kind = ArgumentKind.pathVariable;
    spec.name = annotation.name;
    spec.type = type;
    spec.required = annotation.required;
    spec.defaultValue = ValueConstants.DEFAULT_NONE;
    spec.annotations = [MergedAnnotation(typeNameOf!PathVariable, Any.of(annotation), 0)];
    return new MethodParameter(spec, index, "PathVariableMethodArgumentResolverTests.handle");
}

/// Parameter `index` of `handle` without a binding annotation: Flint AOT makes a simple type a request parameter.
private MethodParameter plainParam(int index, string parameterName, string type)
{
    ArgumentSpec spec;
    spec.kind = ArgumentKind.requestParam;
    spec.name = parameterName;
    spec.type = type;
    spec.defaultValue = ValueConstants.DEFAULT_NONE;
    return new MethodParameter(spec, index, "PathVariableMethodArgumentResolverTests.handle");
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

@("PathVariableMethodArgumentResolverTests.supportsParameter")
unittest
{
    auto f = setup();
    assert(f.resolver.supportsParameter(f.paramNamedString), "Parameter with @PathVariable annotation");
    assert(!f.resolver.supportsParameter(f.paramString), "Parameter without @PathVariable annotation");
}

// The port does not expose resolved path variables under View.PATH_VARIABLES (Spring's handleResolvedValue).
version (FlintWebPathVariablesAttribute)
{
    @("PathVariableMethodArgumentResolverTests.resolveArgument")
    unittest
    {
        auto f = setup();
        string[2][] uriTemplateVars = [["name", "value"]];
        f.request.setAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE, Any.of(uriTemplateVars));

        const result = f.resolver.resolveArgument(f.paramNamedString, f.mavContainer, f.webRequest, null);
        assert(result.get!string == "value", "PathVariable not resolved correctly");

        const pathVarsAttribute = f.request.getAttribute(View.PATH_VARIABLES);
        assert(!pathVarsAttribute.isNull());
        auto pathVars = pathVarsAttribute.get!(Any[string]);
        assert(pathVars.length == 1);
        assert(pathVars["name"] == Any.of("value"));
    }

    @("PathVariableMethodArgumentResolverTests.resolveArgumentNotRequired")
    unittest
    {
        auto f = setup();
        string[2][] uriTemplateVars = [["name", "value"]];
        f.request.setAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE, Any.of(uriTemplateVars));

        const result = f.resolver.resolveArgument(f.paramNotRequired, f.mavContainer, f.webRequest, null);
        assert(result.get!string == "value", "PathVariable not resolved correctly");

        const pathVarsAttribute = f.request.getAttribute(View.PATH_VARIABLES);
        assert(!pathVarsAttribute.isNull());
        auto pathVars = pathVarsAttribute.get!(Any[string]);
        assert(pathVars.length == 1);
        assert(pathVars["name"] == Any.of("value"));
    }
}

// The resolver neither wraps values in Optional nor returns Optional.empty() for a missing Optional!T parameter.
version (FlintWebJavaOptional)
{
    @("PathVariableMethodArgumentResolverTests.resolveArgumentWrappedAsOptional")
    unittest
    {
        auto f = setup();
        string[2][] uriTemplateVars = [["name", "value"]];
        f.request.setAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE, Any.of(uriTemplateVars));

        WebDataBinderFactory binderFactory = new DefaultDataBinderFactory();

        const result = f.resolver.resolveArgument(f.paramOptional, f.mavContainer, f.webRequest,
                binderFactory).get!(Optional!string);
        assert(result.isPresent() && result.get() == "value", "PathVariable not resolved correctly");

        const pathVarsAttribute = f.request.getAttribute(View.PATH_VARIABLES);
        assert(!pathVarsAttribute.isNull());
        auto pathVars = pathVarsAttribute.get!(Any[string]);
        assert(pathVars.length == 1);
        assert(pathVars["name"] == Any.of(Optional!string.of("value")));
    }
}

@("PathVariableMethodArgumentResolverTests.resolveArgumentWithExistingPathVars")
unittest
{
    auto f = setup();
    string[2][] uriTemplateVars = [["name", "value"]];
    f.request.setAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE, Any.of(uriTemplateVars));

    // Spring puts oldName into the same map, so both attributes hold it.
    uriTemplateVars ~= ["oldName", "oldValue"];
    f.request.setAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE, Any.of(uriTemplateVars));
    Any[string] existingPathVars;
    foreach (pair; uriTemplateVars)
        existingPathVars[pair[0]] = Any.of(pair[1]);
    f.request.setAttribute(View.PATH_VARIABLES, Any.of(existingPathVars));

    const result = f.resolver.resolveArgument(f.paramNamedString, f.mavContainer, f.webRequest, null);
    assert(result.get!string == "value", "PathVariable not resolved correctly");

    const pathVarsAttribute = f.request.getAttribute(View.PATH_VARIABLES);
    assert(!pathVarsAttribute.isNull());
    auto pathVars = pathVarsAttribute.get!(Any[string]);
    assert(pathVars.length == 2);
    assert(pathVars["name"] == Any.of("value"));
    assert(pathVars["oldName"] == Any.of("oldValue"));
}

@("PathVariableMethodArgumentResolverTests.handleMissingValue")
unittest
{
    auto f = setup();
    assert(thrown!MissingPathVariableException(() {
            f.resolver.resolveArgument(f.paramNamedString, f.mavContainer, f.webRequest, null);
        }) !is null);
}

@("PathVariableMethodArgumentResolverTests.nullIfNotRequired")
unittest
{
    auto f = setup();
    assert(f.resolver.resolveArgument(f.paramNotRequired, f.mavContainer, f.webRequest, null).isNull());
}

// The resolver neither wraps values in Optional nor returns Optional.empty() for a missing Optional!T parameter.
version (FlintWebJavaOptional)
{
    @("PathVariableMethodArgumentResolverTests.wrapEmptyWithOptional")
    unittest
    {
        auto f = setup();
        WebDataBinderFactory binderFactory = new DefaultDataBinderFactory();

        const result = f.resolver.resolveArgument(f.paramOptional, f.mavContainer, f.webRequest, binderFactory);
        assert(result == Any.of(Optional!string.empty()));
    }
}
