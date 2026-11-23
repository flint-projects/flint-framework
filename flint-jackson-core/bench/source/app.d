/// jackson-core's streaming generator: a JSON object written through JsonFactory and JsonGenerator.
module app;

import flint.jackson.core : ObjectWriteContext;
import flint.jackson.core.json : JsonFactory;
import flint.jackson.core.util : ByteArrayBuilder;
import std.stdio : writeln;

@safe:

int main(string[] args)
{
    auto factory = JsonFactory.builder().build();
    auto output = new ByteArrayBuilder();
    auto g = factory.createGenerator(ObjectWriteContext.empty(), output);
    g.writeStartObject();
    g.writeNumberProperty("id", cast(int) args.length);
    g.writeStringProperty("name", "Leo");
    g.writeName("visits");
    g.writeStartArray();
    g.writeString("2013-01-01");
    g.writeEndArray();
    g.writeEndObject();
    g.close();
    writeln(output.toUtf8String());
    return 0;
}
