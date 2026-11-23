/++
Flint's tests of the per-request path parse (Spring's `ServletRequestPathUtils.parseAndCache`): handler mappings
match every pattern against one parse, and re-parse after a forward changes the path.
+/
module flint.web.request_path_cache_tests;

import flint.engine.aot.any : Any;
import flint.mock.web : MockHttpServletRequest;
import flint.web.servlet.handler : parsedLookupPath, pathAttribute;
import flint.web.util.pattern : PathContainer, PathPatternParser;

@safe:

@("the lookup path is parsed once and reused while the request path is unchanged")
unittest
{
    auto request = new MockHttpServletRequest("GET", "/petclinic/api/owners/7");
    request.setContextPath("/petclinic");
    assert(request.getAttribute(pathAttribute).isNull());

    const first = parsedLookupPath(request);
    assert(first.raw == "/api/owners/7" && first.segments == ["api", "owners", "7"]);
    auto cached = request.getAttribute(pathAttribute);
    assert(!cached.isNull() && cached.asObject() !is null); // one object holds the parse and its segments
    const second = parsedLookupPath(request);
    assert(second.segments is first.segments, "the second lookup reuses the first parse");

    auto parser = new PathPatternParser();
    assert(parser.parse("/api/owners/{ownerId}").matches(second));
    assert(parser.parse("/api/owners/{ownerId}").matchAndExtract(second).getUriVariables() == [
        ["ownerId", "7"]
    ]);
}

@("a forward to another path parses the new path")
unittest
{
    auto request = new MockHttpServletRequest("GET", "/owners");
    const before = parsedLookupPath(request);
    request.setRequestURI("/error");
    const after = parsedLookupPath(request);
    assert(before.segments == ["owners"] && after.segments == ["error"]);
}
