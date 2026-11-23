/++
Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/test/java/org/springframework/web/servlet/resource/ResourceHttpRequestHandlerTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; each `@Nested` class's
fields become a `Fixture` that `setup` (or `setupInitialized`, whose `@BeforeEach` also calls
`afterPropertiesSet`) returns. flint.web.servlet's `ResourceHttpRequestHandler` has no locations, resolvers or
caching yet and answers every path with `NoResourceFoundException`, so its configuration calls and nearly every case
wait behind version gates; the not-found cases run against it as it is. Class-relative `ClassPathResource`s are
spelled from the class path root (the upstream test resources sit under spring-webmvc/src/test/resources), and
`UrlResource`s and `getURL().getPath()` become files on that class path. flint.mock.web's `MockHttpServletRequest`
has no constructor taking a servlet context, so requests keep their own `MockHttpServletContext`; JUnit's
`GzipSupport` parameter is a `GzippedFiles` the test closes, and Mockito mocks are hand-written stubs. The test
lives with flint.mock.web in flint:framework-test.
+/
module flint.web.resource_http_request_handler_tests;

import flint.core.io : ClassPathResource, Resource;
import flint.engine.aot.any : Any;
import flint.http : HttpMethod;
import flint.mock.web : MockHttpServletRequest, MockHttpServletResponse, MockServletContext;
import flint.web.servlet : HandlerMapping;
import flint.web.servlet.resource : NoResourceFoundException, ResourceHttpRequestHandler;
import std.exception : assertThrown;

@safe:

private alias PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE = HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE;

/// The class path directory of `ResourceHttpRequestHandlerTests.class`, which Spring's relative resources start from.
private enum string resourcePackage = "org/springframework/web/servlet/resource/";

/// `testResource`: `new ClassPathResource("test/", ResourceHttpRequestHandlerTests.class)`.
private Resource testResource()
{
    return new ClassPathResource(resourcePackage ~ "test/");
}

/// `testAlternatePathResource`.
private Resource testAlternatePathResource()
{
    return new ClassPathResource(resourcePackage ~ "testalternatepath/");
}

/// `webjarsResource`.
private Resource webjarsResource()
{
    return new ClassPathResource("META-INF/resources/webjars/");
}

/// `TestServletContext`: CSS and JavaScript MIME types on top of the mock's.
private class TestServletContext : MockServletContext
{
    override string getMimeType(string filePath)
    {
        import std.algorithm.searching : endsWith;

        if (filePath.endsWith(".css"))
            return "text/css";
        else if (filePath.endsWith(".js"))
            return "text/javascript";
        else
            return super.getMimeType(filePath);
    }
}

/// The fields of each `@Nested` class.
private struct Fixture
{
    ResourceHttpRequestHandler handler;
    MockHttpServletRequest request;
    MockHttpServletResponse response;

    /// `assertNotFound()`.
    void assertNotFound()
    {
        assertThrown!NoResourceFoundException(handler.handleRequest(request, response));
    }

    /// `request.setAttribute(HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE, path)`.
    void setPathWithinHandlerMapping(string path)
    {
        request.setAttribute(PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE, Any.of(path));
    }
}

/// `@BeforeEach` of `HttpCachingTests` and `ResourceLocationTests`.
private Fixture setup()
{
    auto servletContext = new TestServletContext();
    Fixture f;
    f.handler = new ResourceHttpRequestHandler();
    // ResourceHttpRequestHandler has no locations or servlet context: it serves nothing.
    version (FlintResourceHandlerLocations)
    {
        f.handler.setLocations([testResource(), testAlternatePathResource(), webjarsResource()]);
        f.handler.setServletContext(servletContext);
    }
    // Spring: new MockHttpServletRequest(servletContext, "GET", "").
    f.request = new MockHttpServletRequest("GET", "");
    f.response = new MockHttpServletResponse();
    return f;
}

/// `@BeforeEach` of `ResourceHandlingTests` and `RangeRequestTests`.
private Fixture setupInitialized()
{
    auto f = setup();
    // ResourceHttpRequestHandler has no afterPropertiesSet.
    version (FlintResourceHandlerLocations)
        f.handler.afterPropertiesSet();
    return f;
}

// ---------------------------------------------------------------------------------------------------------------
// ResourceHandlingTests

// ResourceHttpRequestHandler has no locations, media types or servlet context: it serves no resource.
version (FlintResourceHandlerLocations)
{
    import flint.http : MediaType;
    import flint.web : HttpRequestMethodNotSupportedException;

    @("ResourceHttpRequestHandlerTests.ResourceHandlingTests.servesResource")
    unittest
    {
        auto f = setupInitialized();
        f.setPathWithinHandlerMapping("foo.css");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getContentType() == "text/css");
        assert(f.response.getContentLengthLong() == 17);
        assert(f.response.getContentAsString() == "h1 { color:red; }");
    }

    @("ResourceHttpRequestHandlerTests.ResourceHandlingTests.supportsHeadRequests")
    unittest
    {
        auto f = setupInitialized();
        f.request.setMethod("HEAD");
        f.setPathWithinHandlerMapping("foo.css");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getStatus() == 200);
        assert(f.response.getContentType() == "text/css");
        assert(f.response.getContentLengthLong() == 17);
        assert(f.response.getContentAsByteArray().length == 0);
    }

    @("ResourceHttpRequestHandlerTests.ResourceHandlingTests.supportsOptionsRequests")
    unittest
    {
        auto f = setupInitialized();
        f.request.setMethod("OPTIONS");
        f.setPathWithinHandlerMapping("foo.css");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getStatus() == 200);
        assert(f.response.getHeader("Allow") == "GET,HEAD,OPTIONS");
    }

    @("ResourceHttpRequestHandlerTests.ResourceHandlingTests.servesHtmlResources")
    unittest
    {
        auto f = setupInitialized();
        f.setPathWithinHandlerMapping("foo.html");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getContentType() == "text/html");
    }

    // SPR-13658
    @("ResourceHttpRequestHandlerTests.ResourceHandlingTests.getResourceWithRegisteredMediaType")
    unittest
    {
        auto f = setupInitialized();
        Resource[] paths = [new ClassPathResource(resourcePackage ~ "test/")];
        auto handler = new ResourceHttpRequestHandler();
        handler.setServletContext(new MockServletContext());
        handler.setMediaTypes(["bar": MediaType("foo", "bar")]);
        handler.setLocations(paths);
        handler.afterPropertiesSet();

        f.setPathWithinHandlerMapping("foo.bar");
        handler.handleRequest(f.request, f.response);

        assert(f.response.getContentType() == "foo/bar");
        assert(f.response.getContentAsString() == "h1 { color:red; }");
    }

    // SPR-14577
    @("ResourceHttpRequestHandlerTests.ResourceHandlingTests.getMediaTypeWithFavorPathExtensionOff")
    unittest
    {
        auto f = setupInitialized();
        Resource[] paths = [new ClassPathResource(resourcePackage ~ "test/")];
        auto handler = new ResourceHttpRequestHandler();
        handler.setServletContext(new MockServletContext());
        handler.setLocations(paths);
        handler.afterPropertiesSet();

        f.request.addHeader("Accept", "application/json,text/plain,*/*");
        f.setPathWithinHandlerMapping("foo.html");
        handler.handleRequest(f.request, f.response);

        assert(f.response.getContentType() == "text/html");
    }

    // SPR-14368
    @("ResourceHttpRequestHandlerTests.ResourceHandlingTests.getResourceWithMediaTypeResolvedThroughServletContext")
    unittest
    {
        auto f = setupInitialized();
        auto servletContext = new class MockServletContext
        {
            override string getMimeType(string filePath)
            {
                return "foo/bar";
            }
        };

        Resource[] paths = [new ClassPathResource(resourcePackage ~ "test/")];
        auto handler = new ResourceHttpRequestHandler();
        handler.setServletContext(servletContext);
        handler.setLocations(paths);
        handler.afterPropertiesSet();

        // Spring: new MockHttpServletRequest(servletContext, "GET", "").
        auto request = new MockHttpServletRequest("GET", "");
        request.setAttribute(PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE, Any.of("foo.css"));
        handler.handleRequest(request, f.response);

        assert(f.response.getContentType() == "foo/bar");
        assert(f.response.getContentAsString() == "h1 { color:red; }");
    }

    @("ResourceHttpRequestHandlerTests.ResourceHandlingTests.unsupportedHttpMethod")
    unittest
    {
        auto f = setupInitialized();
        f.setPathWithinHandlerMapping("foo.css");
        f.request.setMethod("POST");
        assertThrown!HttpRequestMethodNotSupportedException(f.handler.handleRequest(f.request, f.response));
    }
}

@("ResourceHttpRequestHandlerTests.ResourceHandlingTests.resourceNotFound")
unittest
{
    auto f = setupInitialized();
    foreach (method; HttpMethod.values())
    {
        f.request = new MockHttpServletRequest("GET", "");
        f.setPathWithinHandlerMapping("not-there.css");
        f.request.setMethod(method.name());
        f.response = new MockHttpServletResponse();
        f.assertNotFound();
    }
}

// ---------------------------------------------------------------------------------------------------------------
// RangeRequestTests

// ResourceHttpRequestHandler has no byte-range support (Accept-Ranges, Range, If-Range, multipart/byteranges).
version (FlintResourceRangeRequests)
{
    import flint.http : HttpHeaders;

    @("ResourceHttpRequestHandlerTests.RangeRequestTests.supportsRangeRequest")
    unittest
    {
        auto f = setupInitialized();
        f.setPathWithinHandlerMapping("foo.css");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getHeader("Accept-Ranges") == "bytes");
        assert(f.response.getHeaders("Accept-Ranges").length == 1);
    }

    @("ResourceHttpRequestHandlerTests.RangeRequestTests.partialContentByteRange")
    unittest
    {
        auto f = setupInitialized();
        f.request.addHeader("Range", "bytes=0-1");
        f.setPathWithinHandlerMapping("foo.txt");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getStatus() == 206);
        assert(f.response.getContentType() == "text/plain");
        assert(f.response.getContentLengthLong() == 2);
        assert(f.response.getHeader("Content-Range") == "bytes 0-1/10");
        assert(f.response.getContentAsString() == "So");
        assert(f.response.getHeader("Accept-Ranges") == "bytes");
        assert(f.response.getHeaders("Accept-Ranges").length == 1);
    }

    @("ResourceHttpRequestHandlerTests.RangeRequestTests.ignoreRangeWhenIfRangeETagDoesNotMatch")
    unittest
    {
        auto f = setupInitialized();
        f.handler.setEtagGenerator((Resource resource) => "\"current\"");
        f.request.addHeader(HttpHeaders.RANGE, "bytes=0-1");
        f.request.addHeader(HttpHeaders.IF_RANGE, "\"stale\"");
        f.setPathWithinHandlerMapping("foo.txt");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getStatus() == 200);
        assert(f.response.getHeader(HttpHeaders.ETAG) == "\"current\"");
        assert(f.response.getHeader(HttpHeaders.CONTENT_RANGE) is null);
        assert(f.response.getContentLengthLong() == 10);
        assert(f.response.getContentAsString() == "Some text.");
    }

    @("ResourceHttpRequestHandlerTests.RangeRequestTests.partialContentByteRangeWhenIfRangeETagMatches")
    unittest
    {
        auto f = setupInitialized();
        f.handler.setEtagGenerator((Resource resource) => "\"current\"");
        f.request.addHeader(HttpHeaders.RANGE, "bytes=0-1");
        f.request.addHeader(HttpHeaders.IF_RANGE, "\"current\"");
        f.setPathWithinHandlerMapping("foo.txt");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getStatus() == 206);
        assert(f.response.getHeader(HttpHeaders.ETAG) == "\"current\"");
        assert(f.response.getHeader(HttpHeaders.CONTENT_RANGE) == "bytes 0-1/10");
        assert(f.response.getContentAsString() == "So");
    }

    @("ResourceHttpRequestHandlerTests.RangeRequestTests.partialContentByteRangeNoEnd")
    unittest
    {
        auto f = setupInitialized();
        f.request.addHeader("Range", "bytes=9-");
        f.setPathWithinHandlerMapping("foo.txt");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getStatus() == 206);
        assert(f.response.getContentType() == "text/plain");
        assert(f.response.getContentLengthLong() == 1);
        assert(f.response.getHeader("Content-Range") == "bytes 9-9/10");
        assert(f.response.getContentAsString() == ".");
        assert(f.response.getHeader("Accept-Ranges") == "bytes");
        assert(f.response.getHeaders("Accept-Ranges").length == 1);
    }

    @("ResourceHttpRequestHandlerTests.RangeRequestTests.partialContentByteRangeLargeEnd")
    unittest
    {
        auto f = setupInitialized();
        f.request.addHeader("Range", "bytes=9-10000");
        f.setPathWithinHandlerMapping("foo.txt");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getStatus() == 206);
        assert(f.response.getContentType() == "text/plain");
        assert(f.response.getContentLengthLong() == 1);
        assert(f.response.getHeader("Content-Range") == "bytes 9-9/10");
        assert(f.response.getContentAsString() == ".");
        assert(f.response.getHeader("Accept-Ranges") == "bytes");
        assert(f.response.getHeaders("Accept-Ranges").length == 1);
    }

    @("ResourceHttpRequestHandlerTests.RangeRequestTests.partialContentSuffixRange")
    unittest
    {
        auto f = setupInitialized();
        f.request.addHeader("Range", "bytes=-1");
        f.setPathWithinHandlerMapping("foo.txt");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getStatus() == 206);
        assert(f.response.getContentType() == "text/plain");
        assert(f.response.getContentLengthLong() == 1);
        assert(f.response.getHeader("Content-Range") == "bytes 9-9/10");
        assert(f.response.getContentAsString() == ".");
        assert(f.response.getHeader("Accept-Ranges") == "bytes");
        assert(f.response.getHeaders("Accept-Ranges").length == 1);
    }

    @("ResourceHttpRequestHandlerTests.RangeRequestTests.partialContentSuffixRangeLargeSuffix")
    unittest
    {
        auto f = setupInitialized();
        f.request.addHeader("Range", "bytes=-11");
        f.setPathWithinHandlerMapping("foo.txt");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getStatus() == 206);
        assert(f.response.getContentType() == "text/plain");
        assert(f.response.getContentLengthLong() == 10);
        assert(f.response.getHeader("Content-Range") == "bytes 0-9/10");
        assert(f.response.getContentAsString() == "Some text.");
        assert(f.response.getHeader("Accept-Ranges") == "bytes");
        assert(f.response.getHeaders("Accept-Ranges").length == 1);
    }

    @("ResourceHttpRequestHandlerTests.RangeRequestTests.partialContentInvalidRangeHeader")
    unittest
    {
        import std.algorithm.searching : canFind;

        auto f = setupInitialized();
        f.request.addHeader("Range", "bytes= foo bar");
        f.setPathWithinHandlerMapping("foo.txt");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getStatus() == 416);
        assert(!f.response.getHeaderNames().canFind(HttpHeaders.CONTENT_TYPE));
        assert(f.response.getHeader("Content-Range") == "bytes */10");
        assert(f.response.getHeader("Accept-Ranges") == "bytes");
        assert(f.response.getHeaders("Accept-Ranges").length == 1);
    }

    @("ResourceHttpRequestHandlerTests.RangeRequestTests.partialContentMultipleByteRanges")
    unittest
    {
        import flint.util : StringUtils;
        import std.algorithm.searching : startsWith;

        auto f = setupInitialized();
        f.request.addHeader("Range", "bytes=0-1, 4-5, 8-9");
        f.setPathWithinHandlerMapping("foo.txt");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getStatus() == 206);
        assert(f.response.getContentType().startsWith("multipart/byteranges; boundary="));

        const boundary = "--" ~ f.response.getContentType()[31 .. $];

        const content = f.response.getContentAsString();
        const ranges = StringUtils.tokenizeToStringArray(content, "\r\n", false, true);

        assert(ranges[0] == boundary);
        assert(ranges[1] == "Content-Type: text/plain");
        assert(ranges[2] == "Content-Range: bytes 0-1/10");
        assert(ranges[3] == "So");

        assert(ranges[4] == boundary);
        assert(ranges[5] == "Content-Type: text/plain");
        assert(ranges[6] == "Content-Range: bytes 4-5/10");
        assert(ranges[7] == " t");

        assert(ranges[8] == boundary);
        assert(ranges[9] == "Content-Type: text/plain");
        assert(ranges[10] == "Content-Range: bytes 8-9/10");
        assert(ranges[11] == "t.");
    }

    // gh-25976
    @("ResourceHttpRequestHandlerTests.RangeRequestTests.partialContentWithHttpHead")
    unittest
    {
        auto f = setupInitialized();
        f.request.setMethod("HEAD");
        f.request.addHeader("Range", "bytes=0-1");
        f.setPathWithinHandlerMapping("foo.txt");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getStatus() == 206);
        assert(f.response.getContentType() == "text/plain");
        assert(f.response.getContentLengthLong() == 2);
        assert(f.response.getHeader("Content-Range") == "bytes 0-1/10");
        assert(f.response.getHeaders("Accept-Ranges") == ["bytes"]);
    }
}

// flint.web.servlet.resource has no resource resolver chain (PathResourceResolver, VersionResourceResolver,
// EncodedResourceResolver) and no setResourceResolvers.
version (FlintResourceResolvers)
{
    import flint.core.io : UrlResource;
    import flint.jakarta.servlet.http : HttpServletRequest;
    import flint.java.io : InputStream;
    import flint.web.servlet.resource : EncodedResourceResolver, PathResourceResolver,
        ResourceResolver, ResourceResolverChain, VersionResourceResolver;

    /// `GzipSupport.GzippedFiles`: gzipped copies of test resources, deleted on `close`.
    private struct GzippedFiles
    {
        private string[] created;

        void create(string filePath)
        {
            import std.file : exists, read, remove, write;
            import std.zlib : Compress, HeaderFormat;

            auto location = new ClassPathResource(resourcePackage ~ "test/");
            const resourcePath = location.createRelative(filePath).getFile().getAbsolutePath();

            const gzFilePath = resourcePath ~ ".gz";
            if (exists(gzFilePath))
                remove(gzFilePath);

            auto compress = new Compress(HeaderFormat.gzip);
            const gzipped = compress.compress(read(resourcePath)) ~ compress.flush();
            write(gzFilePath, gzipped);
            created ~= gzFilePath;
        }

        void close()
        {
            import std.file : remove;

            foreach (file; created)
                remove(file);
        }
    }

    // gh-25976
    @("ResourceHttpRequestHandlerTests.RangeRequestTests.partialContentByteRangeWithEncodedResource")
    unittest
    {
        import std.algorithm.sorting : sort;

        GzippedFiles gzippedFiles;
        scope (exit)
            gzippedFiles.close();
        auto f = setupInitialized();
        const path = "js/foo.js";
        gzippedFiles.create(path);

        auto handler = new ResourceHttpRequestHandler();
        handler.setResourceResolvers([
            cast(ResourceResolver) new EncodedResourceResolver(), new PathResourceResolver()
        ]);
        handler.setLocations([testResource()]);
        handler.setServletContext(new MockServletContext());
        handler.afterPropertiesSet();

        f.request.addHeader("Accept-Encoding", "gzip");
        f.request.addHeader("Range", "bytes=0-1");
        f.setPathWithinHandlerMapping(path);
        handler.handleRequest(f.request, f.response);

        assert(f.response.getStatus() == 206);
        auto headerNames = f.response.getHeaderNames().dup;
        assert(headerNames.sort().release() == [
            "Accept-Ranges", "Content-Encoding", "Content-Length", "Content-Range", "Content-Type",
            "Last-Modified", "Vary"
        ]);

        assert(f.response.getContentType() == "text/javascript");
        assert(f.response.getContentLengthLong() == 2);
        assert(f.response.getHeader("Content-Range") == "bytes 0-1/66");
        assert(f.response.getHeaders("Accept-Ranges") == ["bytes"]);
        assert(f.response.getHeaders("Content-Encoding") == ["gzip"]);
        assert(f.response.getHeaders("Vary") == ["Accept-Encoding"]);
    }

    @("ResourceHttpRequestHandlerTests.HttpCachingTests.configureVersionResourceResolver")
    unittest
    {
        auto f = setup();
        auto versionResolver = new VersionResourceResolver().addFixedVersionStrategy("versionString", "/**");
        f.handler.setResourceResolvers([
            cast(ResourceResolver) versionResolver, new PathResourceResolver()
        ]);
        f.handler.afterPropertiesSet();

        f.setPathWithinHandlerMapping("versionString/foo.css");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getHeader("ETag") == "W/\"versionString\"");
    }

    /// Mockito's `mock(Resource.class)` whose `getFilename` and `getInputStream` fail the test.
    private final class UnresolvableResource : ClassPathResource
    {
        this()
        {
            super("unresolvable");
        }

        override string getFilename()
        {
            assert(false, "Resource should not be resolved");
        }

        override InputStream getInputStream()
        {
            assert(false, "Resource should not be resolved");
        }
    }

    /// Mockito's `mock(ResourceResolver.class)` answering every `resolveResource` with `resource`.
    private final class StubResourceResolver : ResourceResolver
    {
        private Resource resource;

        this(Resource resource)
        {
            this.resource = resource;
        }

        Resource resolveResource(HttpServletRequest request, string requestPath, Resource[] locations,
                ResourceResolverChain chain)
        {
            return resource;
        }

        string resolveUrlPath(string resourcePath, Resource[] locations, ResourceResolverChain chain)
        {
            return null;
        }
    }

    @("ResourceHttpRequestHandlerTests.ResourceLocationTests.shouldRejectInvalidPath")
    unittest
    {
        auto f = setup();
        // Use mock ResourceResolver: i.e. we're only testing upfront validations...
        Resource resource = new UnresolvableResource();
        ResourceResolver resolver = new StubResourceResolver(resource);

        f.handler.setLocations([testResource()]);
        f.handler.setResourceResolvers([resolver]);
        f.handler.setServletContext(new TestServletContext());
        f.handler.afterPropertiesSet();

        void testInvalidPath(string requestPath)
        {
            f.setPathWithinHandlerMapping(requestPath);
            f.response = new MockHttpServletResponse();
            f.assertNotFound();
        }

        testInvalidPath("../testsecret/secret.txt");
        testInvalidPath("test/../../testsecret/secret.txt");
        testInvalidPath(":/../../testsecret/secret.txt");
        testInvalidPath("/testsecret/test/../secret.txt");

        Resource location = new UrlResource(classPathUrl("test/"));
        f.handler.setLocations([location]);
        Resource secretResource = new UrlResource(classPathUrl("testsecret/secret.txt"));
        const secretPath = secretResource.getFile().getAbsolutePath();

        testInvalidPath("file:" ~ secretPath);
        testInvalidPath("/file:" ~ secretPath);
        testInvalidPath("url:" ~ secretPath);
        testInvalidPath("/url:" ~ secretPath);
        testInvalidPath("/../.." ~ secretPath);
        testInvalidPath("/%2E%2E/testsecret/secret.txt");
        testInvalidPath("/%2E%2E/testsecret/secret.txt");
    }

    @("ResourceHttpRequestHandlerTests.ResourceLocationTests.initAllowedLocations")
    unittest
    {
        auto f = setup();
        f.handler.afterPropertiesSet();
        auto resolver = cast(PathResourceResolver) f.handler.getResourceResolvers()[0];
        Resource[] locations = resolver.getAllowedLocations();

        assert(locations == [testResource(), testAlternatePathResource(), webjarsResource()]);
    }

    @("ResourceHttpRequestHandlerTests.ResourceLocationTests.initAllowedLocationsWithExplicitConfiguration")
    unittest
    {
        auto f = setup();
        auto pathResolver = new PathResourceResolver();
        pathResolver.setAllowedLocations(testResource());

        f.handler.setResourceResolvers([cast(ResourceResolver) pathResolver]);
        f.handler.setLocations([testResource(), testAlternatePathResource()]);
        f.handler.afterPropertiesSet();

        assert(pathResolver.getAllowedLocations() == [testResource()]);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// HttpCachingTests

// ResourceHttpRequestHandler has no HTTP caching (Last-Modified, cache seconds, ETag generator, conditional
// requests).
version (FlintResourceHttpCaching)
{
    import flint.http : HttpHeaders;
    import flint.jakarta.servlet.http : HttpServletResponse;

    /// `resourceLastModified(resourceName)`.
    private long resourceLastModified(string resourceName)
    {
        return new ClassPathResource(resourcePackage ~ resourceName).getFile().lastModified();
    }

    /// Spring's mock `addHeader(name, long)` formats the date as an HTTP date.
    private string httpDate(long date)
    {
        HttpHeaders headers;
        headers.setIfModifiedSince(date);
        return headers.getFirst(HttpHeaders.IF_MODIFIED_SINCE);
    }

    @("ResourceHttpRequestHandlerTests.HttpCachingTests.defaultCachingHeaders")
    unittest
    {
        auto f = setup();
        f.handler.afterPropertiesSet();
        f.setPathWithinHandlerMapping("foo.css");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.containsHeader("Last-Modified"));
        assert(f.response.getDateHeader("Last-Modified") / 1000 == resourceLastModified("test/foo.css") / 1000);
    }

    @("ResourceHttpRequestHandlerTests.HttpCachingTests.configureCacheSeconds")
    unittest
    {
        auto f = setup();
        f.handler.setCacheSeconds(3600);
        f.handler.afterPropertiesSet();
        f.setPathWithinHandlerMapping("foo.css");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getHeader("Cache-Control") == "max-age=3600");
    }

    @("ResourceHttpRequestHandlerTests.HttpCachingTests.configureCacheSecondsToZero")
    unittest
    {
        auto f = setup();
        f.handler.setCacheSeconds(0);
        f.handler.afterPropertiesSet();
        f.setPathWithinHandlerMapping("foo.css");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getHeader("Cache-Control") == "no-store");
    }

    @("ResourceHttpRequestHandlerTests.HttpCachingTests.shouldRespondWithNotModifiedWhenModifiedSince")
    unittest
    {
        auto f = setup();
        f.handler.setCacheSeconds(3600);
        f.handler.afterPropertiesSet();
        f.setPathWithinHandlerMapping("foo.css");
        f.request.addHeader("If-Modified-Since", httpDate(resourceLastModified("test/foo.css")));
        f.handler.handleRequest(f.request, f.response);
        assert(f.response.getStatus() == HttpServletResponse.SC_NOT_MODIFIED);
        assert(f.response.getHeader("Cache-Control") == "max-age=3600");
    }

    @("ResourceHttpRequestHandlerTests.HttpCachingTests.shouldRespondWithModifiedResource")
    unittest
    {
        auto f = setup();
        f.handler.afterPropertiesSet();
        f.setPathWithinHandlerMapping("foo.css");
        f.request.addHeader("If-Modified-Since", httpDate(resourceLastModified("test/foo.css") / 1000 * 1000 - 1));
        f.handler.handleRequest(f.request, f.response);
        assert(f.response.getStatus() == HttpServletResponse.SC_OK);
        assert(f.response.getContentAsString() == "h1 { color:red; }");
    }

    @("ResourceHttpRequestHandlerTests.HttpCachingTests.shouldRespondWithNotModifiedWhenEtag")
    unittest
    {
        auto f = setup();
        f.handler.setCacheSeconds(3600);
        f.handler.setEtagGenerator((Resource resource) => "testEtag");
        f.handler.afterPropertiesSet();
        f.setPathWithinHandlerMapping("foo.css");
        f.request.addHeader("If-None-Match", "\"testEtag\"");
        f.handler.handleRequest(f.request, f.response);
        assert(f.response.getStatus() == HttpServletResponse.SC_NOT_MODIFIED);
        assert(f.response.getHeader("Cache-Control") == "max-age=3600");
    }

    @("ResourceHttpRequestHandlerTests.HttpCachingTests.shouldRespondWithModifiedResourceWhenEtagNoMatch")
    unittest
    {
        auto f = setup();
        f.handler.setEtagGenerator((Resource resource) => "noMatch");
        f.handler.afterPropertiesSet();
        f.setPathWithinHandlerMapping("foo.css");
        f.request.addHeader("If-None-Match", "\"testEtag\"");
        f.handler.handleRequest(f.request, f.response);
        assert(f.response.getStatus() == HttpServletResponse.SC_OK);
        assert(f.response.getContentAsString() == "h1 { color:red; }");
    }

    @("ResourceHttpRequestHandlerTests.HttpCachingTests.shouldRespondWithNotModifiedWhenEtagAndLastModified")
    unittest
    {
        auto f = setup();
        f.handler.setEtagGenerator((Resource resource) => "testEtag");
        f.handler.afterPropertiesSet();
        f.setPathWithinHandlerMapping("foo.css");
        f.request.addHeader("If-None-Match", "\"testEtag\"");
        f.request.addHeader("If-Modified-Since", httpDate(resourceLastModified("test/foo.css")));
        f.handler.handleRequest(f.request, f.response);
        assert(f.response.getStatus() == HttpServletResponse.SC_NOT_MODIFIED);
    }

    // SPR-14005
    @("ResourceHttpRequestHandlerTests.HttpCachingTests.overwritesExistingCacheControlHeaders")
    unittest
    {
        auto f = setup();
        f.handler.setCacheSeconds(3600);
        f.handler.afterPropertiesSet();
        f.setPathWithinHandlerMapping("foo.css");
        f.response.setHeader("Cache-Control", "no-store");

        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getHeader("Cache-Control") == "max-age=3600");
    }

    @("ResourceHttpRequestHandlerTests.HttpCachingTests.ignoreLastModified")
    unittest
    {
        auto f = setup();
        f.setPathWithinHandlerMapping("foo.css");
        f.handler.setUseLastModified(false);
        f.handler.afterPropertiesSet();
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getContentType() == "text/css");
        assert(f.response.getContentLengthLong() == 17);
        assert(!f.response.containsHeader("Last-Modified"));
        assert(f.response.getContentAsString() == "h1 { color:red; }");
    }
}

// ---------------------------------------------------------------------------------------------------------------
// ResourceLocationTests

/// `ResourceHttpRequestHandlerTests.class.getResource(name)`: a `file:` URL on the first class path root holding
/// the package-relative `name`.
private string classPathUrl(string name)
{
    import flint.core.io : classPathRoots;
    import std.file : exists;
    import std.path : absolutePath, buildPath;

    foreach (root; classPathRoots())
    {
        const candidate = buildPath(root, resourcePackage, name);
        if (exists(candidate))
            return "file:" ~ absolutePath(candidate);
    }
    return null;
}

version (FlintResourceHandlerLocations)
{
    import flint.core.io : UrlResource;

    @("ResourceHttpRequestHandlerTests.ResourceLocationTests.servesResourcesFromAlternatePath")
    unittest
    {
        auto f = setup();
        f.handler.afterPropertiesSet();
        f.setPathWithinHandlerMapping("baz.css");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getContentType() == "text/css");
        assert(f.response.getContentLengthLong() == 17);
        assert(f.response.getContentAsString() == "h1 { color:red; }");
    }

    @("ResourceHttpRequestHandlerTests.ResourceLocationTests.servesResourcesFromSubDirectory")
    unittest
    {
        auto f = setup();
        f.handler.afterPropertiesSet();
        f.setPathWithinHandlerMapping("js/foo.js");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getContentType() == "text/javascript");
        assert(f.response.getContentAsString() == "function foo() { console.log(\"hello world\"); }");
    }

    @("ResourceHttpRequestHandlerTests.ResourceLocationTests.servesResourcesFromSubDirectoryOfAlternatePath")
    unittest
    {
        auto f = setup();
        f.handler.afterPropertiesSet();
        f.setPathWithinHandlerMapping("js/baz.js");
        f.handler.handleRequest(f.request, f.response);

        assert(f.response.getContentType() == "text/javascript");
        assert(f.response.getContentAsString() == "function foo() { console.log(\"hello world\"); }");
    }

    // gh-27538, gh-27624
    @("ResourceHttpRequestHandlerTests.ResourceLocationTests.filterNonExistingLocations")
    unittest
    {
        import std.algorithm.searching : endsWith;

        auto f = setup();
        Resource[] inputLocations = [
            testResource(), testAlternatePathResource(),
            new ClassPathResource(resourcePackage ~ "nosuchpath/")
        ];
        f.handler.setLocations(inputLocations);
        f.handler.setOptimizeLocations(true);
        f.handler.afterPropertiesSet();

        Resource[] actual = f.handler.getLocations();
        assert(actual.length == 2);
        // Spring: getURL().toString(); flint.core.io offers no URLs.
        assert((cast(ClassPathResource) actual[0]).getPath().endsWith("test/"));
        assert((cast(ClassPathResource) actual[1]).getPath().endsWith("testalternatepath/"));
    }

    @("ResourceHttpRequestHandlerTests.ResourceLocationTests.shouldRejectPathWithTraversal")
    unittest
    {
        auto f = setup();
        f.handler.afterPropertiesSet();

        void testResolvePathWithTraversal(Resource location, string requestPath)
        {
            f.setPathWithinHandlerMapping(requestPath);
            f.response = new MockHttpServletResponse();
            f.assertNotFound();
        }

        void shouldRejectPathWithTraversal(HttpMethod httpMethod)
        {
            f.request.setMethod(httpMethod.name());

            Resource location = new ClassPathResource(resourcePackage ~ "test/");
            f.handler.setLocations([location]);

            testResolvePathWithTraversal(location, "../testsecret/secret.txt");
            testResolvePathWithTraversal(location, "test/../../testsecret/secret.txt");
            testResolvePathWithTraversal(location, ":/../../testsecret/secret.txt");

            location = new UrlResource(classPathUrl("./test/"));
            f.handler.setLocations([location]);
            Resource secretResource = new UrlResource(classPathUrl("testsecret/secret.txt"));
            const secretPath = secretResource.getFile().getAbsolutePath();

            testResolvePathWithTraversal(location, "file:" ~ secretPath);
            testResolvePathWithTraversal(location, "/file:" ~ secretPath);
            testResolvePathWithTraversal(location, "url:" ~ secretPath);
            testResolvePathWithTraversal(location, "/url:" ~ secretPath);
            testResolvePathWithTraversal(location, "/" ~ secretPath);
            testResolvePathWithTraversal(location, "////../.." ~ secretPath);
            testResolvePathWithTraversal(location, "/%2E%2E/testsecret/secret.txt");
            testResolvePathWithTraversal(location, "%2F%2F%2E%2E%2F%2Ftestsecret/secret.txt");
            testResolvePathWithTraversal(location, "/  " ~ secretPath);
        }

        foreach (method; HttpMethod.values())
        {
            f.request = new MockHttpServletRequest("GET", "");
            f.response = new MockHttpServletResponse();
            shouldRejectPathWithTraversal(method);
        }
    }

    @("ResourceHttpRequestHandlerTests.ResourceLocationTests.servletContextRootValidation")
    unittest
    {
        import flint.core.io : FileSystemResource;
        import flint.java.lang : IllegalStateException;
        import flint.web.context.support : StaticWebApplicationContext;
        import std.exception : collectException;

        auto context = new class StaticWebApplicationContext
        {
            override Resource getResource(string location)
            {
                return new FileSystemResource("/");
            }
        };

        auto handler = new ResourceHttpRequestHandler();
        handler.setLocationValues(["/"]);
        handler.setApplicationContext(context);

        auto ex = collectException!IllegalStateException(handler.afterPropertiesSet());
        assert(ex !is null);
        assert(ex.msg == "The String-based location \"/\" should be relative to the web application root but "
                ~ "resolved to a Resource of type: class flint.core.io.FileSystemResource. "
                ~ "If this is intentional, please pass it as a pre-configured Resource via setLocations.");
    }
}

@("ResourceHttpRequestHandlerTests.ResourceLocationTests.ignoreInvalidEscapeSequence")
unittest
{
    auto f = setup();
    version (FlintResourceHandlerLocations)
        f.handler.afterPropertiesSet();
    f.setPathWithinHandlerMapping("/%foo%/bar.txt");
    f.response = new MockHttpServletResponse();
    f.assertNotFound();
}

// ResourceHttpRequestHandler has no processPath (leading control character and duplicate slash normalization).
version (FlintResourcePathProcessing)
{
    @("ResourceHttpRequestHandlerTests.ResourceLocationTests.processPath")
    unittest
    {
        auto f = setup();
        // Unchanged
        const unchanged = "/foo/bar";
        assert(f.handler.processPath(unchanged) is unchanged);
        const relative = "foo/bar";
        assert(f.handler.processPath(relative) is relative);

        // leading whitespace control characters (00-1F)
        assert(f.handler.processPath("  /foo/bar") == "/foo/bar");
        assert(f.handler.processPath("\x01/foo/bar") == "/foo/bar");
        assert(f.handler.processPath("\x1F/foo/bar") == "/foo/bar");
        assert(f.handler.processPath("  foo/bar") == "foo/bar");
        assert(f.handler.processPath("\x1Ffoo/bar") == "foo/bar");

        // leading control character 0x7F (DEL)
        assert(f.handler.processPath("\x7F/foo/bar") == "/foo/bar");
        assert(f.handler.processPath("\x7F/foo/bar") == "/foo/bar");

        // leading control and '/' characters
        assert(f.handler.processPath("  /  foo/bar") == "/foo/bar");
        assert(f.handler.processPath("  /  /  foo/bar") == "/foo/bar");
        assert(f.handler.processPath("  // /// ////  foo/bar") == "/foo/bar");
        assert(f.handler.processPath("\x01 / \x7F // foo/bar") == "/foo/bar");

        // root or empty path
        assert(f.handler.processPath("   ").length == 0);
        assert(f.handler.processPath("/") == "/");
        assert(f.handler.processPath("///") == "/");
        assert(f.handler.processPath("/ /   / ") == "/");
        assert(f.handler.processPath(`\/ \/   \/ `) == "/");

        // duplicate slash or backslash
        assert(f.handler.processPath("//foo/ /bar//baz//") == "/foo/ /bar/baz/");
        assert(f.handler.processPath(`\\foo\ \bar\\baz\\`) == "/foo/ /bar/baz/");
        assert(f.handler.processPath(`foo\\/\////bar`) == "foo/bar");
    }
}

@("ResourceHttpRequestHandlerTests.ResourceLocationTests.shouldNotServeDirectory")
unittest
{
    auto f = setup();
    version (FlintResourceHandlerLocations)
        f.handler.afterPropertiesSet();
    f.setPathWithinHandlerMapping("js/");
    f.assertNotFound();
}

@("ResourceHttpRequestHandlerTests.ResourceLocationTests.shouldNotServeDirectoryInJarFile")
unittest
{
    auto f = setup();
    version (FlintResourceHandlerLocations)
        f.handler.afterPropertiesSet();
    f.setPathWithinHandlerMapping("underscorejs/");
    f.assertNotFound();
}

@("ResourceHttpRequestHandlerTests.ResourceLocationTests.shouldNotServeMissingResourcePath")
unittest
{
    auto f = setup();
    version (FlintResourceHandlerLocations)
        f.handler.afterPropertiesSet();
    f.setPathWithinHandlerMapping("");
    f.assertNotFound();
}

// Behaviour: without PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE the port falls back to the lookup path and answers
// NoResourceFoundException instead of Spring's IllegalStateException (required request attribute not set).
version (FlintResourcePathWithinMappingRequired)
{
    @("ResourceHttpRequestHandlerTests.ResourceLocationTests.noPathWithinHandlerMappingAttribute")
    unittest
    {
        import flint.java.lang : IllegalStateException;

        auto f = setup();
        version (FlintResourceHandlerLocations)
            f.handler.afterPropertiesSet();
        assertThrown!IllegalStateException(f.handler.handleRequest(f.request, f.response));
    }
}
