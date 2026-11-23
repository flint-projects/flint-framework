/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/bind/annotation/RequestMethodTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; Java's null
from `resolve` is a null pointer.
+/
module flint.web.bind.request_method_tests;

import flint.http : HttpMethod;
import flint.web.bind.annotation : RequestMethod;

@safe:

@("RequestMethodTests.resolveString")
unittest
{
    static immutable methods = [
        "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE", "QUERY"
    ];
    foreach (httpMethod; methods)
    {
        auto requestMethod = RequestMethod.resolve(httpMethod);
        assert(requestMethod !is null, httpMethod);
        assert(requestMethod.name() == httpMethod);
    }
    assert(RequestMethod.resolve("PROPFIND") is null);
}

@("RequestMethodTests.resolveHttpMethod")
unittest
{
    foreach (httpMethod; HttpMethod.values())
    {
        auto requestMethod = RequestMethod.resolve(httpMethod);
        assert(requestMethod !is null, httpMethod.name());
        assert(requestMethod.name() == httpMethod.name());
    }
    assert(RequestMethod.resolve(HttpMethod.valueOf("PROPFIND")) is null);
}

@("RequestMethodTests.asHttpMethod")
unittest
{
    foreach (requestMethod; RequestMethod.values())
    {
        const httpMethod = requestMethod.asHttpMethod();
        assert(httpMethod.name() == requestMethod.name());
    }
}
