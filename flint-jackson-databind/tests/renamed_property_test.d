/++
Flint tests: accessors renamed onto one name, as Jackson 3.1.8 printed them on Java 21:

    class Two { @JsonProperty("foo") int a = 1; @JsonProperty("foo") int b = 2; }
    -> InvalidDefinitionException: Invalid type definition for type `Two`: Multiple fields representing property
       "foo": Two#a vs Two#b
    class Mixed { int z = 3; @JsonProperty("z") int _z = 4; }
    -> writes {"z":4}; reading {"z":9} sets _z to 9 and leaves z at 3
+/
module renamed_property_test;

import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.jackson.annotation : JsonProperty;
import flint.jackson.databind : JsonMapper;
import flint.jackson.databind.exc : InvalidDefinitionException;

@safe:

private final class Two
{
    @JsonProperty("foo")
    int a = 1;
    @JsonProperty("foo")
    int b = 2;
}

private final class Mixed
{
    int z = 3;
    @JsonProperty("z")
    int _z = 4;
}

private JsonMapper mapper()
{
    auto table = DescriptorTable.withBuiltins();
    table.add(descriptorOf!Two());
    table.add(descriptorOf!Mixed());
    return JsonMapper.builder().descriptors(table).build();
}

@("an explicitly named accessor hides the implicitly named one, on output and input")
unittest
{
    auto m = mapper();
    assert(m.writeValueAsString(new Mixed()) == `{"z":4}`, m.writeValueAsString(new Mixed()));
    const read = m.readValue!Mixed(`{"z":9}`);
    assert(read._z == 9 && read.z == 3);
}

@("two fields explicitly named alike are ambiguous")
unittest
{
    import std.algorithm.searching : canFind;

    try
    {
        mapper().writeValueAsString(new Two());
        assert(false, "expected InvalidDefinitionException");
    }
    catch (InvalidDefinitionException e)
    {
        enum type = typeNameOf!Two;
        assert(e.msg.canFind(`Multiple fields representing property "foo": ` ~ type ~ "#a vs " ~ type ~ "#b"), e.msg);
    }
}
