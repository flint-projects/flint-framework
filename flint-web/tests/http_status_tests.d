/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/http/HttpStatusTests.java and HttpMethodTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts.
+/
module flint.http.http_status_tests;

import flint.http : HttpMethod, HttpStatus, HttpStatusCode;
import flint.java.lang : IllegalArgumentException;

@safe:

private string[][int] statusCodes()
{
    string[][int] codes;
    void add(int code, string name)
    {
        codes[code] ~= name;
    }

    add(100, "CONTINUE");
    add(101, "SWITCHING_PROTOCOLS");
    add(102, "PROCESSING");
    add(103, "EARLY_HINTS");
    add(200, "OK");
    add(201, "CREATED");
    add(202, "ACCEPTED");
    add(203, "NON_AUTHORITATIVE_INFORMATION");
    add(204, "NO_CONTENT");
    add(205, "RESET_CONTENT");
    add(206, "PARTIAL_CONTENT");
    add(207, "MULTI_STATUS");
    add(208, "ALREADY_REPORTED");
    add(226, "IM_USED");
    add(300, "MULTIPLE_CHOICES");
    add(301, "MOVED_PERMANENTLY");
    add(302, "FOUND");
    add(303, "SEE_OTHER");
    add(304, "NOT_MODIFIED");
    add(307, "TEMPORARY_REDIRECT");
    add(308, "PERMANENT_REDIRECT");
    add(400, "BAD_REQUEST");
    add(401, "UNAUTHORIZED");
    add(402, "PAYMENT_REQUIRED");
    add(403, "FORBIDDEN");
    add(404, "NOT_FOUND");
    add(405, "METHOD_NOT_ALLOWED");
    add(406, "NOT_ACCEPTABLE");
    add(407, "PROXY_AUTHENTICATION_REQUIRED");
    add(408, "REQUEST_TIMEOUT");
    add(409, "CONFLICT");
    add(410, "GONE");
    add(411, "LENGTH_REQUIRED");
    add(412, "PRECONDITION_FAILED");
    add(413, "PAYLOAD_TOO_LARGE");
    add(413, "CONTENT_TOO_LARGE");
    add(414, "URI_TOO_LONG");
    add(415, "UNSUPPORTED_MEDIA_TYPE");
    add(416, "REQUESTED_RANGE_NOT_SATISFIABLE");
    add(417, "EXPECTATION_FAILED");
    add(418, "I_AM_A_TEAPOT");
    add(421, "MISDIRECTED_REQUEST");
    add(422, "UNPROCESSABLE_CONTENT");
    add(422, "UNPROCESSABLE_ENTITY");
    add(423, "LOCKED");
    add(424, "FAILED_DEPENDENCY");
    add(425, "TOO_EARLY");
    add(426, "UPGRADE_REQUIRED");
    add(428, "PRECONDITION_REQUIRED");
    add(429, "TOO_MANY_REQUESTS");
    add(431, "REQUEST_HEADER_FIELDS_TOO_LARGE");
    add(451, "UNAVAILABLE_FOR_LEGAL_REASONS");
    add(500, "INTERNAL_SERVER_ERROR");
    add(501, "NOT_IMPLEMENTED");
    add(502, "BAD_GATEWAY");
    add(503, "SERVICE_UNAVAILABLE");
    add(504, "GATEWAY_TIMEOUT");
    add(505, "HTTP_VERSION_NOT_SUPPORTED");
    add(506, "VARIANT_ALSO_NEGOTIATES");
    add(507, "INSUFFICIENT_STORAGE");
    add(508, "LOOP_DETECTED");
    add(509, "BANDWIDTH_LIMIT_EXCEEDED");
    add(510, "NOT_EXTENDED");
    add(511, "NETWORK_AUTHENTICATION_REQUIRED");
    return codes;
}

private bool contains(const(string)[] names, string name)
{
    foreach (candidate; names)
        if (candidate == name)
            return true;
    return false;
}

// Java's reflective @Deprecated lookup becomes the list of constants the upstream source marks deprecated.
private immutable string[] deprecatedNames = [
    "PROCESSING", "PAYLOAD_TOO_LARGE", "I_AM_A_TEAPOT", "UNPROCESSABLE_ENTITY",
    "BANDWIDTH_LIMIT_EXCEEDED", "NOT_EXTENDED"
];

@("HttpStatusTests.fromMapToEnum")
unittest
{
    foreach (value, names; statusCodes())
    {
        HttpStatus status = HttpStatus.valueOf(value);
        assert(status.value() == value, "Invalid value");
        assert(contains(names, status.name()), "Invalid name for code");
        if (contains(deprecatedNames, status.name()))
            assert(names.length == 1, "Should not resolve deprecated enum value when non-deprecated exists");
    }
}

@("HttpStatusTests.fromEnumToMap")
unittest
{
    auto codes = statusCodes();
    foreach (status; HttpStatus.values())
    {
        const code = status.value();
        assert(code in codes, "Map has no value for code");
        assert(contains(codes[code], status.name()), "Invalid name for code");
    }
}

@("HttpStatusTests.allStatusSeriesShouldMatchExpectations")
unittest
{
    foreach (status; HttpStatus.values())
    {
        const HttpStatus.Series expectedSeries = HttpStatus.Series.valueOf(status.value());
        assert(status.series() == expectedSeries);
    }
}

@("HttpMethodTests.comparison")
unittest
{
    HttpMethod method1 = HttpMethod.valueOf("FOO");
    HttpMethod method2 = HttpMethod.valueOf("FOO");
    HttpMethod method3 = HttpMethod.valueOf("BAR");
    assert(method1 == method2);
    assert(method1 != method3);
    assert(method1.hashCode() == method2.hashCode());
    assert(method1.compareTo(method2) == 0);
    assert(method1.compareTo(method3) != 0);
}

@("HttpMethodTests.values")
unittest
{
    HttpMethod[] values = HttpMethod.values();
    const HttpMethod[] expected = [
        HttpMethod.GET, HttpMethod.HEAD, HttpMethod.POST, HttpMethod.PUT, HttpMethod.PATCH,
        HttpMethod.DELETE, HttpMethod.OPTIONS, HttpMethod.TRACE, HttpMethod.QUERY
    ];
    assert(values == expected);
    // check defensive copy
    values[0] = HttpMethod.POST;
    assert(HttpMethod.values() == expected);
}

@("HttpMethodTests.valueOf")
unittest
{
    HttpMethod get = HttpMethod.valueOf("GET");
    assert(get == HttpMethod.GET);
    get = HttpMethod.valueOf("Get");
    assert(get == HttpMethod.GET && get.name() == "GET");
    get = HttpMethod.valueOf("get");
    assert(get == HttpMethod.GET && get.name() == "GET");
    // Java's isNotSameAs on two unknown methods is reference identity, which a value struct does not
    // have (R11); equality is what remains observable.
    const HttpMethod foo = HttpMethod.valueOf("foo");
    const HttpMethod other = HttpMethod.valueOf("foo");
    assert(foo == other);
}

@("HttpMethodTests.name")
unittest
{
    HttpMethod method = HttpMethod.valueOf("FOO");
    assert(method.name() == "FOO");
}

@("HttpMethodTests.matches")
unittest
{
    assert(HttpMethod.GET.matches("GET"));
    assert(!HttpMethod.GET.matches("FOO"));
}

// Flint additions: the R15 adaptation's own contract.

@("HttpStatus converts to HttpStatusCode and compares by value")
unittest
{
    HttpStatusCode code = HttpStatus.NOT_FOUND;
    assert(code.value() == 404);
    assert(code == HttpStatusCode.valueOf(404));
    assert(HttpStatus.NOT_FOUND == HttpStatusCode.valueOf(404));
    assert(code.toString() == "404 NOT_FOUND");
    assert(HttpStatusCode.valueOf(499).toString() == "499");
    assert(HttpStatusCode.valueOf(499).is4xxClientError());
    assert(HttpStatus.resolve(499) is null);
    assert(HttpStatus.resolve(413).name() == "CONTENT_TOO_LARGE");
    assert(HttpStatus.valueOf("I_AM_A_TEAPOT").value() == 418);
    assert(HttpStatus.OK.getReasonPhrase() == "OK");
    assert(HttpStatus.INTERNAL_SERVER_ERROR.toString() == "500 INTERNAL_SERVER_ERROR");
}

@("HttpStatusCode.valueOf and HttpStatus.valueOf reject what Java rejects")
unittest
{
    foreach (bad; [99, 1000, -1])
    {
        bool thrown;
        try
            HttpStatusCode.valueOf(bad);
        catch (IllegalArgumentException e)
            thrown = e.getMessage() == "Status code '" ~ (bad == 99 ? "99" : bad == 1000
                    ? "1000" : "-1") ~ "' should be a three-digit positive integer";
        assert(thrown);
    }
    bool thrown;
    try
        HttpStatus.valueOf(499);
    catch (IllegalArgumentException e)
        thrown = e.getMessage() == "No matching constant for [499]";
    assert(thrown);
}

@("HttpMethod.hashCode is Java's String.hashCode")
unittest
{
    assert(HttpMethod.GET.hashCode() == 70_454);
    assert(HttpMethod.valueOf("ÄÖ").hashCode() == 196 * 31 + 214);
}

@("annotations read as Java's: positional value shorthand, named arrays, composed meta-annotation")
unittest
{
    import flint.web.bind.annotation : GetMapping, RequestMapping, RequestMethod, RequestParam,
        ResponseStatus, RestController, ValueConstants;
    import flint.stereotype : Controller;

    @RestController static class GreetingController
    {
        @GetMapping("/greeting")
        void greeting(@RequestParam(value : "name", defaultValue:
                "World") string name)
        {
        }

        @GetMapping(path : ["/a", "/b"], produces:
                ["application/json"])
        void two()
        {
        }
    }

    enum get = __traits(getAttributes, GreetingController.greeting)[0];
    static assert(get.value == ["/greeting"]);
    enum two = __traits(getAttributes, GreetingController.two)[0];
    static assert(two.path == ["/a", "/b"] && two.produces == ["application/json"]);
    enum meta = __traits(getAttributes, GetMapping)[0];
    static assert(is(typeof(meta) == RequestMapping) && meta.method == [RequestMethod.GET]);
    static assert(is(__traits(getAttributes, RestController)[0] == Controller));
    enum ResponseStatus status = ResponseStatus.init;
    static assert(status.value == HttpStatus.INTERNAL_SERVER_ERROR && status.reason == "");
    static assert(RequestMethod.resolve("GET").asHttpMethod() == HttpMethod.GET);
    static assert(RequestMethod.resolve("get") is null);
    static assert(ValueConstants.DEFAULT_NONE.length == 22); // UTF-8 bytes; 18 UTF-16 units in Java (R14)
}
