/// jackson-databind: JsonMapper.writeValueAsString over a Flint AOT descriptor, as Spring Boot's default mapper.
module app;

import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.databind : JsonMapper;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

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
    emit(mapper.writeValueAsString(Greeting(cast(long) args.length, "Hello, World!")));
    return 0;
}
