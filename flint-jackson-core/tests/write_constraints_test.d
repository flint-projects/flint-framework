/*
 * Ported from Jackson (jackson-core) 3.1.8, https://github.com/FasterXML/jackson-core,
 * tag jackson-core-3.1.8: src/test/java/tools/jackson/core/unittest/{write/UTF8GeneratorTest,
 * constraints/StreamWriteConstraintsDefaultsTest}.java (the nesting-depth cases)
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D; the process-wide default override is not
 * ported (no mutable module-level state), so its test checks the builder and rebuild instead.
 */
module flint.jackson.write_constraints_test;

import flint.jackson.core : JsonGenerator, StreamWriteConstraints;
import flint.jackson.core.exc : StreamConstraintsException;
import flint.jackson.core.json : JsonFactory;

@safe:

private JsonFactory maxNesting1()
{
    return JsonFactory.builder().streamWriteConstraints(StreamWriteConstraints.builder()
            .maxNestingDepth(1).build()).build();
}

private void expectDepthFailure(scope void delegate() @safe action, string expected)
{
    try
    {
        action();
        assert(false, "expected StreamConstraintsException");
    }
    catch (StreamConstraintsException e)
    {
        assert(e.msg.length >= expected.length && e.msg[0 .. expected.length] == expected, e.msg);
    }
}

@("UTF8GeneratorTest.nestingDepthWithSmallLimit")
unittest
{
    auto g = maxNesting1().createGenerator((scope const(ubyte)[]) {});
    g.writeStartObject();
    g.writeName("array");
    expectDepthFailure(() { g.writeStartArray(); }, "Document nesting depth (2) exceeds the maximum allowed (1, "
            ~ "from `StreamWriteConstraints.getMaxNestingDepth()`)");
}

@("UTF8GeneratorTest.nestingDepthWithSmallLimitNestedObject")
unittest
{
    auto g = maxNesting1().createGenerator((scope const(ubyte)[]) {});
    g.writeStartObject();
    g.writeName("object");
    expectDepthFailure(() { g.writeStartObject(); }, "Document nesting depth (2) exceeds the maximum allowed (1, "
            ~ "from `StreamWriteConstraints.getMaxNestingDepth()`)");
}

@("the default limit: 500 levels write, the 501st fails")
unittest
{
    ubyte[] received;
    auto g = new JsonFactory().createGenerator((scope const(ubyte)[] bytes) { received ~= bytes; });
    assert(g.streamWriteConstraints().getMaxNestingDepth() == StreamWriteConstraints.DEFAULT_MAX_DEPTH);
    foreach (_; 0 .. 500)
        g.writeStartArray();
    expectDepthFailure(() { g.writeStartObject(); }, "Document nesting depth (501) exceeds the maximum allowed (500");
    g.flush();
    assert(received.length == 500 && received[0] == '[' && received[$ - 1] == '[', "the 501st start is not written");
}

@("StreamWriteConstraintsDefaultsTest: builder, defaults and rebuild")
unittest
{
    const constraints = StreamWriteConstraints.builder().maxNestingDepth(123).build();
    assert(constraints.getMaxNestingDepth() == 123);
    assert(constraints.rebuild().build().getMaxNestingDepth() == 123);
    assert(StreamWriteConstraints.defaults().getMaxNestingDepth() == StreamWriteConstraints.DEFAULT_MAX_DEPTH);
    assert(JsonFactory.builder().streamWriteConstraints(constraints).build().rebuild().build()
            .streamWriteConstraints().getMaxNestingDepth() == 123);
    constraints.validateNestingDepth(123);
    expectDepthFailure(() { constraints.validateNestingDepth(124); }, "Document nesting depth (124)");
}

@("StreamWriteConstraints.Builder rejects a negative depth")
unittest
{
    try
    {
        StreamWriteConstraints.builder().maxNestingDepth(-1);
        assert(false, "a negative depth must fail");
    }
    catch (Exception e)
    {
        assert(e.msg == "Cannot set maxNestingDepth to a negative value", e.msg);
    }
}
