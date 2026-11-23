/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/method/annotation/RequestHeaderMethodArgumentResolverTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setup` returns. The `SynthesizingMethodParameter`s that reflection finds on `params` are
built from the `ArgumentSpec`s Flint AOT writes for them. The resolver takes no bean factory (no `${}` or SpEL
resolution), so `RequestContextHolder` is not set or reset. `ConfigurableWebBindingInitializer` with
`DefaultFormattingConversionService` is `DefaultDataBinderFactory`. Java's `String[]` header values are added one
by one. The test lives with flint.mock.web in flint:framework-test, which depends on flint:web. Cases that need
unported classes or behave differently are gated by version.
+/
module flint.web.request_header_method_argument_resolver_tests;

import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : MergedAnnotation;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;
import flint.engine.aot.name : typeNameOf;
import flint.java.time : Instant;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.bind : MissingRequestHeaderException, ServletRequestBindingException;
import flint.web.bind.annotation : RequestHeader, ValueConstants;
import flint.web.bind.support : DefaultDataBinderFactory;
import flint.web.context.request : NativeWebRequest, ServletWebRequest;
import flint.web.method.annotation : MethodArgumentTypeMismatchException, RequestHeaderMethodArgumentResolver;

@safe:

private struct Fixture
{
    RequestHeaderMethodArgumentResolver resolver;
    MethodParameter paramNamedDefaultValueStringHeader;
    MethodParameter paramNamedValueStringArray;
    MethodParameter paramSystemProperty;
    MethodParameter paramContextPath;
    MethodParameter paramResolvedNameWithExpression;
    MethodParameter paramResolvedNameWithPlaceholder;
    MethodParameter paramNamedValueMap;
    MethodParameter paramDate;
    MethodParameter paramInstant;
    MethodParameter paramUuid;
    MethodParameter paramUuidOptional;
    MethodParameter paramUuidPlaceholder;
    MockHttpServletRequest servletRequest;
    NativeWebRequest webRequest;
}

// Date and UUID are not ported: their parameters name the types Flint AOT would write for them.
private enum date = "flint.java.util.Date";
private enum uuid = "flint.java.util.UUID";

private Fixture setup()
{
    Fixture f;
    f.resolver = new RequestHeaderMethodArgumentResolver();

    f.paramNamedDefaultValueStringHeader = param(0, "param1", "string", requestHeader("name", true, "bar"));
    f.paramNamedValueStringArray = param(1, "param2", "string[]", requestHeader("name"));
    f.paramSystemProperty = param(2, "param3", "string", requestHeader("name", true,
            "#{systemProperties.systemProperty}"));
    f.paramContextPath = param(3, "param4", "string", requestHeader("name", true, "#{request.contextPath}"));
    f.paramResolvedNameWithExpression = param(4, "param5", "string",
            requestHeader("#{systemProperties.systemProperty}"));
    f.paramResolvedNameWithPlaceholder = param(5, "param6", "string", requestHeader("${systemProperty}"));
    f.paramNamedValueMap = param(6, "unsupported", "string[string]", requestHeader("name"));
    f.paramDate = param(7, "dateParam", date, requestHeader("name"));
    f.paramInstant = param(8, "instantParam", typeNameOf!Instant, requestHeader("name"));
    f.paramUuid = param(9, "uuid", uuid, requestHeader("name"));
    f.paramUuidOptional = param(10, "uuidOptional", uuid, requestHeader("name", false));
    f.paramUuidPlaceholder = param(11, "uuidPlaceholder", uuid, requestHeader("${systemProperty}"));

    f.servletRequest = new MockHttpServletRequest();
    f.webRequest = new ServletWebRequest(f.servletRequest, new MockHttpServletResponse());
    return f;
}

/// `@RequestHeader` as Flint AOT merges it: `name` and its alias `value` agree.
private RequestHeader requestHeader(string name, bool required = true, string defaultValue = ValueConstants
        .DEFAULT_NONE)
{
    RequestHeader annotation;
    annotation.name = name;
    annotation.value = name;
    annotation.required = required;
    annotation.defaultValue = defaultValue;
    return annotation;
}

/// Parameter `index` of `params`, from the `ArgumentSpec` Flint AOT writes for a `@RequestHeader` parameter.
private MethodParameter param(int index, string parameterName, string type, RequestHeader annotation)
{
    ArgumentSpec spec;
    spec.kind = ArgumentKind.requestHeader;
    spec.name = annotation.name.length != 0 ? annotation.name : parameterName;
    spec.type = type;
    spec.required = annotation.required;
    spec.defaultValue = annotation.defaultValue;
    spec.annotations = [MergedAnnotation(typeNameOf!RequestHeader, Any.of(annotation), 0)];
    return new MethodParameter(spec, index, "RequestHeaderMethodArgumentResolverTests.params");
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

// The port supports `@RequestHeader Map` parameters, which Spring leaves to RequestHeaderMapMethodArgumentResolver.
version (FlintWebRequestHeaderMap)
{
    @("RequestHeaderMethodArgumentResolverTests.supportsParameter")
    unittest
    {
        auto f = setup();
        assert(f.resolver.supportsParameter(f.paramNamedDefaultValueStringHeader), "String parameter not supported");
        assert(f.resolver.supportsParameter(f.paramNamedValueStringArray), "String array parameter not supported");
        assert(!f.resolver.supportsParameter(f.paramNamedValueMap), "non-@RequestParam parameter supported");
    }
}

@("RequestHeaderMethodArgumentResolverTests.resolveStringArgument")
unittest
{
    auto f = setup();
    const expected = "foo";
    f.servletRequest.addHeader("name", expected);

    const result = f.resolver.resolveArgument(f.paramNamedDefaultValueStringHeader, null, f.webRequest, null);

    assert(result.get!string == expected);
}

@("RequestHeaderMethodArgumentResolverTests.resolveStringArrayArgument")
unittest
{
    auto f = setup();
    string[] expected = ["foo", "bar"];
    foreach (value; expected)
        f.servletRequest.addHeader("name", value);

    const result = f.resolver.resolveArgument(f.paramNamedValueStringArray, null, f.webRequest, null);
    assert(result.get!(string[]) == expected);
}

@("RequestHeaderMethodArgumentResolverTests.resolveDefaultValue")
unittest
{
    auto f = setup();
    const result = f.resolver.resolveArgument(f.paramNamedDefaultValueStringHeader, null, f.webRequest, null);

    assert(result.get!string == "bar");
}

// The resolver takes no bean factory, so `#{}` SpEL expressions are not evaluated (and Java's System properties
// are not ported).
version (FlintWebSpelExpressions)
{
    @("RequestHeaderMethodArgumentResolverTests.resolveDefaultValueFromSystemProperty")
    unittest
    {
        import flint.java.lang : System;

        auto f = setup();
        System.setProperty("systemProperty", "bar");
        scope (exit)
            System.clearProperty("systemProperty");
        const result = f.resolver.resolveArgument(f.paramSystemProperty, null, f.webRequest, null);

        assert(result.get!string == "bar");
    }

    @("RequestHeaderMethodArgumentResolverTests.resolveNameFromSystemPropertyThroughExpression")
    unittest
    {
        import flint.java.lang : System;

        auto f = setup();
        const expected = "foo";
        f.servletRequest.addHeader("bar", expected);

        System.setProperty("systemProperty", "bar");
        scope (exit)
            System.clearProperty("systemProperty");
        const result = f.resolver.resolveArgument(f.paramResolvedNameWithExpression, null, f.webRequest, null);

        assert(result.get!string == expected);
    }
}

// The resolver takes no bean factory, so `${}` placeholders in names are not resolved (and Java's System
// properties are not ported).
version (FlintWebSystemPropertyPlaceholders)
{
    @("RequestHeaderMethodArgumentResolverTests.resolveNameFromSystemPropertyThroughPlaceholder")
    unittest
    {
        import flint.java.lang : System;

        auto f = setup();
        const expected = "foo";
        f.servletRequest.addHeader("bar", expected);

        System.setProperty("systemProperty", "bar");
        scope (exit)
            System.clearProperty("systemProperty");
        const result = f.resolver.resolveArgument(f.paramResolvedNameWithPlaceholder, null, f.webRequest, null);

        assert(result.get!string == expected);
    }

    @("RequestHeaderMethodArgumentResolverTests.missingParameterFromSystemPropertyThroughPlaceholder")
    unittest
    {
        import flint.java.lang : System;

        auto f = setup();
        const expected = "bar";
        System.setProperty("systemProperty", expected);
        scope (exit)
            System.clearProperty("systemProperty");

        auto ex = thrown!MissingRequestHeaderException(() {
            f.resolver.resolveArgument(f.paramResolvedNameWithPlaceholder, null, f.webRequest, null);
        });
        assert(ex !is null);
        assert(ex.getHeaderName() == expected);
    }
}

// The resolver takes no bean factory, so `#{}` SpEL expressions are not evaluated.
version (FlintWebSpelExpressions)
{
    @("RequestHeaderMethodArgumentResolverTests.resolveDefaultValueFromRequest")
    unittest
    {
        auto f = setup();
        f.servletRequest.setContextPath("/bar");

        const result = f.resolver.resolveArgument(f.paramContextPath, null, f.webRequest, null);

        assert(result.get!string == "/bar");
    }
}

@("RequestHeaderMethodArgumentResolverTests.notFound")
unittest
{
    auto f = setup();
    assert(thrown!ServletRequestBindingException(() {
            f.resolver.resolveArgument(f.paramNamedValueStringArray, null, f.webRequest, null);
        }) !is null);
}

// The port's data binder factory has no Date, Instant or UUID conversion (DefaultFormattingConversionService's
// converters, which also turn blank values into null); Date and UUID are not ported.
version (FlintWebConversionService)
{
    @("RequestHeaderMethodArgumentResolverTests.dateConversion")
    unittest
    {
        import flint.java.util : Date;

        auto f = setup();
        const rfc1123val = "Thu, 21 Apr 2016 17:11:08 +0100";
        f.servletRequest.addHeader("name", rfc1123val);

        const result = f.resolver.resolveArgument(f.paramDate, null, f.webRequest, new DefaultDataBinderFactory());

        assert(result.get!Date == new Date(rfc1123val));
    }

    @("RequestHeaderMethodArgumentResolverTests.instantConversion")
    unittest
    {
        import flint.java.time.format : DateTimeFormatter;

        auto f = setup();
        const rfc1123val = "Thu, 21 Apr 2016 17:11:08 +0100";
        f.servletRequest.addHeader("name", rfc1123val);

        const result = f.resolver.resolveArgument(f.paramInstant, null, f.webRequest, new DefaultDataBinderFactory());

        assert(result.get!Instant == Instant.from(DateTimeFormatter.RFC_1123_DATE_TIME.parse(rfc1123val)));
    }

    @("RequestHeaderMethodArgumentResolverTests.uuidConversionWithValidValue")
    unittest
    {
        import flint.java.util : UUID;

        auto f = setup();
        const uuidValue = UUID.randomUUID();
        f.servletRequest.addHeader("name", uuidValue.toString());

        const result = f.resolver.resolveArgument(f.paramUuid, null, f.webRequest, new DefaultDataBinderFactory());

        assert(result.get!UUID == uuidValue);
    }
}

@("RequestHeaderMethodArgumentResolverTests.uuidConversionWithInvalidValue")
unittest
{
    auto f = setup();
    f.servletRequest.addHeader("name", "bogus-uuid");

    auto binderFactory = new DefaultDataBinderFactory();

    auto ex = thrown!MethodArgumentTypeMismatchException(() {
        f.resolver.resolveArgument(f.paramUuid, null, f.webRequest, binderFactory);
    });
    assert(ex !is null);
    assert(ex.getPropertyName() == "name");
}

// The port's data binder factory has no UUID conversion, so empty and blank values fail to convert instead of
// becoming null (DefaultFormattingConversionService's StringToUUIDConverter).
version (FlintWebConversionService)
{
    @("RequestHeaderMethodArgumentResolverTests.uuidConversionWithEmptyValue")
    unittest
    {
        uuidConversionWithEmptyOrBlankValue("");
    }

    @("RequestHeaderMethodArgumentResolverTests.uuidConversionWithBlankValue")
    unittest
    {
        uuidConversionWithEmptyOrBlankValue("     ");
    }

    private void uuidConversionWithEmptyOrBlankValue(string uuidValue)
    {
        auto f = setup();
        f.servletRequest.addHeader("name", uuidValue);

        auto binderFactory = new DefaultDataBinderFactory();

        assert(thrown!MissingRequestHeaderException(() {
                f.resolver.resolveArgument(f.paramUuid, null, f.webRequest, binderFactory);
            }) !is null);
    }

    @("RequestHeaderMethodArgumentResolverTests.uuidConversionWithEmptyValueOptional")
    unittest
    {
        uuidConversionWithEmptyOrBlankValueOptional("");
    }

    @("RequestHeaderMethodArgumentResolverTests.uuidConversionWithBlankValueOptional")
    unittest
    {
        uuidConversionWithEmptyOrBlankValueOptional("     ");
    }

    private void uuidConversionWithEmptyOrBlankValueOptional(string uuidValue)
    {
        auto f = setup();
        f.servletRequest.addHeader("name", uuidValue);

        const result = f.resolver.resolveArgument(f.paramUuidOptional, null, f.webRequest,
                new DefaultDataBinderFactory());

        assert(result.isNull());
    }
}

// The resolver takes no bean factory, so `${}` placeholders in names are not resolved (and Java's System
// properties are not ported).
version (FlintWebSystemPropertyPlaceholders)
{
    @("RequestHeaderMethodArgumentResolverTests.uuidPlaceholderConversionWithEmptyValue")
    unittest
    {
        import flint.java.lang : System;

        auto f = setup();
        const expected = "name";
        f.servletRequest.addHeader(expected, "");

        System.setProperty("systemProperty", expected);
        scope (exit)
            System.clearProperty("systemProperty");

        auto binderFactory = new DefaultDataBinderFactory();

        auto ex = thrown!MissingRequestHeaderException(() {
            f.resolver.resolveArgument(f.paramUuidPlaceholder, null, f.webRequest, binderFactory);
        });
        assert(ex !is null);
        assert(ex.getHeaderName() == expected);
    }
}
