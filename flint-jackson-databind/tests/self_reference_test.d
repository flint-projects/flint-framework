/// Flint tests: a property whose value is the bean itself fails with Jackson's message under
/// FAIL_ON_SELF_REFERENCES (on by default) and is written as null under WRITE_SELF_REFERENCES_AS_NULL, as
/// BeanPropertyWriter._handleSelfReference does, instead of recursing until the stack overflows.
module self_reference_test;

import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.databind : JsonMapper, SerializationFeature;
import flint.jackson.databind.exc : InvalidDefinitionException;

@safe:

private final class Node
{
    string name;
    Node next;
}

private JsonMapper.Builder builder()
{
    auto table = DescriptorTable.withBuiltins();
    table.add(descriptorOf!Node());
    return JsonMapper.builder().descriptors(table);
}

@("a direct self-reference fails with InvalidDefinitionException, naming the property")
unittest
{
    auto node = new Node;
    node.name = "loop";
    node.next = node;
    try
    {
        builder().build().writeValueAsString(node);
        assert(false, "a self-reference must fail");
    }
    catch (InvalidDefinitionException e)
    {
        import std.algorithm.searching : canFind;

        assert(e.msg.canFind("Direct self-reference leading to cycle"), e.msg);
    }
}

@("WRITE_SELF_REFERENCES_AS_NULL writes a direct self-reference as null")
unittest
{
    auto node = new Node;
    node.name = "loop";
    node.next = node;
    auto mapper = builder().enable(SerializationFeature.WRITE_SELF_REFERENCES_AS_NULL).build();
    assert(mapper.writeValueAsString(node) == `{"name":"loop","next":null}`);
}
