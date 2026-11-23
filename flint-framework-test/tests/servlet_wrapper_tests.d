/++
Flint's tests of `jakarta.servlet`'s request and response wrappers, over Spring's servlet mocks. These cover what
Spring Security's wrappers rely on: delegation of every call, overriding part of it, `isWrapperFor` through nested
wrappers, and a null wrapped object refused.
+/
module flint.web.servlet_wrapper_tests;

import flint.engine.aot.any : Any;
import flint.jakarta.servlet : ServletRequestWrapper, ServletResponseWrapper;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletRequestWrapper,
    HttpServletResponse, HttpServletResponseWrapper;
import flint.java.lang : IllegalArgumentException;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse;

@safe:

@("HttpServletRequestWrapper delegates to the wrapped request and lets a subclass override part of it")
unittest
{
    auto request = new MockHttpServletRequest("GET", "/owners");
    request.addHeader("Accept", "application/json");
    request.setParameter("lastName", "Davis");
    auto plain = new HttpServletRequestWrapper(request);
    assert(plain.getMethod() == "GET" && plain.getRequestURI() == "/owners");
    assert(plain.getHeader("Accept") == "application/json");
    assert(plain.getParameter("lastName") == "Davis");
    plain.setAttribute("seen", Any.of(true));
    assert(request.getAttribute("seen").get!bool);

    HttpServletRequest overriding = new class HttpServletRequestWrapper
    {
        this()
        {
            super(request);
        }

        override string getRemoteUser()
        {
            return "admin";
        }
    };
    assert(overriding.getRemoteUser() == "admin");
    assert(overriding.getMethod() == "GET");
}

@("HttpServletResponseWrapper writes through to the wrapped response")
unittest
{
    auto response = new MockHttpServletResponse();
    auto wrapper = new HttpServletResponseWrapper(response);
    wrapper.setStatus(401);
    wrapper.setHeader("WWW-Authenticate", "Basic realm=\"Realm\"");
    wrapper.setContentType("application/json");
    assert(response.getStatus() == 401);
    assert(response.getHeader("WWW-Authenticate") == "Basic realm=\"Realm\"");
    assert(wrapper.getContentType() == response.getContentType());
    assert(wrapper.containsHeader("WWW-Authenticate"));
}

@("isWrapperFor finds the wrapped object through nested wrappers")
unittest
{
    auto request = new MockHttpServletRequest();
    auto inner = new HttpServletRequestWrapper(request);
    auto outer = new HttpServletRequestWrapper(inner);
    assert(outer.isWrapperFor(request) && outer.isWrapperFor(inner));
    assert(!inner.isWrapperFor(outer));
    assert(outer.getRequest() is inner);

    auto response = new MockHttpServletResponse();
    auto responseWrapper = new ServletResponseWrapper(new HttpServletResponseWrapper(response));
    assert(responseWrapper.isWrapperFor(response));
    assert(!responseWrapper.isWrapperFor(new MockHttpServletResponse()));
}

@("the wrappers refuse a null request or response")
unittest
{
    bool refused(scope void delegate() @safe action)
    {
        try
            action();
        catch (IllegalArgumentException)
            return true;
        return false;
    }

    assert(refused(() { new ServletRequestWrapper(null); }));
    assert(refused(() { new HttpServletResponseWrapper(null); }));
    auto wrapper = new ServletRequestWrapper(new MockHttpServletRequest());
    assert(refused(() { wrapper.setRequest(null); }));
}
