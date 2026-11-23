/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/cors/CorsUtilsTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. The test lives with
flint.mock.web's `MockHttpServletRequest` in flint:framework-test, which depends on flint:web.
+/
module flint.web.cors_utils_tests;

import flint.http : HttpHeaders, HttpMethod;
import flint.mock.web : MockHttpServletRequest;
import flint.web.cors : CorsUtils;

@safe:

@("CorsUtilsTests.isCorsRequest")
unittest
{
    auto request = new MockHttpServletRequest();
    request.addHeader(HttpHeaders.ORIGIN, "https://domain.com");
    assert(CorsUtils.isCorsRequest(request));
}

@("CorsUtilsTests.isNotCorsRequest")
unittest
{
    auto request = new MockHttpServletRequest();
    assert(!CorsUtils.isCorsRequest(request));
}

@("CorsUtilsTests.isPreFlightRequest")
unittest
{
    auto request = new MockHttpServletRequest();
    request.setMethod(HttpMethod.OPTIONS.name());
    request.addHeader(HttpHeaders.ORIGIN, "https://domain.com");
    request.addHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD, "GET");
    assert(CorsUtils.isPreFlightRequest(request));
}

@("CorsUtilsTests.isNotPreFlightRequest")
unittest
{
    auto request = new MockHttpServletRequest();
    assert(!CorsUtils.isPreFlightRequest(request));

    request = new MockHttpServletRequest();
    request.setMethod(HttpMethod.OPTIONS.name());
    request.addHeader(HttpHeaders.ORIGIN, "https://domain.com");
    assert(!CorsUtils.isPreFlightRequest(request));
}
