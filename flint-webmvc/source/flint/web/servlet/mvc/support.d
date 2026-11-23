/++
`org.springframework.web.servlet.mvc.support`: `DefaultHandlerExceptionResolver`.

Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/main/java/org/springframework/web/servlet/mvc/support/DefaultHandlerExceptionResolver.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. Every `ErrorResponse` becomes
`sendError(status, detail)` with its headers, as in Spring 6+; the remaining branches map Spring's other standard
exceptions.
+/
module flint.web.servlet.mvc.support;

import flint.engine.aot.any : Any;
import flint.http.converter : HttpMessageNotReadableException, HttpMessageNotWritableException;
import flint.jakarta.servlet : RequestDispatcher;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.web : ErrorResponse;
import flint.web.method.annotation : MethodArgumentConversionNotSupportedException, TypeMismatchException;
import flint.web.servlet : ModelAndView;
import flint.web.servlet.handler : AbstractHandlerExceptionResolver;

@safe:

/// `DefaultHandlerExceptionResolver`: Spring MVC's standard exceptions to error statuses.
class DefaultHandlerExceptionResolver : AbstractHandlerExceptionResolver
{
    /// `WebUtils.ERROR_EXCEPTION_ATTRIBUTE`.
    enum string ERROR_EXCEPTION_ATTRIBUTE = RequestDispatcher.ERROR_EXCEPTION;

    ///
    this() pure nothrow @nogc
    {
        setOrder(int.max);
    }

    protected override ModelAndView doResolveException(HttpServletRequest request,
            HttpServletResponse response, Object handler, Exception ex)
    {
        try
        {
            if (auto errorResponse = cast(ErrorResponse) ex)
                return handleErrorResponse(errorResponse, request, response, handler);
            if (auto theEx = cast(MethodArgumentConversionNotSupportedException) ex)
            {
                sendServerError(ex, request, response);
                return new ModelAndView();
            }
            if (cast(TypeMismatchException) ex)
            {
                response.sendError(HttpServletResponse.SC_BAD_REQUEST);
                return new ModelAndView();
            }
            if (cast(HttpMessageNotReadableException) ex)
            {
                if (!response.isCommitted())
                    response.sendError(HttpServletResponse.SC_BAD_REQUEST);
                return new ModelAndView();
            }
            if (cast(HttpMessageNotWritableException) ex)
            {
                if (!response.isCommitted())
                    sendServerError(ex, request, response);
                return new ModelAndView();
            }
        }
        catch (Exception handlerEx)
        {
            // Spring logs "Failure while trying to resolve exception" and returns null.
        }
        return null;
    }

    /// Copies the error response's headers and calls `sendError(status, detail)`.
    protected ModelAndView handleErrorResponse(ErrorResponse errorResponse,
            HttpServletRequest request, HttpServletResponse response, Object handler)
    {
        if (!response.isCommitted())
        {
            foreach (name, values; errorResponse.getHeaders())
                foreach (value; values)
                    response.addHeader(name, value);
            const status = errorResponse.getStatusCode().value();
            const message = errorResponse.getBody().getDetail();
            if (message !is null)
                response.sendError(status, message);
            else
                response.sendError(status);
        }
        return new ModelAndView();
    }

    /// Records the exception and sends 500.
    protected void sendServerError(Exception ex, HttpServletRequest request, HttpServletResponse response)
    {
        request.setAttribute(ERROR_EXCEPTION_ATTRIBUTE, Any.of(cast(Object) ex));
        response.sendError(HttpServletResponse.SC_INTERNAL_SERVER_ERROR);
    }
}
