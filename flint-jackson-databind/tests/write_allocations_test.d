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

private final class OwnerFields
{
    string firstName;
    string city;
}

@("a read allocates only the user's objects: the bean and its strings, nothing of Jackson's own")
unittest
{
    auto table = DescriptorTable.withBuiltins();
    table.add(descriptorOf!OwnerFields());
    auto mapper = JsonMapper.builder().descriptors(table).build();
    const(ubyte)[] json = cast(const(ubyte)[]) `{"firstName":"Ada","city":"London"}`;
    const name = descriptorOf!OwnerFields().name;
    foreach (i; 0 .. 10)
        mapper.readValue(json, name);

    // What the user's objects cost: the bean and copies of its two values.
    auto before = GC.stats().allocatedInCurrentThread;
    auto bean = new OwnerFields();
    bean.firstName = "Ada".idup;
    bean.city = "London".idup;
    const own = GC.stats().allocatedInCurrentThread - before;

    before = GC.stats().allocatedInCurrentThread;
    const read = mapper.readValue(json, name).get!OwnerFields();
    assert(GC.stats().allocatedInCurrentThread - before == own);
    assert(read.firstName == "Ada" && read.city == "London");
}

@("a generator user code keeps after close() fails loudly, and never touches another write")
unittest
{
    import flint.jackson.core.exc : StreamWriteException;

    auto mapper = greetingMapper();
    auto mine = new Response();
    // createGenerator is public, so it never hands out a recycled generator.
    auto g = mapper.tokenStreamFactory().createGenerator(&mine.writeBody);
    g.writeStartObject();
    g.writeEndObject();
    g.close();

    auto other = new Response();
    mapper.writeValue(&other.writeBody, Any.of(Greeting(2, "pooled")));
    try
    {
        g.writeString("late");
        assert(false, "a closed generator must refuse to write");
    }
    catch (StreamWriteException e)
        assert(e.msg == "Generator closed: cannot write after close()", e.msg);
    assert(cast(string) mine.buffer[0 .. mine.length] == "{}");
    assert(cast(string) other.buffer[0 .. other.length] == `{"id":2,"content":"pooled"}`);
    assert(mapper.tokenStreamFactory().createGenerator(&mine.writeBody) !is g);
}
