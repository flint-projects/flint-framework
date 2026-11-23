/++
`org.springframework.web.bind`: the binding exceptions of request parameters, headers and path variables.

Ported from spring-projects/spring-framework v7.1.0, spring-web/src/main/java/org/springframework/web/bind/
(ServletRequestBindingException.java, MissingRequestValueException.java,
MissingServletRequestParameterException.java, MissingPathVariableException.java, MissingRequestHeaderException.java,
MissingRequestCookieException.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. They skip backtrace capture (ADR-030 section 4).
`MethodArgumentNotValidException` lands with Jakarta Validation and spring-context's `BindingResult`.
+/
module flint.web.bind;

import flint.core : MethodParameter, javaTypeName;
import flint.engine.aot.any : Any;
import flint.http : HttpStatus, HttpStatusCode, ProblemDetail;
import flint.jakarta.servlet : ServletException;
import flint.web : ErrorResponse, skipBacktrace;

@safe:

/// `ServletRequestBindingException`: a fatal binding problem (400).
class ServletRequestBindingException : ServletException, ErrorResponse
{
    mixin ErrorResponse.Defaults;

    private ProblemDetail body;
    private string messageDetailCode;
    private Any[] messageDetailArguments;

    /// With a message and optional cause.
    this(string message, Throwable cause = null)
    {
        this(message, cause, null, null);
    }

    /// With a message, cause, detail message code and arguments.
    protected this(string message, Throwable cause, string messageDetailCode, Any[] messageDetailArguments)
    {
        super(message, cause);
        body = ProblemDetail.forStatusAndDetail(getStatusCode(), message);
        this.messageDetailCode = messageDetailCode !is null ? messageDetailCode
            : ErrorResponse.getDefaultDetailMessageCode(typeid(this), null);
        this.messageDetailArguments = messageDetailArguments;
        skipBacktrace(this);
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

    override string getDetailMessageCode()
    {
        return messageDetailCode;
    }

    override Any[] getDetailMessageArguments()
    {
        return messageDetailArguments;
    }
}

/// `MissingRequestValueException`: a required value is missing.
class MissingRequestValueException : ServletRequestBindingException
{
    private bool missingAfterConversion;

    ///
    this(string message, bool missingAfterConversion = false)
    {
        super(message);
        this.missingAfterConversion = missingAfterConversion;
    }

    /// ditto, with a message code.
    protected this(string message, bool missingAfterConversion, string messageDetailCode, Any[] arguments)
    {
        super(message, null, messageDetailCode, arguments);
        this.missingAfterConversion = missingAfterConversion;
    }

    /// Whether the value was present but became `null` after conversion.
    bool isMissingAfterConversion() const pure nothrow @nogc
    {
        return missingAfterConversion;
    }
}

/// `MissingServletRequestParameterException`.
class MissingServletRequestParameterException : MissingRequestValueException
{
    private string parameterName;
    private string parameterType;
    private MethodParameter parameter;

    /// For a missing `parameterName` of `parameterType` (a D type name, printed as Java's).
    this(string parameterName, string parameterType, bool missingAfterConversion = false)
    {
        this(parameterName, parameterType, null, missingAfterConversion);
    }

    /// ditto, for a method parameter.
    this(string parameterName, string parameterType, MethodParameter parameter, bool missingAfterConversion)
    {
        super("", missingAfterConversion, null, [Any.of(parameterName)]);
        this.parameterName = parameterName;
        this.parameterType = parameterType;
        this.parameter = parameter;
        msg = computeMessage();
        getBody().setDetail(initBodyDetail(parameterName));
    }

    private string computeMessage()
    {
        return "Required request parameter '" ~ parameterName ~ "' for method parameter type " ~ simpleJavaName(
                // dfmt off
                parameterType) ~ " is "
                        ~ (isMissingAfterConversion() ? "present but converted to null" : "not present");
                // dfmt on
    }

    private static string initBodyDetail(string name)
    {
        return "Required parameter '" ~ name ~ "' is not present.";}

        /// The parameter name.
        final string getParameterName() const pure nothrow @nogc
        {
            return parameterName;}

            /// The parameter type.
            final string getParameterType() const pure nothrow @nogc
            {
                return parameterType;}

                /// The method parameter, or `null`.
                MethodParameter getMethodParameter() pure nothrow @nogc
                {
                    return parameter;}
                }

                /// `MissingPathVariableException`: a URI template variable is missing (500, a server-side mistake).
                class MissingPathVariableException : MissingRequestValueException
                {
                    private string variableName; private MethodParameter parameter; ///
                    this(string variableName, MethodParameter parameter, bool missingAfterConversion = false)
                    {
                        super("", missingAfterConversion, null, [Any.of(variableName)]); this.variableName
                            = variableName; this.parameter = parameter; msg = "Required URI template variable '"
                            ~ variableName ~ "' for method parameter type " ~ simpleJavaName(parameter is null
                                    ? "" : parameter.getNestedParameterType()) ~ " is " ~ (missingAfterConversion
                                    ? "present but converted to null" : "not present"); getBody().setDetail(
                                    "Required path variable '" ~ variableName ~ "' is not present.");}

                        override HttpStatusCode getStatusCode()
                        {
                            return isMissingAfterConversion() ? HttpStatus.BAD_REQUEST
                                : HttpStatus.INTERNAL_SERVER_ERROR;}

                            /// The variable name.
                            final string getVariableName() const pure nothrow @nogc
                            {
                                return variableName;}

                                /// The method parameter.
                                final MethodParameter getParameter() pure nothrow @nogc
                                {
                                    return parameter;}
                                }

                                /// `MissingRequestHeaderException`.
                                class MissingRequestHeaderException : MissingRequestValueException
                                {
                                    private string headerName; private MethodParameter parameter; ///
                                    this(string headerName, MethodParameter parameter,
                                            bool missingAfterConversion = false)
                                    {
                                        super("", missingAfterConversion, null, [Any.of(headerName)]);
                                            this.headerName = headerName; this.parameter = parameter; // dfmt off
        msg = "Required request header '" ~ headerName ~ "' for method parameter type "
                ~ simpleJavaName(parameter is null
        // dfmt on
                                             ? "" : parameter.getNestedParameterType()) ~ " is " ~ (
                                                missingAfterConversion ? "present but converted to null" : "not present");
                                        getBody().setDetail("Required header '" ~ headerName ~ "' is not present.");
                                    }

                                    /// The header name.
                                    final string getHeaderName() const pure nothrow @nogc
                                    {
                                        return headerName;
                                    }

                                    /// The method parameter.
                                    final MethodParameter getParameter() pure nothrow @nogc
                                    {
                                        return parameter;
                                    }
                                }

                                /// `MissingRequestCookieException`.
                                class MissingRequestCookieException : MissingRequestValueException
                                {
                                    private string cookieName;
                                    private MethodParameter parameter;

                                    ///
                                    this(string cookieName, MethodParameter parameter,
                                            bool missingAfterConversion = false)
                                    {
                                        super("", missingAfterConversion, null, [Any.of(cookieName)]);
                                        this.cookieName = cookieName;
                                        this.parameter = parameter;
                                        msg = "Required cookie '" ~ cookieName
                                            ~ "' for method parameter type " ~ simpleJavaName(parameter is null
                                                    ? "" : parameter.getNestedParameterType()) ~ " is " ~ (missingAfterConversion
                                                    ? "present but converted to null" : "not present");
                                        getBody().setDetail("Required cookie '" ~ cookieName ~ "' is not present.");
                                    }

                                    /// The cookie name.
                                    final string getCookieName() const pure nothrow @nogc
                                    {
                                        return cookieName;
                                    }
                                }

                                /// Java's `Class.getSimpleName()` for a D type name: `string` → `String`, `long` → `long`, `app.Owner` → `Owner`.
                                package(flint) string simpleJavaName(string type) pure nothrow
                                {
                                    const java = javaTypeName(type);
                                    foreach_reverse (i, c; java)
                                        if (c == '.')
                                            return java[i + 1 .. $];
                                    return java;
                                }
