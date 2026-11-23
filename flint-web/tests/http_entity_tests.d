/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/http/HttpEntityTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; `new HttpEntity<>(body)`
is `HttpEntity.of(body)` and a null body is the default `HttpEntity` (the erased entity of the web-mvc design).
+/
module flint.http.http_entity_tests;

import flint.http : HttpEntity, HttpHeaders, HttpMethod, HttpStatus, MediaType, RequestEntity, ResponseEntity;
import flint.java.net : URI;

@safe:

@("HttpEntityTests.noHeaders")
unittest
{
    string body = "foo";
    auto entity = HttpEntity.of(body);
    assert(entity.getBody!string() is body);
    assert(entity.getHeaders().isEmpty());
}

@("HttpEntityTests.httpHeaders")
unittest
{
    auto headers = HttpHeaders();
    headers.setContentType(MediaType.TEXT_PLAIN);
    string body = "foo";
    auto entity = HttpEntity.of(body, headers);
    assert(entity.getBody!string() == body);
    assert(*entity.getHeaders().getContentType() == MediaType.TEXT_PLAIN);
    assert(entity.getHeaders().getFirst("Content-Type") == "text/plain");
}

@("HttpEntityTests.multiValueMap")
unittest
{
    auto headers = HttpHeaders();
    headers.set("Content-Type", "text/plain");
    string body = "foo";
    auto entity = HttpEntity.of(body, headers);
    assert(entity.getBody!string() == body);
    assert(*entity.getHeaders().getContentType() == MediaType.TEXT_PLAIN);
    assert(entity.getHeaders().getFirst("Content-Type") == "text/plain");
}

@("HttpEntityTests.equals")
unittest
{
    auto headers1 = HttpHeaders();
    headers1.set("Content-Type", "text/plain");
    auto headers2 = HttpHeaders();
    headers2.set("Content-Type", "application/json");

    assert(HttpEntity() == HttpEntity());
    assert(HttpEntity(headers1) != HttpEntity());
    assert(HttpEntity() != HttpEntity(headers2));

    assert(HttpEntity(headers1) == HttpEntity(headers1));
    assert(HttpEntity(headers1) != HttpEntity(headers2));

    // `new HttpEntity<String>(null, (HttpHeaders) null)`: no body and no headers.
    assert(HttpEntity() == HttpEntity());
    assert(HttpEntity.of("foo") != HttpEntity());
    assert(HttpEntity() != HttpEntity.of("bar"));

    assert(HttpEntity.of("foo", headers1) == HttpEntity.of("foo", headers1));
}

// The last assertion of HttpEntityTests.equals: bodies "foo" and "bar" make different entities, because Java's
// equals compares bodies with ObjectUtils.nullSafeEquals. HttpEntity.opEquals compares bodies by object identity,
// which a string body does not have, so both compare equal. It stays here behind version FlintEntityBodyEquals
// until flint.http compares bodies by value.
version (FlintEntityBodyEquals)
{
    @("HttpEntityTests.equals: different bodies make different entities")
    unittest
    {
        auto headers1 = HttpHeaders();
        headers1.set("Content-Type", "text/plain");
        assert(HttpEntity.of("foo", headers1) != HttpEntity.of("bar", headers1));
    }
}

@("HttpEntityTests.responseEntity")
unittest
{
    auto headers = HttpHeaders();
    headers.setContentType(MediaType.TEXT_PLAIN);
    string body = "foo";
    auto responseEntity = ResponseEntity.of(body, headers, HttpStatus.OK);
    const responseEntity2 = ResponseEntity.of(body, headers, HttpStatus.OK);

    assert(responseEntity.getBody!string() == body);
    assert(*responseEntity.getHeaders().getContentType() == MediaType.TEXT_PLAIN);
    assert(responseEntity.getHeaders().getFirst("Content-Type") == "text/plain");

    assert(responseEntity == responseEntity2);
    assert(responseEntity2 == responseEntity);
}

@("HttpEntityTests.requestEntity")
unittest
{
    auto headers = HttpHeaders();
    headers.setContentType(MediaType.TEXT_PLAIN);
    string body = "foo";
    auto requestEntity = RequestEntity.of(body, headers, HttpMethod.GET, URI.create("/"));
    const requestEntity2 = RequestEntity.of(body, headers, HttpMethod.GET, URI.create("/"));

    assert(requestEntity.getBody!string() == body);
    assert(*requestEntity.getHeaders().getContentType() == MediaType.TEXT_PLAIN);
    assert(requestEntity.getHeaders().getFirst("Content-Type") == "text/plain");

    assert(requestEntity == requestEntity2);
    assert(requestEntity2 == requestEntity);
}

// HttpEntityTests.responseEntity and requestEntity also assert that an HttpEntity never equals a
// ResponseEntity or RequestEntity with the same headers and body, because Java's equals compares classes.
// ResponseEntity and RequestEntity convert to their HttpEntity through `alias entity this`, so in D those
// comparisons compile and compare only the entities. The cases stay here behind version
// FlintEntityEqualityByType until flint.http decides how to keep them unequal.
version (FlintEntityEqualityByType)
{
    @("HttpEntityTests: an HttpEntity never equals a ResponseEntity or RequestEntity")
    unittest
    {
        auto headers = HttpHeaders();
        headers.setContentType(MediaType.TEXT_PLAIN);
        const httpEntity = HttpEntity.of("foo", headers);
        const responseEntity = ResponseEntity.of("foo", headers, HttpStatus.OK);
        const requestEntity = RequestEntity.of("foo", headers, HttpMethod.GET, URI.create("/"));
        assert(httpEntity != responseEntity);
        assert(responseEntity != httpEntity);
        assert(httpEntity != requestEntity);
        assert(requestEntity != httpEntity);
    }
}

@("HttpEntityTests.mutateEmptyInstanceHeaders (gh-34806)")
unittest
{
    auto headers = HttpHeaders(HttpEntity.EMPTY().getHeaders());
    headers.add("Authorization", "Bearer some-token");
    const names = HttpEntity.EMPTY().getHeaders().headerNames();
    assert(names.length == 0, "Headers of HttpEntity.EMPTY should remain empty");
}

// HttpEntityTests.headerAreMutable: Spring 7.1 lets callers change an entity's headers after construction.
// flint.http's HttpEntity hands out read-only headers, so setContentType throws UnsupportedOperationException.
// It stays here behind version FlintEntityMutableHeaders until flint.http follows 7.1.
version (FlintEntityMutableHeaders)
{
    @("HttpEntityTests.headerAreMutable")
    unittest
    {
        auto headers = HttpHeaders();
        headers.setContentType(MediaType.TEXT_PLAIN);
        auto httpEntity = HttpEntity.of("foo", headers);
        httpEntity.getHeaders().setContentType(MediaType.APPLICATION_JSON);
    }
}
