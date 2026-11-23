/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/http/ProblemDetailTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; Java's
`equals`/`hashCode` are D's `opEquals`/`toHash` (rulebook R11).
+/
module flint.http.problem_detail_tests;

import flint.http : HttpStatus, ProblemDetail;

@safe:

@("ProblemDetailTests.equalsAndHashCode")
unittest
{
    ProblemDetail pd1 = ProblemDetail.forStatus(500);
    ProblemDetail pd2 = ProblemDetail.forStatus(HttpStatus.INTERNAL_SERVER_ERROR);
    ProblemDetail pd3 = ProblemDetail.forStatus(HttpStatus.NOT_FOUND);
    ProblemDetail pd4 = ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, "some detail");

    assert(pd1 == pd2);
    assert(pd2 == pd1);
    assert(pd1.toHash() == pd2.toHash());

    assert(pd3 != pd4);
    assert(pd4 != pd3);
    assert(pd3.toHash() != pd4.toHash());

    assert(pd1 != pd3);
    assert(pd1 != pd4);
    assert(pd2 != pd3);
    assert(pd2 != pd4);
    assert(pd1.toHash() != pd3.toHash());
    assert(pd1.toHash() != pd4.toHash());
}

// ProblemDetailTests.equalsAndHashCodeWithDeserialization (gh-30294) round-trips a ProblemDetail through
// Jackson's ObjectMapper. flint.http.converter.json writes ProblemDetail but does not read it yet, so the case
// compiles once reading lands (version FlintProblemDetailRead).
version (FlintProblemDetailRead)
{
    @("ProblemDetailTests.equalsAndHashCodeWithDeserialization (gh-30294)")
    unittest
    {
        import flint.jackson.databind : JsonMapper;

        ProblemDetail originalDetail = ProblemDetail.forStatus(500);
        auto mapper = JsonMapper.builder().findAndAddModules().build();
        auto bytes = mapper.writeValueAsBytes(originalDetail);
        ProblemDetail deserializedDetail = mapper.readValue!ProblemDetail(bytes);
        assert(originalDetail == deserializedDetail);
        assert(deserializedDetail == originalDetail);
        assert(originalDetail.toHash() == deserializedDetail.toHash());
    }
}
