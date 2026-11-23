/++
`org.springframework.http.server`: the server-side `HttpRequest` and response, over the servlet API.

Ported from spring-projects/spring-framework v7.1.0, spring-web/src/main/java/org/springframework/http/server/
(ServerHttpRequest.java, ServerHttpResponse.java, ServletServerHttpRequest.java,
ServletServerHttpResponse.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook (docs/spring/api-mapping.md). As in Spring 7,
flushing the body stream is a no-op and `flush()` commits the servlet response only once a body was written,
which is why `@ResponseBody` responses carry `Content-Length` while `ResponseEntity` bodies are chunked.
+/
module flint.http.server;

import flint.http : HttpHeaders, HttpInputMessage, HttpMethod, HttpOutputMessage, HttpRequest,
    HttpStatusCode, MediaType;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.java.net : URI;

@safe:

/// `ServerHttpRequest`.
interface ServerHttpRequest : HttpRequest, HttpInputMessage
{
}

/// `ServerHttpResponse`.
interface ServerHttpResponse : HttpOutputMessage
{
    /// Sets the status.
    void setStatusCode(HttpStatusCode status);

    /// Writes headers, and commits the response when a body was written.
    void flush();

    /// Writes headers.
    void close();
}

/// `ServletServerHttpRequest`.
class ServletServerHttpRequest : ServerHttpRequest
{
    private HttpServletRequest servletRequest;
    private HttpHeaders headers;
    private bool headersRead;

    ///
    this(HttpServletRequest servletRequest) pure nothrow @nogc
    {
        this.servletRequest = servletRequest;
    }

    /// The wrapped request.
    HttpServletRequest getServletRequest() pure nothrow @nogc
    {
        return servletRequest;
    }

    HttpMethod getMethod()
    {
        return HttpMethod.valueOf(servletRequest.getMethod());
    }

    URI getURI()
    {
        const query = servletRequest.getQueryString();
        return URI.create(servletRequest.getRequestURL() ~ (query !is null ? "?" ~ query : ""));
    }

    HttpHeaders getHeaders()
    {
        if (!headersRead)
        {
            headers = HttpHeaders.create();
            foreach (name; servletRequest.getHeaderNames())
                foreach (value; servletRequest.getHeaders(name))
                    headers.add(name, value);
            // Spring adds Content-Type with the request's character encoding when the header lacks one.
            const contentType = servletRequest.getContentType();
            if (contentType !is null && !headers.containsHeader(HttpHeaders.CONTENT_TYPE))
                headers.set(HttpHeaders.CONTENT_TYPE, contentType);
            const length = servletRequest.getContentLengthLong();
            if (length >= 0 && !headers.containsHeader(HttpHeaders.CONTENT_LENGTH))
                headers.setContentLength(length);
            headersRead = true;
        }
        return headers;
    }

    const(ubyte)[] getBody()
    {
        return servletRequest.getInputStream().readAllBytes();
    }
}

/// `ServletServerHttpResponse`.
class ServletServerHttpResponse : ServerHttpResponse
{
    private HttpServletResponse servletResponse;
    private HttpHeaders headers;
    private bool headersWritten;
    private bool bodyUsed;

    ///
    this(HttpServletResponse servletResponse) pure nothrow
    {
        this.servletResponse = servletResponse;
        headers = HttpHeaders.create();
    }

    /// The wrapped response.
    HttpServletResponse getServletResponse() pure nothrow @nogc
    {
        return servletResponse;
    }

    void setStatusCode(HttpStatusCode status)
    {
        servletResponse.setStatus(status.value());
    }

    /// The headers; read-only once written.
    HttpHeaders getHeaders() pure nothrow
    {
        return headersWritten ? HttpHeaders.readOnlyHttpHeaders(headers) : headers;
    }

    void writeBody(scope const(ubyte)[] bytes)
    {
        bodyUsed = true;
        writeHeaders();
        servletResponse.getOutputStream().write(bytes);
    }

    void flush()
    {
        writeHeaders();
        if (bodyUsed)
            servletResponse.flushBuffer();
    }

    void close()
    {
        writeHeaders();
    }

    private void writeHeaders()
    {
        if (headersWritten)
            return;
        foreach (name, values; headers)
        {
            if (equalsAscii(name, HttpHeaders.CONTENT_TYPE))
                servletResponse.setContentType(values.length != 0 ? values[0] : null);
            else if (equalsAscii(name, HttpHeaders.CONTENT_LENGTH))
            {
                import flint.http : parseJavaLong;

                if (values.length != 0)
                    servletResponse.setContentLengthLong(parseJavaLong(values[0]));
            }
            else
                foreach (value; values)
                    servletResponse.addHeader(name, value);
        }
        // Spring: a Content-Type with a charset sets the response encoding too.
        if (servletResponse.getContentType() is null)
        {
            if (auto contentType = headers.getContentType())
                if (auto charset = contentType.getCharset())
                    servletResponse.setCharacterEncoding(charset.name());
        }
        headersWritten = true;
    }
}

private bool equalsAscii(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i, c; a)
    {
        const x = c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
        const y = b[i] >= 'A' && b[i] <= 'Z' ? cast(char)(b[i] + 32) : b[i];
        if (x != y)
            return false;
    }
    return true;
}
