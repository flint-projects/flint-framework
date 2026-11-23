/++
Flint: one `DispatcherServlet` serves every reactor thread, so its handler mappings, the adapter, the adapter's
prepared invocables and the argument-resolver cache are shared and only read while requests run. These tests
dispatch from several threads at once, each request with its own parameter, and check every response is its own.
+/
module flint.web.servlet.concurrent_dispatch_tests;

// flint.web first: importing flint.web.method.support before it trips a forward-reference error on
// LinkedHashMap!(string, Any) in this compiler.
import flint.web;
import flint.jakarta.servlet : ServletRequest, ServletResponse;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;
import flint.test.web.servlet.setup : MockMvcBuilders;
import flint.web.bind.annotation : GetMapping, PathVariable, RequestParam, RestController;
import flint.web.servlet : DispatcherServlet;

@safe:

@RestController
class ConcurrentGreetingController
{
    @GetMapping("/greeting")
    string greeting(@RequestParam("name") string name)
    {
        return "Hello, " ~ name ~ "!";
    }

    @GetMapping("/owners/{ownerId}/pets/{petId}")
    string pet(@PathVariable("ownerId") int ownerId, @PathVariable("petId") int petId,
            @RequestParam(value: "full", required: false) string full)
    {
        import std.conv : to;

        return ownerId.to!string ~ "/" ~ petId.to!string ~ (full !is null ? "/" ~ full : "");
    }
}

/// `rounds` requests on `servlet`, alternating two handlers; null when every response was this thread's own.
private string dispatch(DispatcherServlet servlet, size_t thread, size_t rounds)
{
    import std.conv : to;

    foreach (round; 0 .. rounds)
    {
        const tag = thread.to!string ~ "-" ~ round.to!string;
        string path, expected;
        auto request = new MockHttpServletRequest("GET", "");
        if (round % 2 == 0)
        {
            path = "/greeting";
            request.setParameter("name", tag);
            expected = "Hello, " ~ tag ~ "!";
        }
        else
        {
            path = "/owners/" ~ thread.to!string ~ "/pets/" ~ round.to!string;
            request.setParameter("full", tag);
            expected = thread.to!string ~ "/" ~ round.to!string ~ "/" ~ tag;
        }
        request.setRequestURI(path);
        auto response = new MockHttpServletResponse;
        // The container's entry point: Servlet.service(ServletRequest, ServletResponse).
        ServletRequest servletRequest = request;
        ServletResponse servletResponse = response;
        servlet.service(servletRequest, servletResponse);
        const content = response.getContentAsString();
        if (response.getStatus() != 200 || content != expected)
            return path ~ ": " ~ response.getStatus().to!string ~ " " ~ content ~ ", expected " ~ expected;
    }
    return null;
}

@("Flint: threads dispatching at once through one DispatcherServlet each get their own responses")
@system unittest
{
    import core.thread.osthread : Thread;
    import std.conv : to;

    auto mockMvc = MockMvcBuilders.standaloneSetup(new ConcurrentGreetingController()).build();
    auto servlet = mockMvc.getDispatcherServlet();
    // The first request on the starting thread, as Boot's startup does, before the reactor threads take over.
    assert(dispatch(servlet, 99, 2) is null);

    enum threads = 6;
    string[threads] failures;
    Thread spawn(size_t t)
    {
        return new Thread(() { failures[t] = dispatch(servlet, t, 600); });
    }

    Thread[] running;
    foreach (t; 0 .. threads)
        running ~= spawn(t);
    foreach (thread; running)
        thread.start();
    foreach (thread; running)
        thread.join();
    foreach (t, failure; failures)
        assert(failure is null, "thread " ~ t.to!string ~ ": " ~ failure);
}
