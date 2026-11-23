/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/http/HttpHeadersTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts.

Excluded until their types are ported (deferred, Phase 1 web slice 2): acceptCharsets, acceptCharsetWildcard
(Charset lists), host, hostNoPort, ipv6Host, hostDeletion (InetSocketAddress), ifMatch*, ifNoneMatch*
(ETag), pragma, cacheControlBuilder, cacheControlEmpty (CacheControl), contentDisposition, acceptLanguage*,
contentLanguage* (Locale), expiresZonedDateTime, firstZonedDateTime (java.time), the keySet/entrySet live-view
tests (Java collection views; HttpHeaders.headerNames returns a snapshot, R10).
+/
module flint.http.http_headers_tests;

import flint.http : HttpHeaders, HttpMethod, MediaType;
import flint.java.lang : IllegalArgumentException, UnsupportedOperationException;
import flint.java.net : URI;
import flint.java.nio.charset : StandardCharsets;

@safe:

private void assertThrows(E)(scope void delegate() @safe action)
{
    bool thrown;
    try
        action();
    catch (E)
        thrown = true;
    assert(thrown, "expected " ~ E.stringof);
}

// new GregorianCalendar(2008, 11, 18, 11, 20) in CET.
private enum long dec18 = 1_229_595_600_000L;

@("HttpHeadersTests.constructorUnwrapsReadonly")
unittest
{
    auto headers = HttpHeaders.create();
    headers.setContentType(MediaType.APPLICATION_JSON);
    HttpHeaders readOnly = HttpHeaders.readOnlyHttpHeaders(headers);
    assert(*readOnly.getContentType() == MediaType.APPLICATION_JSON);
    HttpHeaders writable = HttpHeaders(readOnly);
    writable.setContentType(MediaType.TEXT_PLAIN);
    // Java's ReadOnlyHttpHeaders caches its content type; this port's view reads through (no cache).
    assert(*writable.getContentType() == MediaType.TEXT_PLAIN);
    assert(*headers.getContentType() == MediaType.TEXT_PLAIN);
    assertThrows!UnsupportedOperationException(() { readOnly.set("A", "b"); });
}

@("HttpHeadersTests.writableHttpHeadersUnwrapsMultiple")
unittest
{
    HttpHeaders originalExchangeHeaders = HttpHeaders.readOnlyHttpHeaders(HttpHeaders.create());
    HttpHeaders firewallHeaders = HttpHeaders(originalExchangeHeaders);
    HttpHeaders writable = HttpHeaders(firewallHeaders);
    writable.setContentType(MediaType.APPLICATION_JSON);
}

@("HttpHeadersTests.copyOfCopiesHeaders")
unittest
{
    auto headers = HttpHeaders.create();
    headers.setContentType(MediaType.APPLICATION_JSON);
    headers.add("X-Project", "Spring");
    headers.add("X-Project", "Framework");
    HttpHeaders readOnly = HttpHeaders.readOnlyHttpHeaders(headers);
    assert(*readOnly.getContentType() == MediaType.APPLICATION_JSON);
    HttpHeaders writable = HttpHeaders.copyOf(readOnly);
    writable.setContentType(MediaType.TEXT_PLAIN);
    assert(*readOnly.getContentType() == MediaType.APPLICATION_JSON);
    assert(*writable.getContentType() == MediaType.TEXT_PLAIN);
    assert(writable.get("X-Project") == ["Spring", "Framework"]);
}

@("HttpHeadersTests.getOrEmpty")
unittest
{
    HttpHeaders headers;
    assert(headers.get("FOO") is null);
    assert(headers.getOrEmpty("FOO").length == 0);
    headers.add("FOO", "bar");
    assert(headers.getOrEmpty("FOO") == ["bar"]);
    headers.remove("FOO");
    assert(headers.get("FOO") is null);
    assert(headers.getOrEmpty("FOO").length == 0);
}

@("HttpHeadersTests.getFirst")
unittest
{
    HttpHeaders headers;
    headers.add(HttpHeaders.CACHE_CONTROL, "max-age=1000, public");
    headers.add(HttpHeaders.CACHE_CONTROL, "s-maxage=1000");
    assert(headers.getFirst(HttpHeaders.CACHE_CONTROL) == "max-age=1000, public");
}

@("HttpHeadersTests.accept")
unittest
{
    HttpHeaders headers;
    MediaType[] mediaTypes = [MediaType("text", "html"), MediaType("text", "plain")];
    headers.setAccept(mediaTypes);
    assert(headers.getAccept() == mediaTypes, "Invalid Accept header");
    assert(headers.getFirst("Accept") == "text/html, text/plain", "Invalid Accept header");
}

@("HttpHeadersTests.acceptWithMultipleHeaderValues")
unittest
{
    HttpHeaders headers;
    headers.add("Accept", "text/html");
    headers.add("Accept", "text/plain");
    assert(headers.getAccept() == [MediaType("text", "html"), MediaType("text", "plain")]);
}

@("HttpHeadersTests.acceptWithMultipleCommaSeparatedHeaderValues")
unittest
{
    HttpHeaders headers;
    headers.add("Accept", "text/html,text/pdf");
    headers.add("Accept", "text/plain,text/csv");
    assert(headers.getAccept() == [MediaType("text", "html"), MediaType("text", "pdf"),
            MediaType("text", "plain"), MediaType("text", "csv")]);
}

@("HttpHeadersTests.allow")
unittest
{
    HttpHeaders headers;
    HttpMethod[] methods = [HttpMethod.GET, HttpMethod.POST];
    headers.setAllow(methods);
    assert(headers.getAllow() == methods, "Invalid Allow header");
    assert(headers.getFirst("Allow") == "GET,POST", "Invalid Allow header");
}

@("HttpHeadersTests.contentLength")
unittest
{
    HttpHeaders headers;
    headers.setContentLength(42L);
    assert(headers.getContentLength() == 42L);
    assert(headers.getFirst("Content-Length") == "42");
}

@("HttpHeadersTests.setContentLengthWithNegativeValue")
unittest
{
    HttpHeaders headers;
    assertThrows!IllegalArgumentException(() { headers.setContentLength(-1); });
}

@("HttpHeadersTests.getContentLengthReturnsMinusOneForAbsentHeader")
unittest
{
    HttpHeaders headers;
    assert(headers.getContentLength() == -1);
}

@("HttpHeadersTests.contentType")
unittest
{
    HttpHeaders headers;
    MediaType contentType = MediaType("text", "html", StandardCharsets.UTF_8);
    headers.setContentType(contentType);
    assert(*headers.getContentType() == contentType);
    assert(headers.getFirst("Content-Type") == "text/html;charset=UTF-8");
}

@("HttpHeadersTests.location")
unittest
{
    HttpHeaders headers;
    URI location = URI.create("https://www.example.com/hotels");
    headers.setLocation(location);
    assert(*headers.getLocation() == location);
    assert(headers.getFirst("Location") == "https://www.example.com/hotels");
}

@("HttpHeadersTests.eTag")
unittest
{
    HttpHeaders headers;
    headers.setETag("\"v2.6\"");
    assert(headers.getETag() == "\"v2.6\"");
    assert(headers.getFirst("ETag") == "\"v2.6\"");
}

@("HttpHeadersTests.eTagWithoutQuotes")
unittest
{
    HttpHeaders headers;
    headers.setETag("v2.6");
    assert(headers.getETag() == "\"v2.6\"");
}

@("HttpHeadersTests.weakETagWithoutLeadingQuote")
unittest
{
    HttpHeaders headers;
    headers.setETag("W/v2.6\"");
    assert(headers.getETag() == "\"W/v2.6\"\"");
}

@("HttpHeadersTests.date")
unittest
{
    HttpHeaders headers;
    headers.setDate(dec18);
    assert(headers.getDate() == dec18, "Invalid Date header");
    assert(headers.getFirst("date") == "Thu, 18 Dec 2008 10:20:00 GMT", "Invalid Date header");
    headers.set("Date", "Thu, 18 Dec 2008 10:20:00 GMT");
    assert(headers.getDate() == dec18, "Invalid Date header");
}

@("HttpHeadersTests.dateInvalid")
unittest
{
    HttpHeaders headers;
    headers.set("Date", "Foo Bar Baz");
    assertThrows!IllegalArgumentException(() { headers.getDate(); });
}

@("HttpHeadersTests.dateOtherLocale")
unittest
{
    // D has no default locale; the formatter always uses English names, which is what the test asserts.
    HttpHeaders headers;
    headers.setDate(dec18);
    assert(headers.getFirst("date") == "Thu, 18 Dec 2008 10:20:00 GMT");
    assert(headers.getDate() == dec18);
}

@("HttpHeadersTests.lastModified")
unittest
{
    HttpHeaders headers;
    headers.setLastModified(dec18);
    assert(headers.getLastModified() == dec18);
    assert(headers.getFirst("last-modified") == "Thu, 18 Dec 2008 10:20:00 GMT");
}

@("HttpHeadersTests.expiresLong")
unittest
{
    HttpHeaders headers;
    headers.setExpires(dec18);
    assert(headers.getExpires() == dec18);
    assert(headers.getFirst("expires") == "Thu, 18 Dec 2008 10:20:00 GMT");
}

@("HttpHeadersTests.expiresInvalidDate")
unittest
{
    HttpHeaders headers;
    headers.set("Expires", "-1");
    assert(headers.getExpires() == -1);
}

@("HttpHeadersTests.ifModifiedSince")
unittest
{
    HttpHeaders headers;
    headers.setIfModifiedSince(dec18);
    assert(headers.getIfModifiedSince() == dec18);
    assert(headers.getFirst("if-modified-since") == "Thu, 18 Dec 2008 10:20:00 GMT");
}

@("HttpHeadersTests.invalidIfModifiedSinceHeader")
unittest
{
    HttpHeaders headers;
    foreach (value; ["0", "-1", "XXX"])
    {
        headers.set(HttpHeaders.IF_MODIFIED_SINCE, value);
        assert(headers.getIfModifiedSince() == -1);
    }
}

@("HttpHeadersTests.cacheControl")
unittest
{
    HttpHeaders headers;
    headers.setCacheControl("no-cache");
    assert(headers.getCacheControl() == "no-cache");
    assert(headers.getFirst("cache-control") == "no-cache");
}

@("HttpHeadersTests.cacheControlAllValues")
unittest
{
    HttpHeaders headers;
    headers.add(HttpHeaders.CACHE_CONTROL, "max-age=1000, public");
    headers.add(HttpHeaders.CACHE_CONTROL, "s-maxage=1000");
    assert(headers.getCacheControl() == "max-age=1000, public, s-maxage=1000");
}

@("HttpHeadersTests.getAllowEmptySet")
unittest
{
    HttpHeaders headers;
    headers.setAllow([]);
    assert(headers.getAllow().length == 0);
}

@("HttpHeadersTests.accessControlAllowCredentials")
unittest
{
    HttpHeaders headers;
    assert(!headers.getAccessControlAllowCredentials());
    headers.setAccessControlAllowCredentials(false);
    assert(!headers.getAccessControlAllowCredentials());
    headers.setAccessControlAllowCredentials(true);
    assert(headers.getAccessControlAllowCredentials());
}

@("HttpHeadersTests.accessControlAllowHeaders")
unittest
{
    HttpHeaders headers;
    assert(headers.getAccessControlAllowHeaders().length == 0);
    headers.setAccessControlAllowHeaders(["header1", "header2"]);
    assert(headers.getAccessControlAllowHeaders() == ["header1", "header2"]);
}

@("HttpHeadersTests.accessControlAllowHeadersMultipleValues")
unittest
{
    HttpHeaders headers;
    assert(headers.getAccessControlAllowHeaders().length == 0);
    headers.add(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS, "header1, header2");
    headers.add(HttpHeaders.ACCESS_CONTROL_ALLOW_HEADERS, "header3");
    assert(headers.getAccessControlAllowHeaders() == ["header1", "header2", "header3"]);
}

@("HttpHeadersTests.accessControlAllowMethods")
unittest
{
    HttpHeaders headers;
    assert(headers.getAccessControlAllowMethods().length == 0);
    headers.setAccessControlAllowMethods([HttpMethod.GET, HttpMethod.POST]);
    assert(headers.getAccessControlAllowMethods() == [HttpMethod.GET, HttpMethod.POST]);
}

@("HttpHeadersTests.accessControlAllowOrigin")
unittest
{
    HttpHeaders headers;
    assert(headers.getAccessControlAllowOrigin() is null);
    headers.setAccessControlAllowOrigin("*");
    assert(headers.getAccessControlAllowOrigin() == "*");
}

@("HttpHeadersTests.accessControlExposeHeaders")
unittest
{
    HttpHeaders headers;
    assert(headers.getAccessControlExposeHeaders().length == 0);
    headers.setAccessControlExposeHeaders(["header1", "header2"]);
    assert(headers.getAccessControlExposeHeaders() == ["header1", "header2"]);
}

@("HttpHeadersTests.accessControlMaxAge")
unittest
{
    HttpHeaders headers;
    assert(headers.getAccessControlMaxAge() == -1);
    headers.setAccessControlMaxAge(3600);
    assert(headers.getAccessControlMaxAge() == 3600);
}

@("HttpHeadersTests.accessControlRequestHeaders")
unittest
{
    HttpHeaders headers;
    assert(headers.getAccessControlRequestHeaders().length == 0);
    headers.setAccessControlRequestHeaders(["header1", "header2"]);
    assert(headers.getAccessControlRequestHeaders() == ["header1", "header2"]);
}

@("HttpHeadersTests.accessControlRequestMethod")
unittest
{
    HttpHeaders headers;
    assert(headers.getAccessControlRequestMethod() is null);
    auto post = HttpMethod.POST;
    headers.setAccessControlRequestMethod(&post);
    assert(*headers.getAccessControlRequestMethod() == HttpMethod.POST);
}

@("HttpHeadersTests.firstDate")
unittest
{
    HttpHeaders headers;
    headers.setDate(HttpHeaders.DATE, 1_496_370_120_000L);
    assert(headers.getFirstDate(HttpHeaders.DATE) == 1_496_370_120_000L);
    headers.clear();
    headers.add(HttpHeaders.DATE, "Fri, 02 Jun 2017 02:22:00 GMT");
    headers.add(HttpHeaders.DATE, "Sat, 18 Dec 2010 10:20:00 GMT");
    assert(headers.getFirstDate(HttpHeaders.DATE) == 1_496_370_120_000L);
    // firstZonedDateTime's legacy forms, through getFirstDate
    headers.set(HttpHeaders.DATE, "Friday, 02-Jun-17 02:22:00 GMT");
    assert(headers.getFirstDate(HttpHeaders.DATE) == 1_496_370_120_000L);
    headers.set(HttpHeaders.DATE, "Fri Jun 02 02:22:00 2017");
    assert(headers.getFirstDate(HttpHeaders.DATE) == 1_496_370_120_000L);
}

@("HttpHeadersTests.basicAuth")
unittest
{
    import std.base64 : Base64;

    HttpHeaders headers;
    headers.setBasicAuth("foo", "bar");
    const authorization = headers.getFirst(HttpHeaders.AUTHORIZATION);
    assert(authorization !is null && authorization[0 .. 6] == "Basic ");
    assert(cast(const(char)[]) Base64.decode(authorization[6 .. $]) == "foo:bar");
}

@("HttpHeadersTests.basicAuthIllegalChar")
unittest
{
    HttpHeaders headers;
    assertThrows!IllegalArgumentException(() { headers.setBasicAuth("foo", "λ"); });
}

@("HttpHeadersTests.bearerAuth")
unittest
{
    HttpHeaders headers;
    headers.setBearerAuth("foo");
    assert(headers.getFirst(HttpHeaders.AUTHORIZATION) == "Bearer foo");
}

@("HttpHeadersTests.rfc9651Dates_valid")
unittest
{
    HttpHeaders headers;
    foreach (row; [["@0", "0"], ["@1", "1000"], ["@10", "10000"], ["@-1", "-1000"],
            ["@1659578233", "1659578233000"], ["@-62135596800", "-62135596800000"],
            ["@253402214400", "253402214400000"]])
    {
        import std.conv : to;

        headers.set("Deprecation", row[0]);
        assert(headers.getFirstDate("Deprecation") == row[1].to!long);
    }
}

@("HttpHeadersTests.rfc9651Dates_invalid")
unittest
{
    HttpHeaders headers;
    foreach (value; ["@", " @1", "@ 1", "@0000-", "@15+", "@12p", "@0x15"])
    {
        headers.set("Deprecation", value);
        assertThrows!IllegalArgumentException(() { headers.getFirstDate("Deprecation"); });
    }
}

@("HttpHeadersTests.equalsUnwrapsHttpHeaders")
unittest
{
    auto headers1 = HttpHeaders.create();
    auto headers2 = HttpHeaders(headers1);
    headers1.set("foo", "bar");
    assert(headers1 == headers2);
    assert(headers2 == headers1);
}

@("HttpHeadersTests.getValuesAsList")
unittest
{
    HttpHeaders headers;
    headers.add("Foo", "Bar");
    headers.add("Foo", "Baz, Qux");
    headers.add("Quux", "\t\"Corge\", \"Grault\"");
    headers.add("Garply", " Waldo \"Fred\\!\", \"\tPlugh, Xyzzy! \"");
    headers.add("Example-Dates", "\"Sat, 04 May 1996\", \"Wed, 14 Sep 2005\"");
    assert(headers.getValuesAsList("Foo") == ["Bar", "Baz", "Qux"]);
    assert(headers.getValuesAsList("Quux") == ["Corge", "Grault"]);
    assert(headers.getValuesAsList("Garply") == ["Waldo \"Fred\\!\"", "\tPlugh, Xyzzy! "]);
    assert(headers.getValuesAsList("Example-Dates") == ["Sat, 04 May 1996", "Wed, 14 Sep 2005"]);
}

@("HttpHeaders keeps LinkedCaseInsensitiveMap order and case rules")
unittest
{
    HttpHeaders headers;
    headers.add("Content-Type", "a");
    headers.add("X-One", "1");
    headers.add("content-type", "b"); // add keeps the first spelling and position
    assert(headers.headerNames() == ["Content-Type", "X-One"]);
    assert(headers.get("CONTENT-TYPE") == ["a", "b"]);
    headers.set("content-type", "c"); // put with another case moves the name to the end
    assert(headers.headerNames() == ["X-One", "content-type"]);
    headers.set("X-One", "2"); // same case keeps the position
    assert(headers.headerNames() == ["X-One", "content-type"]);
    assert(headers.toString() == "[X-One:\"2\", content-type:\"c\"]");
}
