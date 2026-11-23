/++
`org.springframework.test.web.servlet.request`: building MockMvc requests.

Ported from spring-projects/spring-framework v7.1.0,
spring-test/src/main/java/org/springframework/test/web/servlet/request/ (MockMvcRequestBuilders.java,
MockHttpServletRequestBuilder.java, AbstractMockHttpServletRequestBuilder.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: `Object... uriVariables` is a template parameter pack (R7) rendered with
`std.conv.to!string`; the builder is a final class with Java's chained methods (R12). Query parameters of the URL
are decoded as UTF-8 (R14), as `UriUtils.decode` does.
+/
module flint.test.web.servlet.request;

import flint.engine.aot.any : Any;
import flint.http : HttpHeaders, HttpMethod, MediaType;
import flint.jakarta.servlet : ServletContext;
import flint.jakarta.servlet.http : Cookie;
import flint.mock.web : MockHttpServletRequest;
import flint.test.web.servlet : RequestBuilder;

@safe:

/// `MockHttpServletRequestBuilder`.
final class MockHttpServletRequestBuilder : RequestBuilder
{
    private string method;
    private string rawPath;
    private string rawQuery;
    private string contextPathValue = "";
    private string servletPathValue = "";
    private string[2][] headers;
    private string[2][] parameters;
    private string[2][] queryParameters;
    private const(ubyte)[] contentValue;
    private string contentTypeValue;
    private string characterEncodingValue;
    private Cookie[] cookies;
    private Any[string] attributes;
    private string[] attributeOrder;
    private bool secureValue;

    ///
    this(string method, string url)
    {
        this.method = method;
        size_t q = url.length;
        foreach (i, c; url)
            if (c == '?')
            {
                q = i;
                break;
            }
        string path = url[0 .. q];
        rawQuery = q < url.length ? url[q + 1 .. $] : null;
        // An absolute URL keeps only its path.
        foreach (i; 0 .. path.length)
            if (i + 3 <= path.length && path[i .. i + 3] == "://")
            {
                const slash = indexOf(path, '/', i + 3);
                path = slash < 0 ? "/" : path[slash .. $];
                break;
            }
        rawPath = path;
    }

    private static ptrdiff_t indexOf(string text, char c, size_t from) pure nothrow @nogc
    {
        foreach (i; from .. text.length)
            if (text[i] == c)
                return i;
        return -1;
    }

    /// Adds a request parameter.
    MockHttpServletRequestBuilder param(string name, string[] values...)
    {
        foreach (value; values)
            parameters ~= [name, value];
        return this;
    }

    /// Adds a query parameter (also appended to the query string).
    MockHttpServletRequestBuilder queryParam(string name, string[] values...)
    {
        foreach (value; values)
            queryParameters ~= [name, value];
        return this;
    }

    /// Adds a header.
    MockHttpServletRequestBuilder header(string name, string[] values...)
    {
        foreach (value; values)
            headers ~= [name, value];
        return this;
    }

    /// Sets `Accept`.
    MockHttpServletRequestBuilder accept(MediaType[] mediaTypes...)
    {
        return header(HttpHeaders.ACCEPT, MediaType.toString(mediaTypes));
    }

    /// Sets `Accept` from text.
    MockHttpServletRequestBuilder accept(string[] mediaTypes...)
    {
        string joined;
        foreach (i, m; mediaTypes)
            joined ~= (i == 0 ? "" : ", ") ~ m;
        return header(HttpHeaders.ACCEPT, joined);
    }

    /// Sets the content type.
    MockHttpServletRequestBuilder contentType(MediaType contentType)
    {
        contentTypeValue = contentType.toString();
        return this;
    }

    /// ditto
    MockHttpServletRequestBuilder contentType(string contentType)
    {
        contentTypeValue = contentType;
        return this;
    }

    /// Sets the body.
    MockHttpServletRequestBuilder content(string content)
    {
        contentValue = cast(const(ubyte)[]) content;
        return this;
    }

    /// ditto
    MockHttpServletRequestBuilder content(const(ubyte)[] content)
    {
        contentValue = content;
        return this;
    }

    /// Sets the character encoding.
    MockHttpServletRequestBuilder characterEncoding(string encoding)
    {
        characterEncodingValue = encoding;
        return this;
    }

    /// Adds cookies.
    MockHttpServletRequestBuilder cookie(Cookie[] cookies...)
    {
        this.cookies ~= cookies;
        return this;
    }

    /// Sets a request attribute.
    MockHttpServletRequestBuilder requestAttr(string name, Any value)
    {
        if (name !in attributes)
            attributeOrder ~= name;
        attributes[name] = value;
        return this;
    }

    /// Sets the context path.
    MockHttpServletRequestBuilder contextPath(string contextPath)
    {
        contextPathValue = contextPath;
        return this;
    }

    /// Sets the servlet path.
    MockHttpServletRequestBuilder servletPath(string servletPath)
    {
        servletPathValue = servletPath;
        return this;
    }

    /// Marks the request secure (`https`).
    MockHttpServletRequestBuilder secure(bool secure)
    {
        secureValue = secure;
        return this;
    }

    MockHttpServletRequest buildRequest(ServletContext servletContext)
    {
        auto request = new MockHttpServletRequest(method, rawPath);
        request.setContextPath(contextPathValue);
        request.setServletPath(servletPathValue);
        if (secureValue)
        {
            request.setScheme("https");
            request.setServerPort(443);
        }
        string query = rawQuery;
        foreach (pair; queryParameters)
            query = (query.length != 0 ? query ~ "&" : "") ~ encodeQuery(pair[0]) ~ "=" ~ encodeQuery(pair[1]);
        request.setQueryString(query);
        foreach (pair; parseQuery(query))
            request.addParameter(pair[0], pair[1]);
        foreach (pair; parameters)
            request.addParameter(pair[0], pair[1]);
        foreach (pair; headers)
            request.addHeader(pair[0], pair[1]);
        if (contentTypeValue !is null)
            request.setContentType(contentTypeValue);
        if (characterEncodingValue !is null)
            request.setCharacterEncoding(characterEncodingValue);
        if (contentValue !is null)
        {
            request.setContent(contentValue);
            if (request.getHeader(HttpHeaders.CONTENT_LENGTH) is null)
            {
                import std.conv : to;

                request.addHeader(HttpHeaders.CONTENT_LENGTH, contentValue.length.to!string);
            }
        }
        if (cookies.length != 0)
            request.setCookies(cookies);
        foreach (name; attributeOrder)
            request.setAttribute(name, attributes[name]);
        return request;
    }

    private static string[2][] parseQuery(string query)
    {
        string[2][] result;
        if (query.length == 0)
            return result;
        size_t start;
        foreach (i; 0 .. query.length + 1)
        {
            if (i == query.length || query[i] == '&')
            {
                auto pair = query[start .. i];
                start = i + 1;
                if (pair.length == 0)
                    continue;
                ptrdiff_t eq = indexOf(pair, '=', 0);
                // UriComponentsBuilder: a name without '=' has a null value, which MockMvc skips.
                if (eq < 0)
                {
                    result ~= [decode(pair), ""];
                    continue;
                }
                result ~= [decode(pair[0 .. eq]), decode(pair[eq + 1 .. $])];
            }
        }
        return result;
    }

    // UriUtils.decode(value, UTF_8): %XX sequences become bytes; '+' stays '+' (it is not form decoding).
    private static string decode(string text)
    {
        char[] result;
        for (size_t i = 0; i < text.length; i++)
        {
            if (text[i] == '%' && i + 2 < text.length && isHex(text[i + 1]) && isHex(text[i + 2]))
            {
                result ~= cast(char)(hex(text[i + 1]) * 16 + hex(text[i + 2]));
                i += 2;
            }
            else
                result ~= text[i];
        }
        return result.idup;
    }

    private static string encodeQuery(string text)
    {
        static immutable digits = "0123456789ABCDEF";
        char[] result;
        foreach (char c; text)
        {
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-'
                    || c == '.' || c == '_' || c == '~')
                result ~= c;
            else
            {
                result ~= '%';
                result ~= digits[c >> 4];
                result ~= digits[c & 15];
            }
        }
        return result.idup;
    }

    private static bool isHex(char c) pure nothrow @nogc
    {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }

    private static int hex(char c) pure nothrow @nogc
    {
        return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;
    }
}

/// `MockMvcRequestBuilders`: static factory methods for requests.
struct MockMvcRequestBuilders
{
    /// GET `uriTemplate`, with `{}` variables expanded in order.
    static MockHttpServletRequestBuilder get(Args...)(string uriTemplate, Args uriVariables)
    {
        return request!Args("GET", uriTemplate, uriVariables);
    }

    /// POST.
    static MockHttpServletRequestBuilder post(Args...)(string uriTemplate, Args uriVariables)
    {
        return request!Args("POST", uriTemplate, uriVariables);
    }

    /// PUT.
    static MockHttpServletRequestBuilder put(Args...)(string uriTemplate, Args uriVariables)
    {
        return request!Args("PUT", uriTemplate, uriVariables);
    }

    /// PATCH.
    static MockHttpServletRequestBuilder patch(Args...)(string uriTemplate, Args uriVariables)
    {
        return request!Args("PATCH", uriTemplate, uriVariables);
    }

    /// DELETE.
    static MockHttpServletRequestBuilder delete_(Args...)(string uriTemplate, Args uriVariables)
    {
        return request!Args("DELETE", uriTemplate, uriVariables);
    }

    /// OPTIONS.
    static MockHttpServletRequestBuilder options(Args...)(string uriTemplate, Args uriVariables)
    {
        return request!Args("OPTIONS", uriTemplate, uriVariables);
    }

    /// HEAD.
    static MockHttpServletRequestBuilder head(Args...)(string uriTemplate, Args uriVariables)
    {
        return request!Args("HEAD", uriTemplate, uriVariables);
    }

    /// Any method.
    static MockHttpServletRequestBuilder request(Args...)(HttpMethod method, string uriTemplate, Args uriVariables)
    {
        return request!Args(method.name(), uriTemplate, uriVariables);
    }

    /// ditto, by name.
    static MockHttpServletRequestBuilder request(Args...)(string method, string uriTemplate, Args uriVariables)
    {
        import std.conv : to;

        string[] values;
        foreach (v; uriVariables)
            values ~= v.to!string;
        return new MockHttpServletRequestBuilder(method, expand(uriTemplate, values));
    }

    private static string expand(string template_, string[] values)
    {
        string result;
        size_t next;
        for (size_t i = 0; i < template_.length; i++)
        {
            if (template_[i] == '{')
            {
                size_t close = i;
                while (close < template_.length && template_[close] != '}')
                    close++;
                if (close < template_.length && next < values.length)
                {
                    result ~= encodePathSegment(values[next++]);
                    i = close;
                    continue;
                }
            }
            result ~= template_[i];
        }
        return result;
    }

    private static string encodePathSegment(string text)
    {
        static immutable digits = "0123456789ABCDEF";
        char[] result;
        foreach (char c; text)
        {
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-'
                    || c == '.' || c == '_' || c == '~' || c == '!' || c == '$' || c == '&' || c == '\''
                    || c == '(' || c == ')' || c == '*' || c == '+' || c == ',' || c == ';'
                    || c == '=' || c == ':' || c == '@')
                result ~= c;
            else
            {
                result ~= '%';
                result ~= digits[c >> 4];
                result ~= digits[c & 15];
            }
        }
        return result.idup;
    }
}
