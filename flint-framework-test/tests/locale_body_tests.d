/++
`AcceptHeaderLocaleResolverTests` (spring-webmvc/src/test/java/org/springframework/web/servlet/i18n/, Spring Framework
v7.1.0) ported, plus Flint checks of two Spring behaviours that MockMvc observes: `DispatcherServlet.render`
applies the resolved locale to the response (`Content-Language`), and `@RequestBody` reads JSON through Jackson.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit becomes D unittests; `List<Locale>` is `Locale[]` (R10).
+/
module locale_body_tests;

import flint.engine.aot.any : Any;
import flint.http : MediaType;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.java.util : LinkedHashMap, Locale;
import flint.mock.web : MockHttpServletRequest;
import flint.stereotype : Controller;
import flint.test.web.servlet.request : MockMvcRequestBuilders;
import flint.test.web.servlet.result : MockMvcResultMatchers;
import flint.test.web.servlet.setup : MockMvcBuilders;
import flint.web.bind.annotation : GetMapping, PostMapping, RequestBody, RestController;
import flint.web.servlet : ModelAndView, View;
import flint.web.servlet.i18n : AcceptHeaderLocaleResolver;

@safe:

private HttpServletRequest request(Locale[] locales...)
{
    auto request = new MockHttpServletRequest();
    request.setPreferredLocales(locales.dup);
    return request;
}

private immutable Locale KOREA = Locale("ko", "KR");

@("AcceptHeaderLocaleResolverTests.resolve")
unittest
{
    auto resolver = new AcceptHeaderLocaleResolver();
    assert(resolver.resolveLocale(request(Locale.CANADA)) == Locale.CANADA);
    assert(resolver.resolveLocale(request(Locale.US, Locale.CANADA)) == Locale.US);
}

@("AcceptHeaderLocaleResolverTests.resolvePreferredSupported")
unittest
{
    auto resolver = new AcceptHeaderLocaleResolver();
    resolver.setSupportedLocales([Locale.CANADA]);
    assert(resolver.resolveLocale(request(Locale.US, Locale.CANADA)) == Locale.CANADA);
}

@("AcceptHeaderLocaleResolverTests.resolvePreferredNotSupported")
unittest
{
    auto resolver = new AcceptHeaderLocaleResolver();
    resolver.setSupportedLocales([Locale.CANADA]);
    assert(resolver.resolveLocale(request(Locale.US, Locale.UK)) == Locale.US);
}

@("AcceptHeaderLocaleResolverTests.resolvePreferredAgainstLanguageOnly")
unittest
{
    auto resolver = new AcceptHeaderLocaleResolver();
    resolver.setSupportedLocales([Locale.ENGLISH]);
    assert(resolver.resolveLocale(request(Locale.GERMANY, Locale.US, Locale.UK)) == Locale.ENGLISH);
}

@("AcceptHeaderLocaleResolverTests.resolvePreferredAgainstCountryIfPossible")
unittest
{
    auto resolver = new AcceptHeaderLocaleResolver();
    resolver.setSupportedLocales([Locale.ENGLISH, Locale.UK]);
    assert(resolver.resolveLocale(request(Locale.GERMANY, Locale.US, Locale.UK)) == Locale.UK);
}

@("AcceptHeaderLocaleResolverTests.resolvePreferredAgainstLanguageWithMultipleSupportedLocales")
unittest
{
    auto resolver = new AcceptHeaderLocaleResolver();
    resolver.setSupportedLocales([Locale.GERMAN, Locale.US]);
    assert(resolver.resolveLocale(request(Locale.GERMANY, Locale.US, Locale.UK)) == Locale.GERMAN);
}

@("AcceptHeaderLocaleResolverTests.resolvePreferredNotSupportedWithDefault")
unittest
{
    auto resolver = new AcceptHeaderLocaleResolver();
    resolver.setSupportedLocales([Locale.US, Locale.JAPAN]);
    resolver.setDefaultLocale(Locale.JAPAN);
    assert(resolver.resolveLocale(request(KOREA)) == Locale.JAPAN);
}

@("AcceptHeaderLocaleResolverTests.defaultLocale")
unittest
{
    auto resolver = new AcceptHeaderLocaleResolver();
    resolver.setDefaultLocale(Locale.JAPANESE);
    auto mock = new MockHttpServletRequest();
    assert(resolver.resolveLocale(mock) == Locale.JAPANESE);

    mock.addHeader("Accept-Language", Locale.US.toLanguageTag());
    mock.setPreferredLocales([Locale.US]);
    assert(resolver.resolveLocale(mock) == Locale.US);
}

@("AcceptHeaderLocaleResolverTests.defaultLocaleFunction")
unittest
{
    auto resolver = new AcceptHeaderLocaleResolver();
    resolver.setDefaultLocaleFunction(delegate Locale(HttpServletRequest) => Locale.UK);
    assert(resolver.resolveLocale(new MockHttpServletRequest()) == Locale.UK);
}

@("an Accept-Language header sets the mock request's locales, as Spring's mock does")
unittest
{
    auto mock = new MockHttpServletRequest();
    assert(mock.getLocale() == Locale.ENGLISH);
    mock.addHeader("Accept-Language", "fr-CH, fr;q=0.9, en;q=0.8, *;q=0.5");
    assert(mock.getLocale().toLanguageTag() == "fr-CH");
    assert(mock.getLocales().length == 3);
}

/// A view that writes its locale-free HTML, as Boot's error view does.
private final class PageView : View
{
    string getContentType()
    {
        return "text/html;charset=UTF-8";
    }

    void render(LinkedHashMap!(string, Any), HttpServletRequest, HttpServletResponse response)
    {
        response.setContentType(getContentType());
        response.getWriter().print("<p>page</p>");
    }
}

/// A controller rendering a view object.
@Controller class PageController
{
    /// `GET /page`.
    @GetMapping("/page") ModelAndView page()
    {
        return new ModelAndView(new PageView);
    }
}

@("DispatcherServlet.render applies the resolved locale to the response (Content-Language)")
unittest
{
    auto mockMvc = MockMvcBuilders.standaloneSetup(new PageController()).build();
    // MockHttpServletRequest's default locale is ENGLISH.
    mockMvc.perform(MockMvcRequestBuilders.get("/page")).andExpect(MockMvcResultMatchers.status()
            .isOk()).andExpect(MockMvcResultMatchers.header().string("Content-Language", "en"))
        .andExpect(MockMvcResultMatchers.content().string("<p>page</p>"));
    mockMvc.perform(MockMvcRequestBuilders.get("/page").header("Accept-Language", "de-DE;q=0.4, en-US"))
        .andExpect(MockMvcResultMatchers.header().string("Content-Language", "en-US"));
}

/// A record-like request and response body.
struct Point
{
    long x; ///
    string label; ///
}

/// A controller echoing a JSON body.
@RestController class PointController
{
    /// `POST /points`.
    @PostMapping("/points") Point echo(@RequestBody Point point)
    {
        return Point(point.x * 2, point.label ~ "!");
    }
}

@("@RequestBody reads JSON through Jackson; malformed JSON is a 400")
unittest
{
    auto mockMvc = MockMvcBuilders.standaloneSetup(new PointController()).build();
    mockMvc.perform(MockMvcRequestBuilders.post("/points").contentType(MediaType.APPLICATION_JSON)
            .content(`{"label":"p","x":21}`)).andExpect(MockMvcResultMatchers.status().isOk())
        .andExpect(MockMvcResultMatchers.content().string(`{"x":42,"label":"p!"}`));
    mockMvc.perform(MockMvcRequestBuilders.post("/points").contentType(MediaType.APPLICATION_JSON)
            .content(`{"x":`)).andExpect(MockMvcResultMatchers.status().isBadRequest());
}
