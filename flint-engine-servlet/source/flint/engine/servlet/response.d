/++
The servlet engine's `HttpServletResponse`, with Tomcat's commit and framing rules.

The body is buffered in GC memory, 8 KiB by default as in Tomcat. Committing (`flushBuffer`, a full buffer)
sends the status and fields with `Content-Length` when the application set one, and chunked framing otherwise.
A response that is never committed is sent whole with `Content-Length` when the exchange ends, so an empty one
carries `Content-Length: 0`. The fields go out in Tomcat's order: the application's in insertion order, then
`Content-Type` and `Content-Language`; the engine adds the framing field, `Date` and the connection fields.

`sendError` records the status and message, clears the buffer and suspends output, as Tomcat's does; the engine
then dispatches to the error page. From the application's side the response then reports itself committed, as
Tomcat's `ResponseFacade` does, so later status and field changes are ignored.
+/
module flint.engine.servlet.response;

import flint.arena : Status, TransportError = Error;
import flint.conc : Context;
import flint.engine.servlet.request : charsetOf, decimal, equalsIgnoreCase, splitter, trim;
import flint.engine.web.fiber : FiberResponse, unknownLength;
import flint.engine.web.stream : StreamField;
import flint.jakarta.servlet : ServletOutputStream;
import flint.jakarta.servlet.http : Cookie, HttpServletResponse;
import flint.java.io : IOException, PrintWriter, Writer;
import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.java.util : Locale;

@safe:

/// Tomcat's default response buffer: `org.apache.catalina.connector.OutputBuffer` holds 8 KiB.
enum int defaultBufferSize = 8192;

/// The response a servlet sees for one exchange on the servlet engine.
final class ServletEngineResponse : HttpServletResponse
{
    private FiberResponse transport;
    private int status = SC_OK;
    private string message;
    private string[] headerNames;
    private string[] headerValues;
    private string contentType;
    private string characterEncoding;
    private bool characterEncodingSet;
    private string contentLanguage;
    private Locale locale;
    private bool localeSet;
    private long contentLength = -1;
    private ubyte[] buffer;
    private int bufferSize = defaultBufferSize;
    private bool committed;
    private ulong written;
    private bool suspended;
    private bool error;
    private bool finished;
    private bool usingStream;
    private bool usingWriter;
    private ServletOutputStream stream;
    private PrintWriter writer;

    package(flint.engine.servlet) this(FiberResponse transport)
    {
        this.transport = transport;
    }

    /// Whether `sendError` was called and the error page has not run yet.
    package(flint.engine.servlet) bool isError() const pure nothrow @nogc
    {
        return error;
    }

    /// The message `sendError` recorded.
    package(flint.engine.servlet) string getErrorMessage() const pure nothrow @nogc
    {
        return message;
    }

    /// Mark the response failed with `status`, as Tomcat's `StandardWrapperValve` does for an uncaught exception.
    package(flint.engine.servlet) void setErrorStatus(int status) pure nothrow @nogc
    {
        this.status = status;
        error = true;
    }

    /// Whether the status line has been sent.
    package(flint.engine.servlet) bool isWireCommitted() const pure nothrow @nogc
    {
        return committed;
    }

    /// Prepare for the error page: keep the status, message and fields, clear the body and resume output, as
    /// Tomcat's `StandardHostValve.custom` does before it forwards.
    package(flint.engine.servlet) void prepareErrorPage()
    {
        error = false;
        suspended = false;
        buffer = null;
        written = 0;
        contentLength = -1;
        usingStream = false;
        usingWriter = false;
        stream = null;
        writer = null;
    }

    /// End the exchange: send what is buffered and finish the body. Throws `IOException` when the client is gone.
    package(flint.engine.servlet) void complete()
    {
        if (finished)
            return;
        finished = true;
        Context context;
        if (!committed)
        {
            const length = contentLength >= 0 ? contentLength : cast(long) buffer.length;
            if (length == buffer.length)
            {
                check(transport.respond(cast(ushort) status, fields(), buffer, false, context));
                committed = true;
                return;
            }
            commit();
        }
        if (buffer.length != 0)
            check(transport.send(buffer, context));
        buffer = null;
        check(transport.finish(context));
    }

    // ServletResponse

    string getCharacterEncoding()
    {
        return characterEncoding is null ? "ISO-8859-1" : characterEncoding;
    }

    string getContentType()
    {
        if (contentType is null)
            return null;
        return characterEncodingSet && characterEncoding !is null
            ? contentType ~ ";charset=" ~ characterEncoding : contentType;
    }

    ServletOutputStream getOutputStream()
    {
        if (usingWriter)
            throw new IllegalStateException("getWriter() has already been called for this response");
        usingStream = true;
        if (stream is null)
            stream = new BodyOutput(this);
        return stream;
    }

    PrintWriter getWriter()
    {
        if (usingStream)
            throw new IllegalStateException("getOutputStream() has already been called for this response");
        if (!usingWriter && !characterEncodingSet && !appCommitted())
        {
            // Tomcat fixes the encoding when the writer is obtained (ENFORCE_ENCODING_IN_GET_WRITER).
            characterEncoding = getCharacterEncoding();
            characterEncodingSet = true;
        }
        usingWriter = true;
        if (writer is null)
            writer = new PrintWriter(new BodyWriter(this));
        return writer;
    }

    void setCharacterEncoding(string charset)
    {
        if (appCommitted() || usingWriter)
            return;
        characterEncoding = charset;
        characterEncodingSet = charset !is null;
    }

    void setContentLength(int len)
    {
        setContentLengthLong(len);
    }

    void setContentLengthLong(long len)
    {
        if (appCommitted())
            return;
        contentLength = len < 0 ? -1 : len;
    }

    void setContentType(string type)
    {
        if (appCommitted())
            return;
        if (type is null)
        {
            contentType = null;
            if (!usingWriter)
            {
                characterEncoding = null;
                characterEncodingSet = false;
            }
            return;
        }
        // Tomcat keeps the media type and its other parameters, and moves the charset to the encoding.
        auto parts = splitter(type, ';');
        string kept = trim(parts.front);
        parts.popFront();
        foreach (parameter; parts)
        {
            const text = trim(parameter);
            if (text.length > 8 && equalsIgnoreCase(text[0 .. 8], "charset="))
                continue;
            if (text.length != 0)
                kept ~= ";" ~ text;
        }
        contentType = kept;
        const charset = charsetOf(type);
        if (charset !is null && !usingWriter)
        {
            characterEncoding = charset;
            characterEncodingSet = true;
        }
    }

    void setBufferSize(int size)
    {
        if (committed || buffer.length != 0)
            throw new IllegalStateException("Cannot change buffer size after data has been written");
        bufferSize = size > 0 ? size : defaultBufferSize;
    }

    int getBufferSize()
    {
        return bufferSize;
    }

    /// `HttpServletResponse.flushBuffer`.
    void flushBuffer()
    {
        if (suspended)
            return;
        Context context;
        if (!committed)
            commit();
        if (buffer.length != 0)
        {
            check(transport.send(buffer, context));
            buffer = null;
        }
    }

    /// `HttpServletResponse.resetBuffer`.
    void resetBuffer()
    {
        if (committed)
            throw new IllegalStateException("Cannot reset buffer after response has been committed");
        buffer = null;
        written = 0;
    }

    /// `HttpServletResponse.isCommitted`.
    bool isCommitted()
    {
        return appCommitted();
    }

    /// `HttpServletResponse.reset`.
    void reset()
    {
        if (committed)
            throw new IllegalStateException("Cannot reset buffer after response has been committed");
        status = SC_OK;
        message = null;
        headerNames = null;
        headerValues = null;
        contentType = null;
        contentLanguage = null;
        localeSet = false;
        contentLength = -1;
        characterEncoding = null;
        characterEncodingSet = false;
        buffer = null;
        usingStream = false;
        usingWriter = false;
        stream = null;
        writer = null;
    }

    // HttpServletResponse

    /// `HttpServletResponse.addCookie`.
    void addCookie(Cookie cookie)
    {
        if (appCommitted())
            return;
        string text = cookie.getName() ~ "=" ~ cookie.getValue();
        foreach (attribute; cookie.getAttributes())
            text ~= attribute[1].length != 0 ? "; " ~ attribute[0] ~ "=" ~ attribute[1] : "; " ~ attribute[0];
        addHeader("Set-Cookie", text);
    }

    /// `HttpServletResponse.containsHeader`.
    bool containsHeader(string name)
    {
        if (equalsIgnoreCase(name, "content-type"))
            return contentType !is null;
        if (equalsIgnoreCase(name, "content-length"))
            return contentLength != -1;
        foreach (existing; headerNames)
            if (equalsIgnoreCase(existing, name))
                return true;
        return false;
    }

    /// No sessions: URLs are returned unchanged.
    string encodeURL(string url)
    {
        return url;
    }

    /// ditto
    string encodeRedirectURL(string url)
    {
        return url;
    }

    /// `HttpServletResponse.sendError`.
    void sendError(int sc, string msg)
    {
        if (appCommitted())
            throw new IllegalStateException("Cannot call sendError() after the response has been committed");
        error = true;
        status = sc;
        message = msg;
        buffer = null;
        written = 0;
        suspended = true;
    }

    /// `HttpServletResponse.sendError`.
    void sendError(int sc)
    {
        sendError(sc, null);
    }

    /// `HttpServletResponse.sendRedirect`.
    void sendRedirect(string location)
    {
        if (appCommitted())
            throw new IllegalStateException("Cannot call sendRedirect() after the response has been committed");
        buffer = null;
        status = SC_FOUND;
        setHeader("Location", location);
        suspended = true;
    }

    void setDateHeader(string name, long date)
    {
        setHeader(name, httpDate(date));
    }

    /// `HttpServletResponse.addDateHeader`.
    void addDateHeader(string name, long date)
    {
        addHeader(name, httpDate(date));
    }

    void setHeader(string name, string value)
    {
        if (name is null || name.length == 0 || appCommitted())
            return;
        if (special(name, value))
            return;
        // D cannot tell an empty string from null, and Spring writes empty values (`Accept-Patch:` from
        // HttpOptionsHandler) as empty joins: a null value is the empty field value here (rulebook R14).
        if (value is null)
            value = "";
        // Tomcat's MimeHeaders.setValue keeps the first field's position and drops the others.
        foreach (index, existing; headerNames)
        {
            if (!equalsIgnoreCase(existing, name))
                continue;
            headerValues[index] = value;
            size_t next = index + 1;
            while (next < headerNames.length)
            {
                if (equalsIgnoreCase(headerNames[next], name))
                {
                    headerNames = headerNames[0 .. next] ~ headerNames[next + 1 .. $];
                    headerValues = headerValues[0 .. next] ~ headerValues[next + 1 .. $];
                }
                else
                    ++next;
            }
            return;
        }
        headerNames ~= name;
        headerValues ~= value;
    }

    /// `HttpServletResponse.addHeader`.
    void addHeader(string name, string value)
    {
        if (name is null || name.length == 0 || appCommitted())
            return;
        if (special(name, value))
            return;
        if (value is null)
            value = "";
        headerNames ~= name;
        headerValues ~= value;
    }

    void setIntHeader(string name, int value)
    {
        setHeader(name, decimal(value));
    }

    /// `HttpServletResponse.addIntHeader`.
    void addIntHeader(string name, int value)
    {
        addHeader(name, decimal(value));
    }

    void setStatus(int sc)
    {
        if (appCommitted())
            return;
        status = sc;
    }

    int getStatus()
    {
        return status;
    }

    string getHeader(string name)
    {
        if (equalsIgnoreCase(name, "content-type"))
            return getContentType();
        if (equalsIgnoreCase(name, "content-length"))
            return contentLength >= 0 ? decimal(contentLength) : null;
        foreach (index, existing; headerNames)
            if (equalsIgnoreCase(existing, name))
                return headerValues[index];
        return null;
    }

    string[] getHeaders(string name)
    {
        if (equalsIgnoreCase(name, "content-type") || equalsIgnoreCase(name, "content-length"))
        {
            const value = getHeader(name);
            return value is null ? null : [value];
        }
        string[] found;
        foreach (index, existing; headerNames)
            if (equalsIgnoreCase(existing, name))
                found ~= headerValues[index];
        return found;
    }

    string[] getHeaderNames()
    {
        string[] distinct;
        outer: foreach (name; headerNames)
        {
            foreach (seen; distinct)
                if (equalsIgnoreCase(seen, name))
                    continue outer;
            distinct ~= name;
        }
        if (contentType !is null)
            distinct ~= "Content-Type";
        if (contentLength >= 0)
            distinct ~= "Content-Length";
        return distinct;
    }

    /// `ServletResponse.setLocale`: `Content-Language` becomes the locale's language tag, which Tomcat writes
    /// after `Content-Type`. Tomcat's locale-to-charset mapping is not applied; Spring's views name their charset.
    void setLocale(Locale loc)
    {
        if (appCommitted())
            return;
        locale = loc;
        localeSet = true;
        contentLanguage = loc.toLanguageTag();
    }

    /// `ServletResponse.getLocale`: the last locale set, else the default locale.
    Locale getLocale()
    {
        return localeSet ? locale : Locale.getDefault();
    }

    // Body

    package(flint.engine.servlet) void write(scope const(ubyte)[] bytes)
    {
        if (suspended || finished || bytes.length == 0)
            return;
        buffer ~= bytes;
        written += bytes.length;
        if (buffer.length > bufferSize)
            flushBuffer();
    }

    private bool appCommitted() const pure nothrow @nogc
    {
        // Tomcat's Response.isAppCommitted: a response whose declared length has been written counts as committed.
        return committed || suspended || finished || (contentLength > 0 && written >= cast(ulong) contentLength);
    }

    private void commit()
    {
        Context context;
        check(transport.begin(cast(ushort) status, fields(), contentLength >= 0 ? contentLength : unknownLength,
                context));
        committed = true;
    }

    /// The fields in Tomcat's order. Framing and hop-by-hop fields belong to the engine and are left out.
    private StreamField[] fields() const
    {
        // One exact allocation; reserve and appends cost several times more per response.
        auto result = new StreamField[headerNames.length + 2];
        size_t used;
        foreach (index, name; headerNames)
        {
            if (hopByHop(name))
                continue;
            result[used++] = StreamField(name, headerValues[index]);
        }
        if (contentType !is null)
            result[used++] = StreamField("Content-Type", characterEncodingSet
                    && characterEncoding !is null ? contentType ~ ";charset=" ~ characterEncoding : contentType);
        if (contentLanguage !is null)
            result[used++] = StreamField("Content-Language", contentLanguage);
        return result[0 .. used];
    }

    /// `Content-Type` and `Content-Length` set as fields go to their own properties, as in Tomcat.
    private bool special(string name, string value)
    {
        if (equalsIgnoreCase(name, "content-type"))
        {
            setContentType(value);
            return true;
        }
        if (equalsIgnoreCase(name, "content-length"))
        {
            long length = -1;
            if (value !is null && value.length != 0)
            {
                length = 0;
                foreach (c; value)
                {
                    if (c < '0' || c > '9')
                        throw new IllegalArgumentException("Invalid Content-Length: " ~ value);
                    length = length * 10 + (c - '0');
                }
            }
            setContentLengthLong(length);
            return true;
        }
        return false;
    }

    private static void check(TransportError result)
    {
        if (result.code != Status.ok)
            throw new IOException("the client connection is no longer writable: " ~ result.message);
    }
}

private bool hopByHop(scope const(char)[] name) pure nothrow @nogc
{
    foreach (candidate; [
        "transfer-encoding", "connection", "keep-alive", "proxy-connection", "upgrade"
    ])
        if (equalsIgnoreCase(name, candidate))
            return true;
    return false;
}

/// Format milliseconds since the epoch as an IMF-fixdate.
private string httpDate(long millis) pure nothrow
{
    static immutable string weekdays = "ThuFriSatSunMonTueWed";
    static immutable string months = "JanFebMarAprMayJunJulAugSepOctNovDec";
    const seconds = millis / 1000;
    long days = seconds / 86_400;
    long clock = seconds % 86_400;
    if (clock < 0)
    {
        clock += 86_400;
        --days;
    }
    const weekday = cast(size_t)(((days % 7) + 7) % 7);
    const shifted = days + 719_468;
    const era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097;
    const dayOfEra = shifted - era * 146_097;
    const yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365;
    const dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
    const monthIndex = (5 * dayOfYear + 2) / 153;
    const day = dayOfYear - (153 * monthIndex + 2) / 5 + 1;
    const month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9;
    const year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0);
    string two(long value)
    {
        return [cast(char)('0' + value / 10 % 10), cast(char)('0' + value % 10)].idup;
    }

    return weekdays[weekday * 3 .. weekday * 3 + 3] ~ ", " ~ two(
            day) ~ " " ~ months[cast(size_t)(month - 1) * 3 .. cast(size_t)(month - 1) * 3 + 3] ~ " " ~ two(
            year / 100) ~ two(year % 100) ~ " " ~ two(clock / 3600) ~ ":" ~ two(
            clock / 60 % 60) ~ ":" ~ two(clock % 60) ~ " GMT";
}

private final class BodyOutput : ServletOutputStream
{
    private ServletEngineResponse response;

    this(ServletEngineResponse response) pure nothrow @nogc
    {
        this.response = response;
    }

    override void write(int b)
    {
        const ubyte[1] one = [cast(ubyte) b];
        response.write(one[]);
    }

    override void write(scope const(ubyte)[] b)
    {
        response.write(b);
    }

    /// Spring's `ServletServerHttpResponse` body flush is a no-op; a servlet's own flush commits, as in Tomcat.
    override void flush()
    {
        response.flushBuffer();
    }
}

private final class BodyWriter : Writer
{
    private ServletEngineResponse response;

    this(ServletEngineResponse response) pure nothrow @nogc
    {
        this.response = response;
    }

    override void write(scope const(char)[] text)
    {
        response.write(cast(const(ubyte)[]) text);
    }

    override void flush()
    {
        response.flushBuffer();
    }
}

@("Date fields format as IMF-fixdate")
unittest
{
    assert(httpDate(784_111_777_000L) == "Sun, 06 Nov 1994 08:49:37 GMT");
    assert(httpDate(0) == "Thu, 01 Jan 1970 00:00:00 GMT");
}
