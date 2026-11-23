/// jackson-databind: JsonMapper.writeValueAsString over a Flint AOT descriptor, as Spring Boot's default mapper.
module app;

import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.databind : JsonMapper;
import std.stdio : writeln;

@safe:

/// gs-rest-service's Greeting.
private struct Greeting
{
    long id;
    string content;
}

int main(string[] args)
{
    auto table = DescriptorTable.withBuiltins();
    table.add(descriptorOf!Greeting());
    auto mapper = JsonMapper.builder().findAndAddModules().descriptors(table).build();
    writeln(mapper.writeValueAsString(Greeting(cast(long) args.length, "Hello, World!")));
    return 0;
}
