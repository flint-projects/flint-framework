/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/ErrorResponseTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors.
+/
module flint.web.error_response_tests;

// ErrorResponseTests.createWithHttpHeader and createWithHttpHeadersConsumer build responses through
// `ErrorResponse.builder(exception, status, detail)`, which flint.web has not ported yet. The cases stay here,
// compiled only once the builder lands (version FlintErrorResponseBuilder).
version (FlintErrorResponseBuilder)
{
    @("ErrorResponseTests.createWithHttpHeader")
    unittest
    {
        static assert(false, "enable once ErrorResponse.builder is ported");
    }
}
