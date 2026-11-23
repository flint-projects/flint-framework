/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/ErrorResponseTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; the
`Consumer<HttpHeaders>` is a delegate (rulebook R9).
+/
module flint.web.error_response_tests;

// Both cases build responses through `ErrorResponse.builder(exception, status, detail)`, which flint.web has not
// ported yet. They compile once the builder lands (version FlintErrorResponseBuilder).
version (FlintErrorResponseBuilder)
{
    import flint.http : HttpHeaders, HttpStatus;
    import flint.java.lang : IllegalStateException;
    import flint.web : ErrorResponse;

@safe:

    @("ErrorResponseTests.createWithHttpHeader")
    unittest
    {
        auto response = ErrorResponse.builder(new IllegalStateException(), HttpStatus.BAD_REQUEST,
                "test").header("header", "value").build();
        assert(response.getHeaders().containsHeaderValue("header", "value"));
    }

    @("ErrorResponseTests.createWithHttpHeadersConsumer")
    unittest
    {
        auto response = ErrorResponse.builder(new IllegalStateException(), HttpStatus.BAD_REQUEST,
                "test").header("header", "value").headers((HttpHeaders headers) {
            headers.add("header", "value2");
            headers.add("another", "value3");
        }).build();
        assert(response.getHeaders().get("header") == ["value", "value2"]);
        assert(response.getHeaders().get("another") == ["value3"]);
    }
}
