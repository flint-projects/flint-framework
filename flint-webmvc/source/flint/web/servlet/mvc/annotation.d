/++
`org.springframework.web.servlet.mvc.annotation`: `ResponseStatusExceptionResolver`.

Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/main/java/org/springframework/web/servlet/mvc/annotation/ResponseStatusExceptionResolver.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: `@ResponseStatus` on an exception class is read from its Flint AOT descriptor
(contract 1 section 4.2) instead of reflection; message-source resolution of reasons waits for spring-context.
+/
module flint.web.servlet.mvc.annotation;

import flint.engine.aot.descriptor : DescriptorTable;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.web.bind.annotation : ResponseStatus;
import flint.web.server : ResponseStatusException;
import flint.web.servlet : ModelAndView;
import flint.web.servlet.handler : AbstractHandlerExceptionResolver;

@safe:

/// `ResponseStatusExceptionResolver`: `ResponseStatusException` and `@ResponseStatus` exception types.
class ResponseStatusExceptionResolver : AbstractHandlerExceptionResolver
{
    private DescriptorTable descriptors;

    /// With the descriptors that carry `@ResponseStatus` on exception classes (may be `null`).
    this(DescriptorTable descriptors = null) pure nothrow @nogc
    {
        this.descriptors = descriptors;
    }

    protected override ModelAndView doResolveException(HttpServletRequest request, HttpServletResponse response,
            Object handler, Exception ex)
    {
        if (auto rse = cast(ResponseStatusException) ex)
            return resolveResponseStatusException(rse, request, response, handler);
        bool found;
        auto status = findResponseStatus(ex, found);
        if (found)
            return resolveResponseStatus(status, request, response, handler, ex);
        if (auto cause = cast(Exception) ex.next)
            return doResolveException(request, response, handler, cause);
        return null;
    }

    private ResponseStatus findResponseStatus(Exception ex, out bool found)
    {
        if (descriptors is null)
            return ResponseStatus.init;
        for (auto info = typeid(ex); info !is null; info = info.base)
        {
            if (auto descriptor = descriptors.find(info.name))
            {
                if (auto annotation = descriptor.annotation("flint.web.bind.annotation.ResponseStatus"))
                {
                    found = true;
                    ResponseStatus status = annotation.value.get!ResponseStatus;
                    return status;
                }
            }
        }
        return ResponseStatus.init;
    }

    /// `@ResponseStatus` on the exception's class: `sendError(code, reason)` or `sendError(code)`.
    protected ModelAndView resolveResponseStatus(ResponseStatus responseStatus, HttpServletRequest request,
            HttpServletResponse response, Object handler, Exception ex)
    {
        const statusCode = responseStatus.code.value();
        return applyStatusAndReason(statusCode, responseStatus.reason.length != 0 ? responseStatus.reason : null, response);
    }

    /// `ResponseStatusException`: its headers, then `sendError(status, reason)`.
    protected ModelAndView resolveResponseStatusException(ResponseStatusException ex, HttpServletRequest request,
            HttpServletResponse response, Object handler)
    {
        foreach (name, values; ex.getHeaders())
            foreach (value; values)
                response.addHeader(name, value);
        return applyStatusAndReason(ex.getStatusCode().value(), ex.getReason(), response);
    }

    /// `sendError(statusCode, reason)`, or `sendError(statusCode)` without a reason.
    protected ModelAndView applyStatusAndReason(int statusCode, string reason, HttpServletResponse response)
    {
        if (reason is null || reason.length == 0)
            response.sendError(statusCode);
        else
            response.sendError(statusCode, reason);
        return new ModelAndView();
    }
}
