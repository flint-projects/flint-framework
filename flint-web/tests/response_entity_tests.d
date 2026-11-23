/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/http/ResponseEntityTests.java and ProblemDetailTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; `getBody()`
equality reads the erased body back with `getBody!T` (ADR-030 section 5).
Excluded until `CacheControl` is ported (deferred, web slice 2): emptyCacheControl, cacheControl,
cacheControlNoCache. ProblemDetailTests.equalsAndHashCode's Jackson round trip waits for flint.jackson.
+/
module flint.http.response_entity_tests;

import flint.http : HttpHeaders, HttpMethod, HttpStatus, HttpStatusCode, MediaType, ProblemDetail, ResponseEntity;
import flint.java.net : URI;
import flint.java.util : Optional;

@safe:

@("ResponseEntityTests.normal")
unittest
{
    auto responseEntity = ResponseEntity.status(HttpStatus.OK.code()).header("My-Custom-Header", "HeaderValue1",
            "HeaderValue2").body(42);
    assert(responseEntity.getStatusCode() == HttpStatus.OK);
    assert(responseEntity.getHeaders().containsHeader("My-Custom-Header"));
    assert(responseEntity.getHeaders().get("My-Custom-Header") == ["HeaderValue1", "HeaderValue2"]);
    assert(responseEntity.getBody!int() == 42);
}

@("ResponseEntityTests.okNoBody")
unittest
{
    auto responseEntity = ResponseEntity.ok().build();
    assert(responseEntity.getStatusCode() == HttpStatus.OK);
    assert(responseEntity.getBody().isNull());
}

@("ResponseEntityTests.okEntity")
unittest
{
    auto responseEntity = ResponseEntity.ok(42);
    assert(responseEntity.getStatusCode() == HttpStatus.OK);
    assert(responseEntity.getBody!int() == 42);
}

@("ResponseEntityTests.ofOptional")
unittest
{
    auto responseEntity = ResponseEntity.of(Optional!int.of(42));
    assert(responseEntity.getStatusCode() == HttpStatus.OK);
    assert(responseEntity.getBody!int() == 42);
}

@("ResponseEntityTests.ofEmptyOptional")
unittest
{
    auto responseEntity = ResponseEntity.of(Optional!int.empty());
    assert(responseEntity.getStatusCode() == HttpStatus.NOT_FOUND);
    assert(responseEntity.getBody().isNull());
}

@("ResponseEntityTests.ofNullable")
unittest
{
    auto responseEntity = ResponseEntity.ofNullable(42);
    assert(responseEntity.getStatusCode() == HttpStatus.OK);
    assert(responseEntity.getBody!int() == 42);
}

@("ResponseEntityTests.ofNullNullable")
unittest
{
    Object nothing = null;
    auto responseEntity = ResponseEntity.ofNullable(nothing);
    assert(responseEntity.getStatusCode() == HttpStatus.NOT_FOUND);
    assert(responseEntity.getBody().isNull());
}

@("ResponseEntityTests.createdLocation")
unittest
{
    URI location = URI.create("location");
    auto responseEntity = ResponseEntity.created(location).build();
    assert(responseEntity.getStatusCode() == HttpStatus.CREATED);
    assert(responseEntity.getHeaders().containsHeader(HttpHeaders.LOCATION));
    assert(responseEntity.getHeaders().getFirst(HttpHeaders.LOCATION) == location.toString());
    assert(responseEntity.getBody().isNull());
    ResponseEntity.created(location).header("MyResponseHeader", "MyValue").body("Hello World");
}

@("ResponseEntityTests.acceptedNoBody, acceptedNoBodyWithAlternativeBodyType, noContent, badRequest, notFound")
unittest
{
    assert(ResponseEntity.accepted().build().getStatusCode() == HttpStatus.ACCEPTED);
    assert(ResponseEntity.accepted().build().getBody().isNull());
    assert(ResponseEntity.noContent().build().getStatusCode() == HttpStatus.NO_CONTENT);
    assert(ResponseEntity.badRequest().build().getStatusCode() == HttpStatus.BAD_REQUEST);
    assert(ResponseEntity.notFound().build().getStatusCode() == HttpStatus.NOT_FOUND);
    assert(ResponseEntity.notFound().build().getBody().isNull());
}

@("ResponseEntityTests.unprocessableContent, unprocessableEntity, internalServerError")
unittest
{
    auto content = ResponseEntity.unprocessableContent().body("error");
    assert(content.getStatusCode() == HttpStatus.UNPROCESSABLE_CONTENT && content.getBody!string() == "error");
    auto entity = ResponseEntity.status(422).body("error");
    assert(entity.getStatusCode().value() == 422 && entity.getBody!string() == "error");
    auto internal = ResponseEntity.internalServerError().body("error");
    assert(internal.getStatusCode() == HttpStatus.INTERNAL_SERVER_ERROR && internal.getBody!string() == "error");
}

@("ResponseEntityTests.headers")
unittest
{
    URI location = URI.create("location");
    long contentLength = 67_890;
    MediaType contentType = MediaType.TEXT_PLAIN;
    auto responseEntity = ResponseEntity.ok()
        .allow(HttpMethod.GET)
        .lastModified(12_345L)
        .location(location)
        .contentLength(contentLength)
        .contentType(contentType)
        .headers((HttpHeaders headers) { assert(headers.size() == 5); })
        .build();
    assert(responseEntity.getStatusCode() == HttpStatus.OK);
    HttpHeaders responseHeaders = responseEntity.getHeaders();
    assert(responseHeaders.getFirst(HttpHeaders.ALLOW) == HttpMethod.GET.name());
    assert(responseHeaders.getFirst(HttpHeaders.LAST_MODIFIED) == "Thu, 01 Jan 1970 00:00:12 GMT");
    assert(responseHeaders.getFirst(HttpHeaders.LOCATION) == location.toASCIIString());
    assert(responseHeaders.getFirst(HttpHeaders.CONTENT_LENGTH) == "67890");
    assert(responseHeaders.getFirst(HttpHeaders.CONTENT_TYPE) == contentType.toString());
    assert(responseEntity.getBody().isNull());
}

@("ResponseEntityTests.Etagheader")
unittest
{
    assert(ResponseEntity.ok().eTag("\"foo\"").build().getHeaders().getETag() == "\"foo\"");
    assert(ResponseEntity.ok().eTag("foo").build().getHeaders().getETag() == "\"foo\"");
    assert(ResponseEntity.ok().eTag("W/\"foo\"").build().getHeaders().getETag() == "W/\"foo\"");
    assert(ResponseEntity.ok().eTag(null).build().getHeaders().getETag() is null);
}

@("ResponseEntityTests.headersCopy")
unittest
{
    auto customHeaders = HttpHeaders.create();
    customHeaders.set("X-CustomHeader", "vale");
    auto responseEntity = ResponseEntity.ok().headers(customHeaders).build();
    HttpHeaders responseHeaders = responseEntity.getHeaders();
    assert(responseEntity.getStatusCode() == HttpStatus.OK);
    assert(responseHeaders.size() == 1);
    assert(responseHeaders.get("X-CustomHeader").length == 1);
    assert(responseHeaders.getFirst("X-CustomHeader") == "vale");
}

@("ResponseEntityTests.headersCopyWithEmptyAndNull")
unittest
{
    auto withEmpty = ResponseEntity.ok().headers(HttpHeaders.create()).build();
    auto withNull = ResponseEntity.ok().headers(HttpHeaders.init).build(); // R7: typed null
    assert(withEmpty.getStatusCode() == HttpStatus.OK);
    assert(withEmpty.getHeaders().isEmpty());
    assert(withNull.toString() == withEmpty.toString());
    assert(withEmpty.toString() == "<200 OK OK,[]>");
}

@("ResponseEntityTests.statusCodeAsInt and customStatusCode")
unittest
{
    auto ok = ResponseEntity.status(200).body(42);
    assert(ok.getStatusCode().value() == 200 && ok.getBody!int() == 42);
    auto custom = ResponseEntity.status(299).body(42);
    assert(custom.getStatusCode().value() == 299 && custom.getBody!int() == 42);
}

@("ResponseEntity.of(ProblemDetail) builds the problem as the body with its status")
unittest
{
    auto problem = ProblemDetail.forStatusAndDetail(HttpStatus.BAD_REQUEST, "bad");
    auto entity = ResponseEntity.of(problem).header("X", "y").build();
    assert(entity.getStatusCode() == HttpStatus.BAD_REQUEST);
    assert(entity.getBody!ProblemDetail() is problem);
    assert(entity.getHeaders().getFirst("X") == "y");
}

@("ProblemDetailTests.equalsAndHashCode")
unittest
{
    ProblemDetail pd1 = ProblemDetail.forStatus(500);
    ProblemDetail pd2 = ProblemDetail.forStatus(HttpStatus.INTERNAL_SERVER_ERROR);
    ProblemDetail pd3 = ProblemDetail.forStatus(HttpStatus.NOT_FOUND);
    ProblemDetail pd4 = ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, "some detail");
    assert(pd1 == pd2 && pd2 == pd1);
    assert(pd1.toHash() == pd2.toHash());
    assert(pd3 != pd1 && pd4 != pd3 && pd4 != pd1);
    assert(pd3.toHash() != pd1.toHash() && pd4.toHash() != pd3.toHash() && pd4.toHash() != pd1.toHash());
}

@("ProblemDetail defaults: no type, title from the status, Java's toString")
unittest
{
    auto pd = ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, "No static resource nope.");
    assert(pd.getType() is null);
    assert(pd.getTitle() == "Not Found");
    assert(pd.toString() == "ProblemDetail[type='null', title='Not Found', status=404, "
            ~ "detail='No static resource nope.', instance='null', properties='null']");
    pd.setProperty("timestamp", 7);
    assert(pd.getPropertyNames() == ["timestamp"] && pd.getProperty("timestamp").get!int() == 7);
    assert(ProblemDetail.forStatus(499).getTitle() is null);
}
