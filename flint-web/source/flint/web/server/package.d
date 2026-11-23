/++
`org.springframework.web.server`: `ResponseStatusException` and its subclasses.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/web/server/ResponseStatusException.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook (docs/spring/api-mapping.md). It skips
backtrace capture: it is a framework control-flow exception (ADR-030 section 4).
+/
module flint.web.server;

import flint.engine.aot.any : Any;
import flint.http : HttpHeaders, HttpStatusCode, ProblemDetail;
import flint.web : ErrorResponseException;

@safe:

/// `ResponseStatusException`: an `ErrorResponseException` with a status and an optional reason.
class ResponseStatusException : ErrorResponseException
{
    private string reason;

    /// With `status` and an optional `reason` and cause.
    this(HttpStatusCode status, string reason = null, Throwable cause = null)
    {
        this(status, reason, cause, null, null);
    }

    /// With a raw status code.
    this(int rawStatusCode, string reason, Throwable cause)
    {
        this(HttpStatusCode.valueOf(rawStatusCode), reason, cause);
    }

    /// Spring's protected constructor with message code and arguments.
    protected this(HttpStatusCode status, string reason, Throwable cause, string messageDetailCode,
            Any[] messageDetailArguments)
    {
        super(status, ProblemDetail.forStatus(status), cause, messageDetailCode, messageDetailArguments);
        this.reason = reason;
        setDetail(reason);
    }

    /// The reason, or `null`.
    string getReason() const pure nothrow @nogc
    {
        return reason;
    }

    /// `HttpHeaders.EMPTY`.
    override HttpHeaders getHeaders()
    {
        return HttpHeaders.EMPTY();
    }

    /// `"404 NOT_FOUND \"reason\""`.
    protected override string computeMessage()
    {
        return getStatusCode().toString() ~ (reason !is null ? " \"" ~ reason ~ "\"" : "");
    }
}
