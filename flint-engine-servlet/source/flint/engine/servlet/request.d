/++
The servlet engine's `HttpServletRequest`: a GC copy of one `flint.engine.web` request.

The engine copies the request line, every field and the body out of the request arena in two allocations before
the servlet runs, so no arena memory reaches application code (ADR-030 section 4). Everything a getter returns is
a slice of that copy or a value derived from it. The behaviour follows Tomcat's `org.apache.catalina.connector.Request`
as Spring Boot 4.2.0 runs it: parameters come from the query string, decoded as UTF-8 with `+` as a space, and from
an `application/x-www-form-urlencoded` body; the servlet mapped at `/` sees the whole path as its servlet path.
+/
module flint.engine.servlet.request;

import flint.engine.aot.any : Any;
import flint.engine.web.types : Method;
import flint.jakarta.servlet : DispatcherType, RequestDispatcher, ServletContext,
    ServletInputStream, ServletRequest, ServletResponse;
import flint.jakarta.servlet.http : Cookie, HttpServletRequest;
import flint.java.lang : IllegalArgumentException, IllegalStateException, NumberFormatException;

@safe:

/// What a request reads from its engine: the servlet context, the listener and a dispatcher factory.
package(flint.engine.servlet) interface RequestHost
{
    ServletContext context();
    string localAddress();
    int localPort();
    RequestDispatcher dispatcher(string path);
}

/// The request a servlet sees for one exchange on the servlet engine.
final class ServletEngineRequest : HttpServletRequest
{
    private RequestHost host;
    private string method;
    private string requestURI;
    private string queryString;
    private string protocol;
    private string servletPath;
    private string contextPath;
    private string[] names;
    private string[] values;
    private immutable(ubyte)[] content;
    private string requestId;
    private DispatcherType dispatcherType = DispatcherType.REQUEST;
    private Any[string] attributes;
    private string[] attributeOrder;
    private string characterEncoding;
    private string[][string] parameters;
    private string[] parameterOrder;
    private bool parametersParsed;
    private bool inputUsed;

    package(flint.engine.servlet) this(RequestHost host, string method, string requestURI, string queryString,
            string protocol, string contextPath, string[] names, string[] values,
            immutable(ubyte)[] content, string requestId)
    {
        this.host = host;
        this.method = method;
        this.requestURI = requestURI;
        this.queryString = queryString;
        this.protocol = protocol;
        this.contextPath = contextPath;
        this.servletPath = requestURI.length >= contextPath.length ? requestURI[contextPath.length .. $] : requestURI;
        this.names = names;
        this.values = values;
        this.content = content;
        this.requestId = requestId;
    }

    /// Change the path the request reports, as a forward or error dispatch does; returns the previous state.
    package(flint.engine.servlet) DispatchState redirect(string uri, string query, DispatcherType type)
    {
        auto previous = DispatchState(requestURI, servletPath, queryString, dispatcherType);
        requestURI = contextPath ~ uri;
        servletPath = uri;
        queryString = query;
        dispatcherType = type;
        return previous;
    }

    /// Restore the state `redirect` returned.
    package(flint.engine.servlet) void restore(DispatchState state)
    {
        requestURI = state.requestURI;
        servletPath = state.servletPath;
        queryString = state.queryString;
        dispatcherType = state.dispatcherType;
    }

    // ServletRequest

    Any getAttribute(string name)
    {
        if (auto value = name in attributes)
            return *value;
        return Any.init;
    }

    string[] getAttributeNames()
    {
        return attributeOrder.dup;
    }

    string getCharacterEncoding()
    {
        if (characterEncoding !is null)
            return characterEncoding;
        return charsetOf(getContentType());
    }

    void setCharacterEncoding(string env)
    {
        if (!parametersParsed && !inputUsed)
            characterEncoding = env;
    }

    int getContentLength()
    {
        const length = getContentLengthLong();
        return length > int.max ? -1 : cast(int) length;
    }

    long getContentLengthLong()
    {
        const text = getHeader("content-length");
        if (text is null)
            return content.length != 0 ? cast(long) content.length : -1;
        long value;
        foreach (c; text)
        {
            if (c < '0' || c > '9')
                return -1;
            value = value * 10 + (c - '0');
        }
        return value;
    }

    string getContentType()
    {
        return getHeader("content-type");
    }

    ServletInputStream getInputStream()
    {
        inputUsed = true;
        return new BodyInput(content);
    }

    string getParameter(string name)
    {
        parseParameters();
        if (auto list = name in parameters)
            return (*list).length != 0 ? (*list)[0] : null;
        return null;
    }

    string[] getParameterNames()
    {
        parseParameters();
        return parameterOrder.dup;
    }

    string[] getParameterValues(string name)
    {
        parseParameters();
        if (auto list = name in parameters)
            return (*list).dup;
        return null;
    }

    string[][string] getParameterMap()
    {
        parseParameters();
        string[][string] copy;
        foreach (name; parameterOrder)
            copy[name] = parameters[name].dup;
        return copy;
    }

    string getProtocol()
    {
        return protocol;
    }

    string getScheme()
    {
        return "http";
    }

    string getServerName()
    {
        const authority = getHeader("host");
        if (authority is null || authority.length == 0)
            return host.localAddress();
        if (authority[0] == '[')
        {
            foreach (index, c; authority)
                if (c == ']')
                    return authority[0 .. index + 1];
            return authority;
        }
        foreach (index, c; authority)
            if (c == ':')
                return authority[0 .. index];
        return authority;
    }

    int getServerPort()
    {
        const authority = getHeader("host");
        if (authority is null || authority.length == 0)
            return host.localPort();
        size_t colon = size_t.max;
        foreach (index, c; authority)
        {
            if (c == ']')
                colon = size_t.max;
            else if (c == ':')
                colon = index;
        }
        if (colon == size_t.max)
            return 80;
        int port;
        foreach (c; authority[colon + 1 .. $])
        {
            if (c < '0' || c > '9' || port > 65_535)
                return 80;
            port = port * 10 + (c - '0');
        }
        return port;
    }

    /// The engine does not expose the peer address yet; `null`, as for a request without one.
    string getRemoteAddr()
    {
        return null;
    }

    /// ditto
    string getRemoteHost()
    {
        return null;
    }

    void setAttribute(string name, Any o)
    {
        if (o.isNull())
        {
            removeAttribute(name);
            return;
        }
        if ((name in attributes) is null)
            attributeOrder ~= name;
        attributes[name] = o;
    }

    /// `HttpServletRequest.removeAttribute`.
    void removeAttribute(string name)
    {
        if ((name in attributes) is null)
            return;
        attributes.remove(name);
        foreach (index, existing; attributeOrder)
        {
            if (existing == name)
            {
                attributeOrder = attributeOrder[0 .. index] ~ attributeOrder[index + 1 .. $];
                break;
            }
        }
    }

    /// `HttpServletRequest.isSecure`.
    bool isSecure()
    {
        return false;
    }

    RequestDispatcher getRequestDispatcher(string path)
    {
        if (path is null)
            return null;
        if (path.length == 0 || path[0] != '/')
        {
            // Relative to the current servlet path's directory.
            size_t slash;
            foreach (index, c; servletPath)
                if (c == '/')
                    slash = index;
            path = servletPath[0 .. slash + 1] ~ path;
        }
        return host.dispatcher(path);
    }

    /// See `getRemoteAddr`.
    int getRemotePort()
    {
        return -1;
    }

    string getLocalName()
    {
        return host.localAddress();
    }

    string getLocalAddr()
    {
        return host.localAddress();
    }

    int getLocalPort()
    {
        return host.localPort();
    }

    ServletContext getServletContext()
    {
        return host.context();
    }

    /// `HttpServletRequest.isAsyncSupported`.
    bool isAsyncSupported()
    {
        return false;
    }

    DispatcherType getDispatcherType()
    {
        return dispatcherType;
    }

    string getRequestId()
    {
        return requestId;
    }

    /// HTTP/1 has no protocol-level request id.
    string getProtocolRequestId()
    {
        return "";
    }

    // HttpServletRequest

    string getAuthType()
    {
        return null;
    }

    Cookie[] getCookies()
    {
        Cookie[] cookies;
        foreach (index, name; names)
        {
            if (name != "cookie")
                continue;
            foreach (pair; split(values[index], ';'))
            {
                const text = trim(pair);
                size_t equals = text.length;
                foreach (position, c; text)
                {
                    if (c == '=')
                    {
                        equals = position;
                        break;
                    }
                }
                if (equals == 0 || equals == text.length)
                    continue;
                auto value = text[equals + 1 .. $];
                if (value.length >= 2 && value[0] == '"' && value[$ - 1] == '"')
                    value = value[1 .. $ - 1];
                try
                    cookies ~= new Cookie(text[0 .. equals], value);
                catch (IllegalArgumentException)
                {
                    // Tomcat drops a cookie whose name is not a token.
                }
            }
        }
        return cookies.length != 0 ? cookies : null;
    }

    long getDateHeader(string name)
    {
        const text = getHeader(name);
        if (text is null)
            return -1;
        const parsed = parseHttpDate(text);
        if (parsed == long.min)
            throw new IllegalArgumentException(text);
        return parsed;
    }

    string getHeader(string name)
    {
        foreach (index, existing; names)
            if (equalsIgnoreCase(existing, name))
                return values[index];
        return null;
    }

    string[] getHeaders(string name)
    {
        string[] found;
        foreach (index, existing; names)
            if (equalsIgnoreCase(existing, name))
                found ~= values[index];
        return found;
    }

    string[] getHeaderNames()
    {
        string[] distinct;
        outer: foreach (name; names)
        {
            foreach (seen; distinct)
                if (seen == name)
                    continue outer;
            distinct ~= name;
        }
        return distinct;
    }

    int getIntHeader(string name)
    {
        const text = getHeader(name);
        if (text is null)
            return -1;
        long value;
        const negative = text.length != 0 && text[0] == '-';
        const digits = negative ? text[1 .. $] : text;
        if (digits.length == 0)
            throw new NumberFormatException("For input string: \"" ~ text ~ "\"");
        foreach (c; digits)
        {
            if (c < '0' || c > '9' || value > int.max)
                throw new NumberFormatException("For input string: \"" ~ text ~ "\"");
            value = value * 10 + (c - '0');
        }
        value = negative ? -value : value;
        if (value > int.max || value < int.min)
            throw new NumberFormatException("For input string: \"" ~ text ~ "\"");
        return cast(int) value;
    }

    string getMethod()
    {
        return method;
    }

    /// The servlet mapped at `/` has no path info.
    string getPathInfo()
    {
        return null;
    }

    string getPathTranslated()
    {
        return null;
    }

    string getContextPath()
    {
        return contextPath;
    }

    string getQueryString()
    {
        return queryString;
    }

    string getRemoteUser()
    {
        return null;
    }

    /// `HttpServletRequest.isUserInRole`.
    bool isUserInRole(string)
    {
        return false;
    }

    string getRequestedSessionId()
    {
        return null;
    }

    string getRequestURI()
    {
        return requestURI;
    }

    string getRequestURL()
    {
        const port = getServerPort();
        const name = getServerName();
        return port == 80 ? "http://" ~ name ~ requestURI : "http://" ~ name ~ ":" ~ decimal(port) ~ requestURI;
    }

    string getServletPath()
    {
        return servletPath;
    }

    /// `HttpServletRequest.isRequestedSessionIdValid`.
    bool isRequestedSessionIdValid()
    {
        return false;
    }

    private void parseParameters()
    {
        if (parametersParsed)
            return;
        parametersParsed = true;
        addParameters(queryString);
        if (method == "POST" && !inputUsed && content.length != 0)
        {
            const type = getContentType();
            if (type !is null && equalsIgnoreCase(trim(split(type, ';')[0]), "application/x-www-form-urlencoded"))
                addParameters(cast(string) content);
        }
    }

    private void addParameters(string text)
    {
        if (text.length == 0)
            return;
        foreach (pair; split(text, '&'))
        {
            if (pair.length == 0)
                continue;
            size_t equals = pair.length;
            foreach (index, c; pair)
            {
                if (c == '=')
                {
                    equals = index;
                    break;
                }
            }
            const name = decodeComponent(pair[0 .. equals]);
            const value = equals < pair.length ? decodeComponent(pair[equals + 1 .. $]) : "";
            // Tomcat skips a parameter whose name or value is not valid percent-encoding.
            if (name is null || value is null || name.length == 0)
                continue;
            if (auto list = name in parameters)
                *list ~= value;
            else
            {
                parameters[name] = [value];
                parameterOrder ~= name;
            }
        }
    }
}

/// The path state a dispatch replaces.
package(flint.engine.servlet) struct DispatchState
{
    string requestURI;
    string servletPath;
    string queryString;
    DispatcherType dispatcherType;
}

/// The request method as a servlet sees it.
package(flint.engine.servlet) string methodName(Method method) pure nothrow @nogc
{
    final switch (method)
    {
    case Method.get:
        return "GET";
    case Method.post:
        return "POST";
    case Method.put:
        return "PUT";
    case Method.patch:
        return "PATCH";
    case Method.delete_:
        return "DELETE";
    case Method.head:
        return "HEAD";
    case Method.options:
        return "OPTIONS";
    }
}

private final class BodyInput : ServletInputStream
{
    private immutable(ubyte)[] content;
    private size_t position;

    this(immutable(ubyte)[] content) pure nothrow @nogc
    {
        this.content = content;
    }

    override int read()
    {
        return position < content.length ? content[position++] : -1;
    }

    override ubyte[] readAllBytes()
    {
        auto rest = content[position .. $].dup;
        position = content.length;
        return rest;
    }

    override bool isFinished()
    {
        return position >= content.length;
    }

    override bool isReady()
    {
        return true;
    }
}

/// Decode `application/x-www-form-urlencoded` text: `+` is a space and `%XX` a byte. `null` when malformed.
package(flint.engine.servlet) string decodeComponent(string text) pure nothrow
{
    bool plain = true;
    foreach (c; text)
        if (c == '%' || c == '+')
            plain = false;
    if (plain)
        return text;
    auto output = new char[text.length];
    size_t length;
    for (size_t index; index < text.length; ++index)
    {
        const c = text[index];
        if (c == '+')
            output[length++] = ' ';
        else if (c == '%')
        {
            if (index + 2 >= text.length)
                return null;
            const high = hexValue(text[index + 1]);
            const low = hexValue(text[index + 2]);
            if (high < 0 || low < 0)
                return null;
            output[length++] = cast(char)(high * 16 + low);
            index += 2;
        }
        else
            output[length++] = c;
    }
    return output[0 .. length].idup;
}

private int hexValue(char c) pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/// The `charset` parameter of a media type, or `null`.
package(flint.engine.servlet) string charsetOf(string contentType) pure nothrow
{
    if (contentType is null)
        return null;
    foreach (parameter; split(contentType, ';')[1 .. $])
    {
        const text = trim(parameter);
        if (text.length > 8 && equalsIgnoreCase(text[0 .. 8], "charset="))
        {
            auto value = trim(text[8 .. $]);
            if (value.length >= 2 && value[0] == '"' && value[$ - 1] == '"')
                value = value[1 .. $ - 1];
            return value;
        }
    }
    return null;
}

/// Parse an IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`) into milliseconds since the epoch; `long.min` if not one.
package(flint.engine.servlet) long parseHttpDate(string text) pure nothrow @nogc
{
    static immutable string months = "JanFebMarAprMayJunJulAugSepOctNovDec";
    if (text.length != 29 || text[3 .. 5] != ", " || text[25 .. 29] != " GMT")
        return long.min;
    int number(size_t from, size_t count)
    {
        int value;
        foreach (c; text[from .. from + count])
        {
            if (c < '0' || c > '9')
                return -1;
            value = value * 10 + (c - '0');
        }
        return value;
    }

    const day = number(5, 2), year = number(12, 4), hour = number(17, 2), minute = number(20, 2),
        second = number(23, 2);
    int month = -1;
    foreach (index; 0 .. 12)
        if (text[8 .. 11] == months[index * 3 .. index * 3 + 3])
            month = index + 1;
    if (day < 1 || year < 0 || hour < 0 || minute < 0 || second < 0 || month < 0)
        return long.min;
    // Civil date to days since the epoch (H. Hinnant).
    const y = month <= 2 ? year - 1 : year;
    const era = (y >= 0 ? y : y - 399) / 400;
    const yearOfEra = y - era * 400;
    const dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
    const dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
    const days = cast(long) era * 146_097 + dayOfEra - 719_468;
    return ((days * 24 + hour) * 60 + minute) * 60_000L + second * 1000L;
}

package(flint.engine.servlet) bool equalsIgnoreCase(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (index, c; a)
    {
        const x = c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
        const y = b[index] >= 'A' && b[index] <= 'Z' ? cast(char)(b[index] + 32) : b[index];
        if (x != y)
            return false;
    }
    return true;
}

package(flint.engine.servlet) string[] split(string text, char separator) pure nothrow
{
    string[] parts;
    size_t start;
    foreach (index, c; text)
    {
        if (c == separator)
        {
            parts ~= text[start .. index];
            start = index + 1;
        }
    }
    parts ~= text[start .. $];
    return parts;
}

package(flint.engine.servlet) string trim(string text) pure nothrow @nogc
{
    size_t first, last = text.length;
    while (first < last && (text[first] == ' ' || text[first] == '\t'))
        ++first;
    while (last > first && (text[last - 1] == ' ' || text[last - 1] == '\t'))
        --last;
    return text[first .. last];
}

package(flint.engine.servlet) string decimal(long value) pure nothrow
{
    if (value == 0)
        return "0";
    char[20] digits;
    size_t first = digits.length;
    const negative = value < 0;
    ulong magnitude = negative ? -cast(ulong) value : cast(ulong) value;
    while (magnitude != 0)
    {
        digits[--first] = cast(char)('0' + magnitude % 10);
        magnitude /= 10;
    }
    return (negative ? "-" : "") ~ digits[first .. $].idup;
}

@("form decoding treats + as a space, decodes UTF-8 percent bytes and rejects malformed escapes")
unittest
{
    assert(decodeComponent("Jane+Q%20Public") == "Jane Q Public");
    assert(decodeComponent("%C3%A9t%C3%A9") == "été");
    assert(decodeComponent("%22quoted%22%5Cslash%3C%3E") == `"quoted"\slash<>`);
    assert(decodeComponent("plain") == "plain");
    assert(decodeComponent("bad%2") is null);
    assert(decodeComponent("bad%zz") is null);
    assert(decodeComponent("%") is null);
}

@("IMF-fixdate parsing matches the RFC example and rejects other forms")
unittest
{
    assert(parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT") == 784_111_777_000L);
    assert(parseHttpDate("Thu, 01 Jan 1970 00:00:00 GMT") == 0);
    assert(parseHttpDate("Tue, 29 Feb 2000 00:00:00 GMT") == 951_782_400_000L);
    assert(parseHttpDate("Sunday, 06-Nov-94 08:49:37 GMT") == long.min);
    assert(parseHttpDate("Sun, 06 Nov 1994 08:49:37 UTC") == long.min);
}

@("charset parameters are found in any case and unquoted")
unittest
{
    assert(charsetOf("text/html;charset=UTF-8") == "UTF-8");
    assert(charsetOf("text/plain; Charset=\"iso-8859-1\"") == "iso-8859-1");
    assert(charsetOf("application/json") is null);
    assert(charsetOf(null) is null);
}
