/++
The servlet engine over real sockets, with a plain `HttpServlet`: Tomcat's framing, field order, error-page
forward, exception handling, parameters and keep-alive.
+/
module servlet_engine_tests;

import core.time : MonoTime, dur;
import flint.engine.aot.any : Any;
import flint.engine.servlet : ServletEngine, ServletEngineException, ServletEngineOptions;
import flint.jakarta.servlet : DispatcherType, Filter, FilterChain, RequestDispatcher,
    ServletRequest, ServletResponse;
import flint.jakarta.servlet.http : HttpServlet, HttpServletRequest, HttpServletRequestWrapper, HttpServletResponse;
import flint.java.lang : IllegalStateException;
import flint.java.util : Locale;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel, TcpSocket;

@safe:

private final class Probe : HttpServlet
{
    long counter;

    protected override string[] getDeclaredMethods()
    {
        return ["GET", "POST"];
    }

    protected override void doGet(HttpServletRequest request, HttpServletResponse response)
    {
        if (request.getDispatcherType() == DispatcherType.ERROR)
            return errorPage(request, response);
        alias Page = void delegate(HttpServletRequest, HttpServletResponse) @safe;
        const Page[string] pages = [
            "/greeting": &greeting, "/committed": &committed, "/empty": &empty,
            "/fields": &fields, "/throw": &fail, "/headers": &headers, "/large": &large,
            "/many": &many
        ];
        if (auto page = request.getServletPath() in pages)
            return (*page)(request, response);
        response.setHeader("Allow", "GET");
        response.sendError(request.getServletPath() == "/nope" ? 404 : 405);
    }

    private void greeting(HttpServletRequest request, HttpServletResponse response)
    {
        ++counter;
        string joined;
        foreach (index, value; request.getParameterValues("name"))
            joined ~= (index != 0 ? "," : "") ~ value;
        if (joined.length == 0)
            joined = "World";
        response.setContentType("application/json");
        response.getOutputStream()
            .write(cast(const(ubyte)[])(`{"id":` ~ decimal(counter) ~ `,"content":"Hello, ` ~ joined ~ `!"}`));
    }

    private void committed(HttpServletRequest, HttpServletResponse response)
    {
        response.setHeader("X-First", "1");
        response.setContentType("application/json");
        response.getOutputStream().write(cast(const(ubyte)[]) `{"committed":true}`);
        response.flushBuffer();
        response.setHeader("X-Late", "ignored");
    }

    private void empty(HttpServletRequest, HttpServletResponse response)
    {
        response.setStatus(406);
        response.setHeader("Accept", "application/json, application/*+json");
    }

    private void fields(HttpServletRequest, HttpServletResponse response)
    {
        response.addHeader("Vary", "Origin");
        response.addHeader("Vary", "Access-Control-Request-Method");
        response.setHeader("X-Replaced", "a");
        response.setHeader("X-Replaced", "b");
        response.setContentType("text/html;charset=UTF-8");
        response.setLocale(Locale.US);
        response.getWriter().print("<p>é</p>");
    }

    private void fail(HttpServletRequest, HttpServletResponse)
    {
        throw new IllegalStateException("boom");
    }

    private void headers(HttpServletRequest request, HttpServletResponse response)
    {
        response.setContentType("text/plain");
        response.getWriter()
            .print(request.getHeader("X-Trace") ~ "|" ~ request.getHeader(
                    "x-trace") ~ "|" ~ request.getServerName() ~ "|" ~ decimal(
                    request.getServerPort()) ~ "|" ~ request.getRequestURL() ~ "|" ~ request.getQueryString()
                    ~ "|" ~ request.getProtocol() ~ "|" ~ request.getLocale().toLanguageTag());
    }

    /// More attributes, parameters and fields than the request and response hold inside themselves.
    private void many(HttpServletRequest request, HttpServletResponse response)
    {
        foreach (index; 0 .. 12)
            request.setAttribute("a" ~ decimal(index), Any.of(cast(int) index));
        request.setAttribute("a3", Any.of(30));
        request.removeAttribute("a5");
        string attributes;
        foreach (name; request.getAttributeNames())
            attributes ~= name ~ "=" ~ decimal(request.getAttribute(name).get!int) ~ " ";
        string parameters;
        foreach (name; request.getParameterNames())
        {
            parameters ~= name ~ "=";
            foreach (value; request.getParameterValues(name))
                parameters ~= value ~ ",";
        }
        foreach (index; 0 .. 10)
            response.addHeader("X-" ~ decimal(index), decimal(index));
        response.setHeader("X-2", "two"); // inside the response's slots, now on the heap
        response.setHeader("X-9", "nine");
        response.setContentType("text/plain");
        response.getWriter().print(attributes ~ "|" ~ parameters);
    }

    private void large(HttpServletRequest, HttpServletResponse response)
    {
        response.setContentType("text/plain");
        auto writer = response.getWriter();
        foreach (_; 0 .. 1000)
            writer.print("0123456789");
    }

    protected override void doPost(HttpServletRequest request, HttpServletResponse response)
    {
        if (request.getDispatcherType() == DispatcherType.ERROR)
            return errorPage(request, response);
        if (request.getServletPath() == "/many")
            return many(request, response);
        response.setHeader("Allow", "GET");
        response.sendError(405, "Method 'POST' is not supported.");
    }

    /// Stands in for Boot's BasicErrorController: echoes the error attributes, then commits (chunked).
    private void errorPage(HttpServletRequest request, HttpServletResponse response)
    {
        const code = request.getAttribute(RequestDispatcher.ERROR_STATUS_CODE).get!int;
        const uri = request.getAttribute(RequestDispatcher.ERROR_REQUEST_URI).get!string;
        const message = request.getAttribute(RequestDispatcher.ERROR_MESSAGE).get!string;
        auto exception = request.getAttribute(RequestDispatcher.ERROR_EXCEPTION);
        response.setStatus(code);
        response.setContentType("application/json");
        response.getOutputStream()
            .write(cast(const(ubyte)[])(`{"status":` ~ decimal(
                    code) ~ `,"path":"` ~ uri ~ `","message":"` ~ message ~ `","exception":` ~ (exception.isNull()
                    ? "null" : `"` ~ request.getAttribute(RequestDispatcher.ERROR_EXCEPTION_TYPE).get!string ~ `"`)
                    ~ `,"at":"` ~ request.getRequestURI() ~ `"}`));
        response.flushBuffer();
    }
}

private string decimal(long value)
{
    import std.conv : to;

    return value.to!string;
}

private struct Fixture
{
    ServletEngine engine;
    Probe probe;
    ushort port;

    void open(string contextPath = "")
    {
        ServletEngineOptions options;
        options.address = "127.0.0.1";
        options.contextPath = contextPath;
        options.port = 0;
        engine = new ServletEngine(options);
        probe = new Probe;
        engine.addServlet("dispatcherServlet", probe);
        engine.start();
        port = cast(ushort) engine.getPort();
        assert(port != 0);
    }

    void close()
    {
        engine.stop();
    }

    Socket connect()
    {
        auto socket = new TcpSocket(new InternetAddress("127.0.0.1", port));
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(3_000));
        return socket;
    }
}

private bool interrupted() @trusted
{
    import core.stdc.errno : EINTR, errno;

    return errno == EINTR;
}

private void sendAll(Socket socket, scope const(char)[] text)
{
    const(ubyte)[] bytes = cast(const(ubyte)[]) text;
    while (bytes.length != 0)
    {
        const sent = socket.send(bytes);
        if (sent == Socket.ERROR && interrupted())
            continue;
        assert(sent > 0);
        bytes = bytes[sent .. $];
    }
}

private ptrdiff_t find(scope const(char)[] text, scope const(char)[] needle, size_t from = 0)
{
    foreach (index; from .. text.length >= needle.length ? text.length - needle.length + 1 : from)
        if (text[index .. index + needle.length] == needle)
            return index;
    return -1;
}

/// One response, head and decoded content, read off a keep-alive connection.
private struct Exchange
{
    string head;
    string content;

    /// The head without its Date line, which the suites do not compare either.
    string headWithoutDate() const
    {
        const at = find(head, "Date: ");
        if (at < 0)
            return head;
        const end = find(head, "\r\n", at);
        return head[0 .. at] ~ head[end + 2 .. $];
    }
}

private Exchange exchange(Socket socket, ref char[] received, scope const(char)[] request, bool head = false)
{
    sendAll(socket, request);
    char[4096] chunk;
    const deadline = MonoTime.currTime + dur!"seconds"(5);
    for (;;)
    {
        const end = find(received, "\r\n\r\n");
        if (end >= 0)
        {
            const headText = received[0 .. end + 4];
            const start = end + 4;
            const lengthAt = find(headText, "\r\nContent-Length: ");
            if (head)
            {
                auto result = Exchange(headText.idup, "");
                received = received[start .. $].dup;
                return result;
            }
            if (lengthAt >= 0)
            {
                size_t length;
                foreach (c; headText[lengthAt + 18 .. $])
                {
                    if (c < '0' || c > '9')
                        break;
                    length = length * 10 + (c - '0');
                }
                if (received.length >= start + length)
                {
                    auto result = Exchange(headText.idup, received[start .. start + length].idup);
                    received = received[start + length .. $].dup;
                    return result;
                }
            }
            else
            {
                const last = find(received, "\r\n0\r\n\r\n", start - 2);
                if (last >= 0)
                {
                    auto result = Exchange(headText.idup, dechunk(received[start .. last + 7]));
                    received = received[last + 7 .. $].dup;
                    return result;
                }
            }
        }
        assert(MonoTime.currTime < deadline, "timed out: " ~ received.idup);
        ptrdiff_t count;
        do
            count = socket.receive(chunk[]);
        while (count == Socket.ERROR && interrupted());
        assert(count > 0, "connection closed: " ~ received.idup);
        received ~= chunk[0 .. count];
    }
}

private string dechunk(scope const(char)[] text)
{
    string decoded;
    size_t at;
    for (;;)
    {
        size_t size;
        while (text[at] != '\r')
        {
            const c = text[at++];
            size = size * 16 + (c <= '9' ? c - '0' : c - 'a' + 10);
        }
        at += 2;
        if (size == 0)
            return decoded;
        decoded ~= text[at .. at + size];
        at += size + 2;
    }
}

@("an uncommitted response is sent whole with Content-Length and no reason phrase")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    char[] pending;

    auto reply = exchange(socket, pending, "GET /greeting HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.headWithoutDate() == "HTTP/1.1 200 \r\nContent-Type: application/json\r\nContent-Length: 34\r\n\r\n",
            reply.head);
    assert(reply.content == `{"id":1,"content":"Hello, World!"}`, reply.content);

    // Query parameters: '+' is a space, UTF-8 percent bytes decode, repeated values join, empty is the default.
    reply = exchange(socket, pending, "GET /greeting?name=Jane+Q%20Public HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.content == `{"id":2,"content":"Hello, Jane Q Public!"}`, reply.content);
    reply = exchange(socket, pending, "GET /greeting?name=%C3%A9t%C3%A9 HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.content == `{"id":3,"content":"Hello, été!"}`, reply.content);
    reply = exchange(socket, pending, "GET /greeting?name=a&name=b HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.content == `{"id":4,"content":"Hello, a,b!"}`, reply.content);

    // An empty response that was never committed: Content-Length: 0 after the application's fields.
    reply = exchange(socket, pending, "GET /empty HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.headWithoutDate() == "HTTP/1.1 406 \r\nAccept: application/json, application/*+json\r\n"
            ~ "Content-Length: 0\r\n\r\n", reply.head);

    // HEAD: the handler runs, Content-Length is the length of the body that is not sent.
    reply = exchange(socket, pending, "HEAD /greeting HTTP/1.1\r\nHost: localhost\r\n\r\n", true);
    assert(reply.headWithoutDate() == "HTTP/1.1 200 \r\nContent-Type: application/json\r\nContent-Length: 34\r\n\r\n",
            reply.head);
    reply = exchange(socket, pending, "GET /greeting?name=again HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.content == `{"id":6,"content":"Hello, again!"}`, reply.content);

    // Past 16 names the parameters are indexed; values still join in arrival order.
    string query = "name=x";
    foreach (index; 0 .. 20)
        query ~= "&p" ~ decimal(index) ~ "=" ~ decimal(index);
    reply = exchange(socket, pending, "GET /greeting?" ~ query ~ "&name=y HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.content == `{"id":7,"content":"Hello, x,y!"}`, reply.content);
}

@("flushBuffer commits with chunked framing and freezes the fields; a full buffer commits too")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    char[] pending;

    auto reply = exchange(socket, pending, "GET /committed HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.headWithoutDate() == "HTTP/1.1 200 \r\nX-First: 1\r\nContent-Type: application/json\r\n"
            ~ "Transfer-Encoding: chunked\r\n\r\n", reply.head);
    assert(reply.content == `{"committed":true}`, reply.content);

    // 10,000 bytes overflow Tomcat's 8 KiB buffer: committed early, so chunked.
    reply = exchange(socket, pending, "GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(find(reply.head, "Transfer-Encoding: chunked\r\n") > 0, reply.head);
    assert(reply.content.length == 10_000 && reply.content[0 .. 10] == "0123456789");
}

@("sendError forwards once to the error page with Tomcat's attributes, keeping fields set before it")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    char[] pending;

    auto reply = exchange(socket, pending, "GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.headWithoutDate() == "HTTP/1.1 404 \r\nAllow: GET\r\nContent-Type: application/json\r\n"
            ~ "Transfer-Encoding: chunked\r\n\r\n", reply.head);
    assert(reply.content == `{"status":404,"path":"/nope","message":"","exception":null,"at":"/error"}`, reply.content);

    reply = exchange(socket, pending, "POST /greeting HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n");
    assert(reply.head[0 .. 15] == "HTTP/1.1 405 \r\n", reply.head);
    assert(reply.content == `{"status":405,"path":"/greeting","message":"Method 'POST' is not supported.",`
            ~ `"exception":null,"at":"/error"}`, reply.content);

    // The connection is still in step after the error dispatches.
    reply = exchange(socket, pending, "GET /greeting HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.content == `{"id":1,"content":"Hello, World!"}`, reply.content);

    // An uncaught exception is a 500 forwarded with the exception's type. As in Tomcat
    // (Http11Processor.statusDropsConnection), a 500 closes the connection with "Connection: close".
    reply = exchange(socket, pending, "GET /throw HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.head[0 .. 15] == "HTTP/1.1 500 \r\n", reply.head);
    assert(find(reply.head, "\r\nConnection: close\r\n") > 0, reply.head);
    assert(reply.content == `{"status":500,"path":"/throw","message":"boom",`
            ~ `"exception":"flint.java.lang.IllegalStateException","at":"/error"}`, reply.content);
    ubyte[1] rest;
    assert(socket.receive(rest[]) == 0, "the connection stays open after a 500");
}

@("a request outside the context path gets Tomcat's host-level 404 page; inside it, the servlet")
unittest
{
    Fixture fixture;
    fixture.open("/app");
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    char[] pending;

    auto reply = exchange(socket, pending, "GET /greeting HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.headWithoutDate() == "HTTP/1.1 404 \r\nContent-Type: text/html;charset=utf-8\r\n"
            ~ "Content-Language: en\r\nContent-Length: 431\r\n\r\n", reply.head);
    assert(reply.content[0 .. 67] == "<!doctype html><html lang=\"en\"><head><title>HTTP Status 404 \u2013 Not",
            reply.content);
    reply = exchange(socket, pending, "GET /application/greeting HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.head[0 .. 15] == "HTTP/1.1 404 \r\n", reply.head);
    assert(find(reply.content, "HTTP Status 404") > 0, reply.content);

    reply = exchange(socket, pending, "GET /app/greeting HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.content == `{"id":1,"content":"Hello, World!"}`, reply.content);
}

@("request fields, host, URL and query reach the servlet as copies; field order follows Tomcat")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    char[] pending;

    auto reply = exchange(socket, pending, "GET /headers?a=1&b HTTP/1.1\r\nHost: example.test:8443\r\n"
            ~ "X-Trace: 7\r\nAccept-Language: de;q=0.5, fr-CH\r\n\r\n");
    assert(reply.content == "7|7|example.test|8443|http://example.test:8443/headers|a=1&b|HTTP/1.1|fr-CH",
            reply.content);

    // Repeated fields keep their order; a replaced field keeps its first position; Content-Type, then
    // Content-Language, follow the application's fields, as Tomcat writes them.
    reply = exchange(socket, pending, "GET /fields HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.headWithoutDate() == "HTTP/1.1 200 \r\nVary: Origin\r\nVary: Access-Control-Request-Method\r\n"
            ~ "X-Replaced: b\r\nContent-Type: text/html;charset=UTF-8\r\nContent-Language: en-US\r\n"
            ~ "Content-Length: 9\r\n\r\n", reply.head);
    assert(reply.content == "<p>é</p>", reply.content);

    // A request naming keep-alive gets Tomcat's Keep-Alive field with the 60 s timeout.
    reply = exchange(socket, pending, "GET /greeting HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n");
    assert(find(reply.head, "\r\nKeep-Alive: timeout=60\r\nConnection: keep-alive\r\n") > 0, reply.head);
}

@("attributes, parameters, fields and a form body past the inline slots keep their order and values")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    auto socket = fixture.connect();
    scope (exit)
        socket.close();
    char[] pending;

    // Parameters from the query and from a form body (copied with the request head, in one block).
    const form = "p4=4&p5=5&p1=1b&p6=%41";
    const formLength = decimal(form.length);
    auto reply = exchange(socket, pending, "POST /many?p1=1&p2=2&p3=3 HTTP/1.1\r\nHost: localhost\r\n"
            ~ "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: " ~ formLength ~ "\r\n\r\n" ~ form);
    assert(reply.content == "a0=0 a1=1 a2=2 a3=30 a4=4 a6=6 a7=7 a8=8 a9=9 a10=10 a11=11 "
            ~ "|p1=1,1b,p2=2,p3=3,p4=4,p5=5,p6=A,", reply.content);
    const contentLength = decimal(reply.content.length);
    assert(reply.headWithoutDate() == "HTTP/1.1 200 \r\nX-0: 0\r\nX-1: 1\r\nX-2: two\r\nX-3: 3\r\n"
            ~ "X-4: 4\r\nX-5: 5\r\nX-6: 6\r\nX-7: 7\r\nX-8: 8\r\nX-9: nine\r\n"
            ~ "Content-Type: text/plain;charset=ISO-8859-1\r\nContent-Length: " ~ contentLength ~ "\r\n\r\n",
            reply.head);

    // The next request on the connection starts from empty slots.
    reply = exchange(socket, pending, "GET /many?q=1 HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.content == "a0=0 a1=1 a2=2 a3=30 a4=4 a6=6 a7=7 a8=8 a9=9 a10=10 a11=11 |q=1,", reply.content);
}

@("a second engine on a bound port fails to start with ServletEngineException")
unittest
{
    Fixture fixture;
    fixture.open();
    scope (exit)
        fixture.close();
    ServletEngineOptions options;
    options.address = "127.0.0.1";
    options.port = fixture.port;
    auto second = new ServletEngine(options);
    second.addServlet("dispatcherServlet", new Probe);
    bool failed;
    try
        second.start();
    catch (ServletEngineException e)
        failed = e.port == fixture.port;
    assert(failed);
    assert(second.getPort() == -1);
}

@("graceful shutdown with no requests in flight reports idle")
unittest
{
    Fixture fixture;
    fixture.open();
    assert(fixture.engine.shutDownGracefully(5_000_000_000L));
    fixture.engine.stop();
}

/// Adds a response field naming itself, then passes the request on.
private final class Tagging : Filter
{
    mixin Filter.Defaults;
    private string tag;

    this(string tag) pure nothrow @nogc
    {
        this.tag = tag;
    }

    void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
    {
        (cast(HttpServletResponse) response).addHeader("X-Filter", tag);
        chain.doFilter(request, response);
    }
}

@("a ServletContextInitializer registers the servlet and filters through ServletContext, as Boot's beans do")
unittest
{
    ServletEngineOptions options;
    options.address = "127.0.0.1";
    options.port = 0;
    auto engine = new ServletEngine(options);
    auto context = engine.getServletContext();
    auto servlet = context.addServlet("dispatcherServlet", new Probe);
    assert(servlet !is null && servlet.getName() == "dispatcherServlet");
    servlet.setLoadOnStartup(1);
    assert(servlet.addMapping("/").length == 0 && servlet.getMappings() == ["/"]);
    assert(context.addServlet("dispatcherServlet", new Probe) is null);
    // isMatchAfter true runs after every isMatchAfter false mapping, whatever the declaration order.
    context.addFilter("late", new Tagging("late")).addMappingForUrlPatterns(null, true, "/*");
    context.addFilter("early", new Tagging("early")).addMappingForUrlPatterns(null, false, "/*");
    context.addFilter("named", new Tagging("named")).addMappingForServletNames(null, false, "dispatcherServlet");
    context.addFilter("elsewhere", new Tagging("elsewhere")).addMappingForUrlPatterns(null, false, "/api/*");
    assert(context.addFilter("early", new Tagging("again")) is null);
    engine.start();
    scope (exit)
        engine.stop();
    bool refused;
    try
        context.addServlet("late", new Probe);
    catch (IllegalStateException)
        refused = true;
    assert(refused);

    auto socket = new TcpSocket(new InternetAddress("127.0.0.1", cast(ushort) engine.getPort()));
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(3_000));
    scope (exit)
        socket.close();
    char[] pending;
    auto reply = exchange(socket, pending, "GET /greeting HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.headWithoutDate() == "HTTP/1.1 200 \r\nX-Filter: early\r\nX-Filter: named\r\nX-Filter: late\r\n"
            ~ "Content-Type: application/json\r\nContent-Length: 34\r\n\r\n", reply.head);
}

/// A request with one header added, as Spring Security's wrappers add to the request they wrap.
private final class WrappedRequest : HttpServletRequestWrapper
{
    this(HttpServletRequest request)
    {
        super(request);
    }

    override string getHeader(string name)
    {
        return name == "X-Wrapped" ? "yes" : super.getHeader(name);
    }
}

/// Passes a `WrappedRequest` down the chain.
private final class Wrapping : Filter
{
    mixin Filter.Defaults;

    void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
    {
        chain.doFilter(new WrappedRequest(cast(HttpServletRequest) request), response);
    }
}

/// Forwards `/api/forward` to `/api/target`, which reports what it sees.
private final class Forwarding : HttpServlet
{
    protected override void doGet(HttpServletRequest request, HttpServletResponse response)
    {
        if (request.getServletPath() == "/api/forward")
            return request.getRequestDispatcher("/api/target").forward(request, response);
        response.setHeader("X-Seen", request.getHeader("X-Wrapped"));
        response.setHeader("X-Path", request.getServletPath());
        response.setContentType("text/plain");
        response.getWriter().write("ok");
    }
}

@("a request a filter wraps still selects the filters mapped to its path, and forwards through the engine")
unittest
{
    ServletEngineOptions options;
    options.address = "127.0.0.1";
    options.port = 0;
    auto engine = new ServletEngine(options);
    auto context = engine.getServletContext();
    context.addServlet("dispatcherServlet", new Forwarding).addMapping("/");
    context.addFilter("wrapping", new Wrapping).addMappingForUrlPatterns(null, false, "/*");
    context.addFilter("api", new Tagging("api")).addMappingForUrlPatterns(null, false, "/api/*");
    engine.start();
    scope (exit)
        engine.stop();

    auto socket = new TcpSocket(new InternetAddress("127.0.0.1", cast(ushort) engine.getPort()));
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(3_000));
    scope (exit)
        socket.close();
    char[] pending;
    auto reply = exchange(socket, pending, "GET /api/forward HTTP/1.1\r\nHost: localhost\r\n\r\n");
    assert(reply.headWithoutDate() == "HTTP/1.1 200 \r\nX-Filter: api\r\nX-Seen: yes\r\nX-Path: /api/target\r\n"
            ~ "Content-Type: text/plain;charset=ISO-8859-1\r\nContent-Length: 2\r\n\r\n", reply.head);
    assert(reply.content == "ok");
}

/// spring-petclinic-rest's updates: `new ResponseEntity<>(dto, HttpStatus.NO_CONTENT)`, a 204 with a JSON body.
private final class NoContentWithBody : HttpServlet
{
    protected override void doGet(HttpServletRequest request, HttpServletResponse response)
    {
        response.setStatus(204);
        response.setContentType("application/json");
        const json = `{"id":11,"firstName":"George"}`;
        response.setContentLength(cast(int) json.length);
        // Spring's ServletServerHttpResponse writes the body, then flushes it (commit by flushBuffer).
        response.getOutputStream().write(cast(const(ubyte)[]) json);
        response.flushBuffer();
    }
}

@("a 204 with a body sends Tomcat's head, Content-Type and no framing field, and no body")
unittest
{
    ServletEngineOptions options;
    options.address = "127.0.0.1";
    options.port = 0;
    auto engine = new ServletEngine(options);
    engine.getServletContext().addServlet("dispatcherServlet", new NoContentWithBody).addMapping("/");
    engine.start();
    scope (exit)
        engine.stop();

    auto socket = new TcpSocket(new InternetAddress("127.0.0.1", cast(ushort) engine.getPort()));
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(3_000));
    scope (exit)
        socket.close();
    char[] pending;
    auto reply = exchange(socket, pending, "GET /owners/11 HTTP/1.1\r\nHost: localhost\r\n\r\n", true);
    assert(reply.headWithoutDate() == "HTTP/1.1 204 \r\nContent-Type: application/json\r\n\r\n", reply.head);
    // The connection stays usable: the next response follows directly, with no stray body bytes before it.
    auto next = exchange(socket, pending, "GET /owners/11 HTTP/1.1\r\nHost: localhost\r\n\r\n", true);
    assert(next.headWithoutDate() == reply.headWithoutDate(), next.head);
}
