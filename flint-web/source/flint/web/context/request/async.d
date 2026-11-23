/++
`org.springframework.web.context.request.async`: asynchronous request processing, so far its timeout exception.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/web/context/request/async/AsyncRequestTimeoutException.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook.
+/
module flint.web.context.request.async;

import flint.http : HttpStatus, HttpStatusCode, ProblemDetail;
import flint.java.lang : RuntimeException;
import flint.web : ErrorResponse;

@safe:

/// `AsyncRequestTimeoutException`: an asynchronous request timed out (503).
class AsyncRequestTimeoutException : RuntimeException, ErrorResponse
{
    mixin ErrorResponse.Defaults;

    ///
    this(string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(null, null, file, line);
    }

    HttpStatusCode getStatusCode()
    {
        return HttpStatus.SERVICE_UNAVAILABLE;
    }

    ProblemDetail getBody()
    {
        return ProblemDetail.forStatus(getStatusCode());
    }
}
