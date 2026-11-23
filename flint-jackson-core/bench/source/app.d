/// jackson-core's streaming generator: a JSON object written through JsonFactory and JsonGenerator.
module app;

import flint.jackson.core : ObjectWriteContext;
import flint.jackson.core.json : JsonFactory;
import flint.jackson.core.util : ByteArrayBuilder;
import core.stdc.stdio : fputc, stdout;

@safe:

/// Writes one line without Phobos, so the probe adds no std.format template instances to the module's count.
private void emit(scope const(char)[] text) nothrow @nogc
{
    foreach (c; text)
        fputc(c, stdout);
    fputc('\n', stdout);
}

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
    emit(output.toUtf8String());
    return 0;
}
