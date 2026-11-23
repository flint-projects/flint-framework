/// Flint tests: a write through `ObjectMapper.writeValue(OutputSink, Any)` allocates nothing of Jackson's own once the
/// factory's generator pool is warm (ADR-030 section 4: engine memory is reused, only the user's objects are GC), and
/// a recycled generator keeps nothing of the value it wrote.
module write_allocations_test;

import core.memory : GC;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.databind : JsonMapper;

private struct Greeting
{
    long id;
    string content;
}

private final class Response
{
    ubyte[512] buffer;
    size_t length;

    void writeBody(scope const(ubyte)[] bytes) @safe
    {
        buffer[length .. length + bytes.length] = bytes[];
        length += bytes.length;
    }
}

private JsonMapper greetingMapper()
{
    auto table = DescriptorTable.withBuiltins();
    table.add(descriptorOf!Greeting());
    return JsonMapper.builder().descriptors(table).build();
}

@("writeValue(OutputSink): no GC allocation per write once warm; writeValueAsBytes allocates only its result")
unittest
{
    auto mapper = greetingMapper();
    auto value = Any.of(Greeting(1, "Hello, World!"));
    auto response = new Response();
    foreach (i; 0 .. 10)
    {
        response.length = 0;
        mapper.writeValue(&response.writeBody, value);
    }
    const before = GC.stats().allocatedInCurrentThread;
    foreach (i; 0 .. 1000)
    {
        response.length = 0;
        mapper.writeValue(&response.writeBody, value);
    }
    assert(GC.stats().allocatedInCurrentThread == before);
    assert(cast(string) response.buffer[0 .. response.length] == `{"id":1,"content":"Hello, World!"}`);

    const bytesBefore = GC.stats().allocatedInCurrentThread;
    const json = mapper.writeValueAsBytes(value);
    assert(cast(string) json == `{"id":1,"content":"Hello, World!"}`);
    assert(GC.stats().allocatedInCurrentThread - bytesBefore <= 48);
}

@("a recycled generator writes each document from scratch")
unittest
{
    auto mapper = greetingMapper();
    auto response = new Response();
    foreach (i; 0 .. 3)
    {
        response.length = 0;
        mapper.writeValue(&response.writeBody, Any.of(Greeting(i, "n" ~ cast(char)('0' + i))));
        assert(cast(string) response.buffer[0 .. response.length] == `{"id":` ~ cast(char)(
                '0' + i) ~ `,"content":"n` ~ cast(char)('0' + i) ~ `"}`);
    }
    assert(cast(string) mapper.writeValueAsBytes(Any.of(Greeting(7, "x"))) == `{"id":7,"content":"x"}`);
}
