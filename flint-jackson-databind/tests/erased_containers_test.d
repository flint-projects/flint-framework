/// Flint tests: beans whose List, Set and Map properties are described by flint.java.util.descriptors' erased
/// builders (what Flint AOT registers, decision 2670d5be) write and read as with descriptorOf's.
module erased_containers_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.jackson.databind : JsonMapper;
import flint.java.util : ArrayList, LinkedHashMap, List, Map;
import flint.java.util.descriptors : rawListDescriptor, rawMapDescriptor;

@safe:

private final class Holder
{
    List!string names;
    Map!(string, int) counts;
}

private Any newNames()
{
    return Any.of(cast(List!string) new ArrayList!string());
}

private Any newCounts()
{
    return Any.of(cast(Map!(string, int)) new LinkedHashMap!(string, int)());
}

private JsonMapper mapper()
{
    auto table = DescriptorTable.withBuiltins();
    table.add(descriptorOf!Holder());
    table.add(rawListDescriptor(typeNameOf!(List!string), "string", &newNames));
    table.add(rawMapDescriptor(typeNameOf!(Map!(string, int)), "string", "int", &newCounts));
    return JsonMapper.builder().descriptors(table).build();
}

// A getter-only map is not filled: Jackson 3's USE_GETTERS_AS_SETTERS is off by default.
@("erased container descriptors: write, and read into created containers")
unittest
{
    auto m = mapper();
    auto holder = m.readValue!Holder(`{"names":["a","b"],"counts":{"x":1,"y":2}}`);
    assert(holder.names.size() == 2 && holder.names.get(1) == "b");
    assert(holder.counts.get("y") == 2);
    const json = m.writeValueAsString(holder);
    assert(json == `{"counts":{"x":1,"y":2},"names":["a","b"]}`, json);
}
