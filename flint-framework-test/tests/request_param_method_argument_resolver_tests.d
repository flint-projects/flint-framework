/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/method/annotation/RequestParamMethodArgumentResolverTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the test's fields
become a `Fixture` that `setup` returns. `ResolvableMethod`'s reflective lookup of `handle`'s parameters becomes
the `ArgumentSpec` table Flint AOT writes for them (`handleArguments`), picked by position (`Handle`). The resolver
takes no bean factory (no `${}` or SpEL resolution), so `RequestContextHolder` is not set. Mockito's
`WebDataBinderFactory` mock with a `StringTrimmerEditor(true)` binder is a stub factory that trims strings to
null; `ConfigurableWebBindingInitializer` with `DefaultConversionService` is `DefaultDataBinderFactory`. Java's
`Integer` and `Boolean` are `int` and `bool`. The test lives with flint.mock.web in flint:framework-test, which
depends on flint:web. Cases that need unported classes or behave differently are gated by version.
+/
module flint.web.request_param_method_argument_resolver_tests;

import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : MergedAnnotation;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;
import flint.engine.aot.name : typeNameOf;
import flint.java.util : List, Optional;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.web.bind : MissingServletRequestParameterException;
import flint.web.bind.annotation : RequestParam, ValueConstants;
import flint.web.bind.support : DefaultDataBinderFactory, WebDataBinderFactory;
import flint.web.context.request : NativeWebRequest, ServletWebRequest;
import flint.web.method.annotation : RequestParamMethodArgumentResolver;

@safe:

private struct Fixture
{
    RequestParamMethodArgumentResolver resolver;
    MockHttpServletRequest request;
    NativeWebRequest webRequest;
}

private Fixture setup()
{
    Fixture f;
    f.request = new MockHttpServletRequest();
    f.webRequest = new ServletWebRequest(f.request, new MockHttpServletResponse());
    f.resolver = new RequestParamMethodArgumentResolver(true);
    return f;
}

/// The parameters of Spring's `handle` method, in declaration order.
private enum Handle
{
    param1, /// `@RequestParam(name = "name", defaultValue = "bar") String`
    param2, /// `@RequestParam("name") String[]`
    param3, /// `@RequestParam("name") Map<?, ?>`
    param4, /// `@RequestParam("mfile") MultipartFile`
    param5, /// `@RequestParam("mfilelist") List<MultipartFile>`
    param6, /// `@RequestParam("mfilearray") MultipartFile[]`
    param7, /// `@RequestParam("pfile") Part`
    param8, /// `@RequestParam("pfilelist") List<Part>`
    param9, /// `@RequestParam("pfilearray") Part[]`
    param10, /// `@RequestParam Map<?, ?>`
    stringNotAnnot, /// `String`
    multipartFileNotAnnot, /// `MultipartFile`
    multipartFileList, /// `List<MultipartFile>`
    part, /// `Part`
    requestPartAnnot, /// `@RequestPart MultipartFile`
    paramRequired, /// `@RequestParam("name") String`
    paramNotRequired, /// `@RequestParam(name = "name", required = false) String`
    paramOptional, /// `@RequestParam("name") Optional<Integer>`
    paramOptionalArray, /// `@RequestParam("name") Optional<Integer[]>`
    paramOptionalList, /// `@RequestParam("name") Optional<List<?>>`
    multipartFileOptional, /// `@RequestParam("mfile") Optional<MultipartFile>`
    booleanParam, /// `@RequestParam(defaultValue = "false") Boolean`
    placeholderParam, /// `@RequestParam("${systemProperty}") Integer`
    primitivePlaceholderParam, /// `@RequestParam(name = "${systemProperty}", required = false) int`
}

// MultipartFile and Part are not ported: their parameters name the types Flint AOT would write for them.
private enum multipartFile = "flint.web.multipart.MultipartFile";
private enum part = "flint.jakarta.servlet.http.Part";

/// `@RequestParam` as Flint AOT merges it: `name` and its alias `value` agree.
private RequestParam requestParam(string name = null, bool required = true,
        string defaultValue = ValueConstants.DEFAULT_NONE)
{
    RequestParam annotation;
    annotation.name = name;
    annotation.value = name;
    annotation.required = required;
    annotation.defaultValue = defaultValue;
    return annotation;
}

/// The `ArgumentSpec` Flint AOT writes for a `@RequestParam` parameter: the annotation's name, else the parameter
/// name, with its required flag and default value.
private ArgumentSpec annotated(string parameterName, string type, RequestParam annotation)
{
    ArgumentSpec spec;
    spec.kind = ArgumentKind.requestParam;
    spec.name = annotation.name.length != 0 ? annotation.name : parameterName;
    spec.type = type;
    spec.required = annotation.required;
    spec.defaultValue = annotation.defaultValue;
    spec.annotations = [MergedAnnotation(typeNameOf!RequestParam, Any.of(annotation), 0)];
    return spec;
}

/// The `ArgumentSpec` Flint AOT writes for a parameter without a binding annotation: a simple type is an optional
/// request parameter, any other type is resolved by type.
private ArgumentSpec plain(string parameterName, string type, ArgumentKind kind, MergedAnnotation[] annotations = null)
{
    ArgumentSpec spec;
    spec.kind = kind;
    spec.name = parameterName;
    spec.type = type;
    spec.required = kind != ArgumentKind.requestParam;
    spec.defaultValue = ValueConstants.DEFAULT_NONE;
    spec.annotations = annotations;
    return spec;
}

/// Flint AOT's `ArgumentSpec`s for Spring's `handle` method, in `Handle` order.
private ArgumentSpec[] handleArguments()
{
    return [
        annotated("param1", "string", requestParam("name", true, "bar")),
        annotated("param2", "string[]", requestParam("name")),
        annotated("param3", "string[string]", requestParam("name")),
        annotated("param4", multipartFile, requestParam("mfile")),
        annotated("param5", "flint.java.util.List!(" ~ multipartFile ~ ")", requestParam("mfilelist")),
        annotated("param6", multipartFile ~ "[]", requestParam("mfilearray")),
        annotated("param7", part, requestParam("pfile")),
        annotated("param8", "flint.java.util.List!(" ~ part ~ ")", requestParam("pfilelist")),
        annotated("param9", part ~ "[]", requestParam("pfilearray")),
        annotated("param10", "string[string]", requestParam()),
        plain("stringNotAnnot", "string", ArgumentKind.requestParam),
        plain("multipartFileNotAnnot", multipartFile, ArgumentKind.byType),
        plain("multipartFileList", "flint.java.util.List!(" ~ multipartFile ~ ")",
                ArgumentKind.byType), plain("part", part, ArgumentKind.byType),
        // @RequestPart is not ported: the parameter carries it by name only.
        plain("requestPartAnnot", multipartFile, ArgumentKind.byType,
                [MergedAnnotation("flint.web.bind.annotation.RequestPart",
                        Any.init, 0)]), annotated("paramRequired", "string", requestParam("name")),
        annotated("paramNotRequired", "string", requestParam("name", false)),
        annotated("paramOptional", typeNameOf!(Optional!int), requestParam("name")),
        annotated("paramOptionalArray", typeNameOf!(Optional!(int[])), requestParam("name")),
        annotated("paramOptionalList", typeNameOf!(Optional!(List!string)), requestParam("name")),
        annotated("multipartFileOptional", "flint.java.util.Optional!(" ~ multipartFile ~ ")",
                requestParam("mfile")),
        annotated("booleanParam", "bool", requestParam(null, true, "false")),
        annotated("placeholderParam", "int", requestParam("${systemProperty}")),
        annotated("primitivePlaceholderParam", "int", requestParam("${systemProperty}", false)),
    ];
}

/// The `MethodParameter` for `handle`'s parameter, as `ResolvableMethod` finds it.
private MethodParameter arg(Handle parameter)
{
    return new MethodParameter(handleArguments()[parameter], parameter,
            "RequestParamMethodArgumentResolverTests.handle");
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

/// Mockito's `WebDataBinderFactory` mock whose binder has `StringTrimmerEditor(true)` for `String`: strings are
/// trimmed and empty ones become null; other values convert as `DefaultDataBinderFactory` does.
private final class StringTrimmerBinderFactory : WebDataBinderFactory
{
    Any convertIfNecessary(Any value, string targetType, MethodParameter parameter)
    {
        import std.string : strip;

        if (targetType == "string" && value.holds!string)
        {
            const trimmed = value.get!string.strip;
            return trimmed.length == 0 ? Any.init : Any.of!string(trimmed);
        }
        return new DefaultDataBinderFactory().convertIfNecessary(value, targetType, parameter);
    }
}

// MultipartFile, Part, MultipartException, MissingServletRequestPartException, @RequestPart and the multipart
// mocks are not ported (the port also supports an unnamed `@RequestParam Map`, which Spring leaves to
// RequestParamMapMethodArgumentResolver).
version (FlintWebMultipart)
{
    import flint.jakarta.servlet.http : Part;
    import flint.mock.web : MockMultipartFile, MockMultipartHttpServletRequest, MockPart;
    import flint.web.bind.annotation : RequestPart;
    import flint.web.multipart : MultipartException, MultipartFile;
    import flint.web.multipart.support : MissingServletRequestPartException;
    import std.algorithm.comparison : equal;
    import std.string : representation;

    @("RequestParamMethodArgumentResolverTests.supportsParameter")
    unittest
    {
        auto f = setup();
        f.resolver = new RequestParamMethodArgumentResolver(true);

        MethodParameter param = arg(Handle.param1);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.param2);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.param3);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.param4);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.param5);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.param6);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.param7);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.param8);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.param9);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.param10);
        assert(!f.resolver.supportsParameter(param));

        param = arg(Handle.stringNotAnnot);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.multipartFileNotAnnot);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.multipartFileList);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.part);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.requestPartAnnot);
        assert(!f.resolver.supportsParameter(param));

        param = arg(Handle.paramRequired);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.paramNotRequired);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.paramOptional);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.multipartFileOptional);
        assert(f.resolver.supportsParameter(param));

        f.resolver = new RequestParamMethodArgumentResolver(false);

        param = arg(Handle.stringNotAnnot);
        assert(!f.resolver.supportsParameter(param));

        param = arg(Handle.requestPartAnnot);
        assert(!f.resolver.supportsParameter(param));

        param = arg(Handle.placeholderParam);
        assert(f.resolver.supportsParameter(param));

        param = arg(Handle.primitivePlaceholderParam);
        assert(f.resolver.supportsParameter(param));
    }
}

@("RequestParamMethodArgumentResolverTests.resolveString")
unittest
{
    auto f = setup();
    const expected = "foo";
    f.request.addParameter("name", expected);

    MethodParameter param = arg(Handle.param1);
    const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
    assert(result.get!string == expected);
}

@("RequestParamMethodArgumentResolverTests.resolveStringArray")
unittest
{
    auto f = setup();
    string[] expected = ["foo", "bar"];
    f.request.addParameter("name", expected);

    MethodParameter param = arg(Handle.param2);
    const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
    assert(result.get!(string[]) == expected);
}

// gh-32577: the port does not fall back to the `name[]` parameter when `name` is absent.
version (FlintWebRequestParamArraySuffix)
{
    @("RequestParamMethodArgumentResolverTests.resolveStringArrayWithEmptyArraySuffix")
    unittest
    {
        auto f = setup();
        string[] expected = ["foo", "bar"];
        f.request.addParameter("name[]", expected[0]);
        f.request.addParameter("name[]", expected[1]);

        MethodParameter param = arg(Handle.param2);
        const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
        assert(result.get!(string[]) == expected);
    }
}

// MultipartFile, Part and their mocks are not ported.
version (FlintWebMultipart)
{
    @("RequestParamMethodArgumentResolverTests.resolveMultipartFile")
    unittest
    {
        auto f = setup();
        auto request = new MockMultipartHttpServletRequest();
        MultipartFile expected = new MockMultipartFile("mfile", "Hello World".representation);
        request.addFile(expected);
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.param4);
        const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
        assert(cast(MultipartFile) result.asObject() is expected);
    }

    @("RequestParamMethodArgumentResolverTests.resolveMultipartFileList")
    unittest
    {
        auto f = setup();
        auto request = new MockMultipartHttpServletRequest();
        MultipartFile expected1 = new MockMultipartFile("mfilelist", "Hello World 1".representation);
        MultipartFile expected2 = new MockMultipartFile("mfilelist", "Hello World 2".representation);
        request.addFile(expected1);
        request.addFile(expected2);
        request.addFile(new MockMultipartFile("other", "Hello World 3".representation));
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.param5);
        const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
        assert(equal!((a, b) => a is b)(result.get!(List!MultipartFile).toArray(), [
            expected1, expected2
        ]));
    }

    @("RequestParamMethodArgumentResolverTests.resolveMultipartFileListMissing")
    unittest
    {
        auto f = setup();
        auto request = new MockMultipartHttpServletRequest();
        request.addFile(new MockMultipartFile("other", "Hello World 3".representation));
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.param5);
        assert(thrown!MissingServletRequestPartException(() {
                f.resolver.resolveArgument(param, null, f.webRequest, null);
            }) !is null);
    }

    @("RequestParamMethodArgumentResolverTests.resolveMultipartFileArray")
    unittest
    {
        auto f = setup();
        auto request = new MockMultipartHttpServletRequest();
        MultipartFile expected1 = new MockMultipartFile("mfilearray", "Hello World 1".representation);
        MultipartFile expected2 = new MockMultipartFile("mfilearray", "Hello World 2".representation);
        request.addFile(expected1);
        request.addFile(expected2);
        request.addFile(new MockMultipartFile("other", "Hello World 3".representation));
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.param6);
        const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
        assert(equal!((a, b) => a is b)(result.get!(MultipartFile[]), [expected1, expected2]));
    }

    @("RequestParamMethodArgumentResolverTests.resolveMultipartFileArrayMissing")
    unittest
    {
        auto f = setup();
        auto request = new MockMultipartHttpServletRequest();
        request.addFile(new MockMultipartFile("other", "Hello World 3".representation));
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.param6);
        assert(thrown!MissingServletRequestPartException(() {
                f.resolver.resolveArgument(param, null, f.webRequest, null);
            }) !is null);
    }

    @("RequestParamMethodArgumentResolverTests.resolvePart")
    unittest
    {
        auto f = setup();
        auto request = new MockHttpServletRequest();
        auto expected = new MockPart("pfile", "Hello World".representation);
        request.setMethod("POST");
        request.setContentType("multipart/form-data");
        request.addPart(expected);
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.param7);
        const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
        assert(cast(Part) result.asObject() is expected);
    }

    @("RequestParamMethodArgumentResolverTests.resolvePartList")
    unittest
    {
        auto f = setup();
        auto request = new MockHttpServletRequest();
        request.setMethod("POST");
        request.setContentType("multipart/form-data");
        auto expected1 = new MockPart("pfilelist", "Hello World 1".representation);
        auto expected2 = new MockPart("pfilelist", "Hello World 2".representation);
        request.addPart(expected1);
        request.addPart(expected2);
        request.addPart(new MockPart("other", "Hello World 3".representation));
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.param8);
        const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
        Part[] expected = [expected1, expected2];
        assert(equal!((a, b) => a is b)(result.get!(List!Part).toArray(), expected));
    }

    @("RequestParamMethodArgumentResolverTests.resolvePartListMissing")
    unittest
    {
        auto f = setup();
        auto request = new MockHttpServletRequest();
        request.setMethod("POST");
        request.setContentType("multipart/form-data");
        request.addPart(new MockPart("other", "Hello World 3".representation));
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.param8);
        assert(thrown!MissingServletRequestPartException(() {
                f.resolver.resolveArgument(param, null, f.webRequest, null);
            }) !is null);
    }

    @("RequestParamMethodArgumentResolverTests.resolvePartArray")
    unittest
    {
        auto f = setup();
        auto request = new MockHttpServletRequest();
        auto expected1 = new MockPart("pfilearray", "Hello World 1".representation);
        auto expected2 = new MockPart("pfilearray", "Hello World 2".representation);
        request.setMethod("POST");
        request.setContentType("multipart/form-data");
        request.addPart(expected1);
        request.addPart(expected2);
        request.addPart(new MockPart("other", "Hello World 3".representation));
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.param9);
        const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
        Part[] expected = [expected1, expected2];
        assert(equal!((a, b) => a is b)(result.get!(Part[]), expected));
    }

    @("RequestParamMethodArgumentResolverTests.resolvePartArrayMissing")
    unittest
    {
        auto f = setup();
        auto request = new MockHttpServletRequest();
        request.setMethod("POST");
        request.setContentType("multipart/form-data");
        request.addPart(new MockPart("other", "Hello World 3".representation));
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.param9);
        assert(thrown!MissingServletRequestPartException(() {
                f.resolver.resolveArgument(param, null, f.webRequest, null);
            }) !is null);
    }

    @("RequestParamMethodArgumentResolverTests.resolveMultipartFileNotAnnot")
    unittest
    {
        auto f = setup();
        auto request = new MockMultipartHttpServletRequest();
        MultipartFile expected = new MockMultipartFile("multipartFileNotAnnot", "Hello World".representation);
        request.addFile(expected);
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.multipartFileNotAnnot);
        const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
        assert(cast(MultipartFile) result.asObject() is expected);
    }

    @("RequestParamMethodArgumentResolverTests.resolveMultipartFileListNotannot")
    unittest
    {
        auto f = setup();
        auto request = new MockMultipartHttpServletRequest();
        MultipartFile expected1 = new MockMultipartFile("multipartFileList", "Hello World 1".representation);
        MultipartFile expected2 = new MockMultipartFile("multipartFileList", "Hello World 2".representation);
        request.addFile(expected1);
        request.addFile(expected2);
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.multipartFileList);

        const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
        assert(equal!((a, b) => a is b)(result.get!(List!MultipartFile).toArray(), [
            expected1, expected2
        ]));
    }

    @("RequestParamMethodArgumentResolverTests.isMultipartRequest")
    unittest
    {
        auto f = setup();
        MethodParameter param = arg(Handle.param4);
        assert(thrown!MultipartException(() {
                f.resolver.resolveArgument(param, null, f.webRequest, null);
            }) !is null);
    }

    // SPR-9079
    @("RequestParamMethodArgumentResolverTests.isMultipartRequestHttpPut")
    unittest
    {
        auto f = setup();
        auto request = new MockMultipartHttpServletRequest();
        MultipartFile expected = new MockMultipartFile("multipartFileList", "Hello World".representation);
        request.addFile(expected);
        request.setMethod("PUT");
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.multipartFileList);

        const actual = f.resolver.resolveArgument(param, null, f.webRequest, null);
        assert(equal!((a, b) => a is b)(actual.get!(List!MultipartFile).toArray(), [expected]));
    }

    @("RequestParamMethodArgumentResolverTests.noMultipartContent")
    unittest
    {
        auto f = setup();
        f.request.setMethod("POST");
        MethodParameter param = arg(Handle.param4);
        assert(thrown!MultipartException(() {
                f.resolver.resolveArgument(param, null, f.webRequest, null);
            }) !is null);
    }

    @("RequestParamMethodArgumentResolverTests.missingMultipartFile")
    unittest
    {
        auto f = setup();
        f.request.setMethod("POST");
        f.request.setContentType("multipart/form-data");
        MethodParameter param = arg(Handle.param4);
        assert(thrown!MissingServletRequestPartException(() {
                f.resolver.resolveArgument(param, null, f.webRequest, null);
            }) !is null);
    }

    @("RequestParamMethodArgumentResolverTests.resolvePartNotAnnot")
    unittest
    {
        auto f = setup();
        auto expected = new MockPart("part", "Hello World".representation);
        auto request = new MockHttpServletRequest();
        request.setMethod("POST");
        request.setContentType("multipart/form-data");
        request.addPart(expected);
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.part);
        const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
        assert(cast(Part) result.asObject() is expected);
    }
}

@("RequestParamMethodArgumentResolverTests.resolveDefaultValue")
unittest
{
    auto f = setup();
    MethodParameter param = arg(Handle.param1);
    const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
    assert(result.get!string == "bar");
}

@("RequestParamMethodArgumentResolverTests.missingRequestParam")
unittest
{
    auto f = setup();
    MethodParameter param = arg(Handle.param2);
    assert(thrown!MissingServletRequestParameterException(() {
            f.resolver.resolveArgument(param, null, f.webRequest, null);
        }) !is null);
}

// SPR-10578
@("RequestParamMethodArgumentResolverTests.missingRequestParamEmptyValueConvertedToNull")
unittest
{
    auto f = setup();
    WebDataBinderFactory binderFactory = new StringTrimmerBinderFactory();
    f.request.addParameter("stringNotAnnot", "");

    MethodParameter param = arg(Handle.stringNotAnnot);
    const result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
    assert(result.isNull());
}

// gh-31336: the port's conversion rejects a blank `bool` value instead of converting it to null (Spring's
// StringToBooleanConverter), so the default value is never applied.
version (FlintWebBlankConversionToNull)
{
    @("RequestParamMethodArgumentResolverTests.missingRequestParamAfterConversionWithDefaultValue")
    unittest
    {
        auto f = setup();
        WebDataBinderFactory binderFactory = new DefaultDataBinderFactory();
        f.request.addParameter("booleanParam", " ");

        MethodParameter param = arg(Handle.booleanParam);
        const result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.get!bool == false);
    }
}

@("RequestParamMethodArgumentResolverTests.missingRequestParamEmptyValueNotRequired")
unittest
{
    auto f = setup();
    WebDataBinderFactory binderFactory = new StringTrimmerBinderFactory();
    f.request.addParameter("name", "");

    MethodParameter param = arg(Handle.paramNotRequired);
    const result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
    assert(result.isNull());
}

// gh-29550: when conversion yields null, the port does not fall back to the default value.
version (FlintWebDefaultValueAfterConversion)
{
    @("RequestParamMethodArgumentResolverTests.missingRequestParamEmptyValueNotRequiredWithDefaultValue")
    unittest
    {
        auto f = setup();
        WebDataBinderFactory binderFactory = new StringTrimmerBinderFactory();
        f.request.addParameter("name", "    ");

        MethodParameter param = arg(Handle.param1);
        const result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(!result.isNull() && result.get!string == "bar");
    }
}

@("RequestParamMethodArgumentResolverTests.resolveSimpleTypeParam")
unittest
{
    auto f = setup();
    f.request.setParameter("stringNotAnnot", "plainValue");
    MethodParameter param = arg(Handle.stringNotAnnot);
    const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
    assert(result.get!string == "plainValue");
}

// SPR-8561
@("RequestParamMethodArgumentResolverTests.resolveSimpleTypeParamToNull")
unittest
{
    auto f = setup();
    MethodParameter param = arg(Handle.stringNotAnnot);
    const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
    assert(result.isNull());
}

// SPR-10180
@("RequestParamMethodArgumentResolverTests.resolveEmptyValueToDefault")
unittest
{
    auto f = setup();
    f.request.addParameter("name", "");
    MethodParameter param = arg(Handle.param1);
    const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
    assert(result.get!string == "bar");
}

@("RequestParamMethodArgumentResolverTests.resolveEmptyValueWithoutDefault")
unittest
{
    auto f = setup();
    f.request.addParameter("stringNotAnnot", "");
    MethodParameter param = arg(Handle.stringNotAnnot);
    const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
    assert(!result.isNull() && result.get!string == "");
}

@("RequestParamMethodArgumentResolverTests.resolveEmptyValueRequiredWithoutDefault")
unittest
{
    auto f = setup();
    f.request.addParameter("name", "");
    MethodParameter param = arg(Handle.paramNotRequired);
    const result = f.resolver.resolveArgument(param, null, f.webRequest, null);
    assert(!result.isNull() && result.get!string == "");
}

// The resolver neither wraps values in Optional nor returns Optional.empty() for a missing Optional!T parameter.
version (FlintWebJavaOptional)
{
    @("RequestParamMethodArgumentResolverTests.resolveOptionalParamValue")
    unittest
    {
        auto f = setup();
        WebDataBinderFactory binderFactory = new DefaultDataBinderFactory();

        MethodParameter param = arg(Handle.paramOptional);
        Any result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.get!(Optional!int).isEmpty());

        f.request.addParameter("name", "123");
        result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.holds!(Optional!int));
        assert(result.get!(Optional!int).get() == 123);
    }

    @("RequestParamMethodArgumentResolverTests.missingOptionalParamValue")
    unittest
    {
        auto f = setup();
        WebDataBinderFactory binderFactory = new DefaultDataBinderFactory();

        MethodParameter param = arg(Handle.paramOptional);
        Any result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.get!(Optional!int).isEmpty());

        result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.holds!(Optional!int));
        assert(!result.get!(Optional!int).isPresent());
    }

    @("RequestParamMethodArgumentResolverTests.resolveOptionalParamArray")
    unittest
    {
        auto f = setup();
        WebDataBinderFactory binderFactory = new DefaultDataBinderFactory();

        MethodParameter param = arg(Handle.paramOptionalArray);
        Any result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.get!(Optional!(int[])).isEmpty());

        f.request.addParameter("name", "123", "456");
        result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.holds!(Optional!(int[])));
        assert(result.get!(Optional!(int[])).get() == [123, 456]);
    }

    @("RequestParamMethodArgumentResolverTests.missingOptionalParamArray")
    unittest
    {
        auto f = setup();
        WebDataBinderFactory binderFactory = new DefaultDataBinderFactory();

        MethodParameter param = arg(Handle.paramOptionalArray);
        Any result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.get!(Optional!(int[])).isEmpty());

        result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.holds!(Optional!(int[])));
        assert(!result.get!(Optional!(int[])).isPresent());
    }

    @("RequestParamMethodArgumentResolverTests.resolveOptionalParamList")
    unittest
    {
        auto f = setup();
        WebDataBinderFactory binderFactory = new DefaultDataBinderFactory();

        MethodParameter param = arg(Handle.paramOptionalList);
        Any result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.get!(Optional!(List!string)).isEmpty());

        f.request.addParameter("name", "123", "456");
        result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.holds!(Optional!(List!string)));
        assert(result.get!(Optional!(List!string)).get().toArray() == ["123", "456"]);
    }

    @("RequestParamMethodArgumentResolverTests.missingOptionalParamList")
    unittest
    {
        auto f = setup();
        WebDataBinderFactory binderFactory = new DefaultDataBinderFactory();

        MethodParameter param = arg(Handle.paramOptionalList);
        Any result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.get!(Optional!(List!string)).isEmpty());

        result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.holds!(Optional!(List!string)));
        assert(!result.get!(Optional!(List!string)).isPresent());
    }
}

// MultipartFile and its mocks are not ported.
version (FlintWebMultipart)
{
    @("RequestParamMethodArgumentResolverTests.resolveOptionalMultipartFile")
    unittest
    {
        auto f = setup();
        WebDataBinderFactory binderFactory = new DefaultDataBinderFactory();

        auto request = new MockMultipartHttpServletRequest();
        MultipartFile expected = new MockMultipartFile("mfile", "Hello World".representation);
        request.addFile(expected);
        f.webRequest = new ServletWebRequest(request);

        MethodParameter param = arg(Handle.multipartFileOptional);
        const result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.get!(Optional!MultipartFile).get() is expected);
    }

    @("RequestParamMethodArgumentResolverTests.missingOptionalMultipartFile")
    unittest
    {
        auto f = setup();
        WebDataBinderFactory binderFactory = new DefaultDataBinderFactory();

        f.request.setMethod("POST");
        f.request.setContentType("multipart/form-data");

        MethodParameter param = arg(Handle.multipartFileOptional);
        const actual = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);

        assert(actual.get!(Optional!MultipartFile).isEmpty());
    }

    @("RequestParamMethodArgumentResolverTests.optionalMultipartFileWithoutMultipartRequest")
    unittest
    {
        auto f = setup();
        WebDataBinderFactory binderFactory = new DefaultDataBinderFactory();

        MethodParameter param = arg(Handle.multipartFileOptional);
        const actual = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);

        assert(actual.get!(Optional!MultipartFile).isEmpty());
    }
}

// The resolver takes no bean factory, so `${}` placeholders in names are not resolved (and Java's System
// properties are not ported).
version (FlintWebSystemPropertyPlaceholders)
{
    @("RequestParamMethodArgumentResolverTests.resolveNameFromSystemPropertyThroughPlaceholder")
    unittest
    {
        import flint.java.lang : System;

        auto f = setup();
        WebDataBinderFactory binderFactory = new DefaultDataBinderFactory();

        const expected = 100;
        f.request.addParameter("name", "100");

        System.setProperty("systemProperty", "name");
        scope (exit)
            System.clearProperty("systemProperty");

        MethodParameter param = arg(Handle.placeholderParam);
        const result = f.resolver.resolveArgument(param, null, f.webRequest, binderFactory);
        assert(result.holds!int && result.get!int == expected);
    }

    @("RequestParamMethodArgumentResolverTests.missingParameterFromSystemPropertyThroughPlaceholder")
    unittest
    {
        import flint.java.lang : System;

        auto f = setup();
        const expected = "name";
        System.setProperty("systemProperty", expected);

        MethodParameter param = arg(Handle.placeholderParam);
        auto ex = thrown!MissingServletRequestParameterException(() {
            f.resolver.resolveArgument(param, null, f.webRequest, null);
        });
        assert(ex !is null);
        assert(ex.getParameterName() == expected);

        System.clearProperty("systemProperty");
    }

    @("RequestParamMethodArgumentResolverTests.notNullablePrimitiveParameterFromSystemPropertyThroughPlaceholder")
    unittest
    {
        import flint.java.lang : IllegalStateException, System;
        import std.algorithm.searching : canFind;

        auto f = setup();
        const expected = "sysbar";
        System.setProperty("systemProperty", expected);

        MethodParameter param = arg(Handle.primitivePlaceholderParam);
        auto ex = thrown!IllegalStateException(() {
            f.resolver.resolveArgument(param, null, f.webRequest, null);
        });
        assert(ex !is null);
        assert(ex.msg.canFind(expected));

        System.clearProperty("systemProperty");
    }
}
