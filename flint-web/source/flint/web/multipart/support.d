/++
`org.springframework.web.multipart.support`: multipart request support, so far its missing-part exception.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/web/multipart/support/MissingServletRequestPartException.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook.
+/
module flint.web.multipart.support;

import flint.engine.aot.any : Any;
import flint.http : HttpStatus, HttpStatusCode, ProblemDetail;
import flint.jakarta.servlet : ServletException;
import flint.web : ErrorResponse;

@safe:

/// `MissingServletRequestPartException`: a required part of a multipart request is missing (400).
class MissingServletRequestPartException : ServletException, ErrorResponse
{
    mixin ErrorResponse.Defaults;

    private string requestPartName;
    private ProblemDetail body;

    /// For the missing part `requestPartName`.
    this(string requestPartName)
    {
        super("Required part '" ~ requestPartName ~ "' is not present.");
        this.requestPartName = requestPartName;
        body = ProblemDetail.forStatus(getStatusCode());
        body.setDetail(msg);
    }

    /// The name of the missing part.
    string getRequestPartName() const pure nothrow @nogc
    {
        return requestPartName;
    }

    HttpStatusCode getStatusCode()
    {
        return HttpStatus.BAD_REQUEST;
    }

    ProblemDetail getBody()
    {
        return
        body;
    }

    override Any[] getDetailMessageArguments()
    {
        return [Any.of(requestPartName)];
    }
}
