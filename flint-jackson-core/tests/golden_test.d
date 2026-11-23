/// Byte equality with Jackson 3.1.8: each case makes the same generator calls as its twin in
/// tests/golden/GoldenCore.java, whose output the real Jackson wrote to tests/golden/core/.
module golden_test;

import flint.jackson.core : JsonGenerator, ObjectWriteContext, PrettyPrinter;
import flint.jackson.core.json : JsonFactory;
import flint.jackson.core.util : ByteArrayBuilder, DefaultPrettyPrinter;

@safe:

private final class PrettyContext : ObjectWriteContext.Base
{
    override PrettyPrinter getPrettyPrinter()
    {
        return new DefaultPrettyPrinter();
    }
}

private string emit(bool pretty, scope void delegate(JsonGenerator) @safe write)
{
    auto factory = JsonFactory.builder().build();
    auto output = new ByteArrayBuilder();
    auto g = factory.createGenerator(pretty ? new PrettyContext() : ObjectWriteContext.empty(), output);
    write(g);
    g.close();
    return output.toUtf8String();
}

private void nested(JsonGenerator g)
{
    g.writeStartObject();
    g.writeNumberProperty("id", 1);
    g.writeStringProperty("name", "Leo");
    g.writeName("visits");
    g.writeStartArray();
    g.writeStartObject();
    g.writeStringProperty("date", "2013-01-01");
    g.writeNullProperty("description");
    g.writeEndObject();
    g.writeNumber(2);
    g.writeEndArray();
    g.writeName("empty");
    g.writeStartObject();
    g.writeEndObject();
    g.writeName("none");
    g.writeStartArray();
    g.writeEndArray();
    g.writeBooleanProperty("active", true);
    g.writeEndObject();
}

@("golden: greeting")
unittest
{
    assert(emit(false, (g) {
            g.writeStartObject();
            g.writeNumberProperty("id", 1L);
            g.writeStringProperty("content", "Hello, World!");
            g.writeEndObject();
        }) == import("core/greeting.json"));
}

@("golden: escapes of control characters, quotes, slashes, DEL and non-ASCII")
unittest
{
    assert(emit(false, (g) {
            char[0x20] controls;
            foreach (i, ref c; controls)
                c = cast(char) i;
            g.writeStartArray();
            g.writeString(controls.idup);
            g.writeString("quote \" backslash \\ slash / del \x7f");
            // U+2028 and U+2029 as UTF-8 bytes: D string literals turn those two characters into "\n".
            g.writeString("caf\u00e9 \u65e5\u672c \U0001F600 \xE2\x80\xA8 \xE2\x80\xA9");
            g.writeString("");
            g.writeEndArray();
        }) == import("core/escapes.json"));
}

@("golden: property names are escaped like strings")
unittest
{
    assert(emit(false, (g) {
            g.writeStartObject();
            g.writeName("tab\tname");
            g.writeNumber(1);
            g.writeName("über");
            g.writeNumber(2);
            g.writeEndObject();
        }) == import("core/names.json"));
}

@("golden: integers at their limits and encoded numbers")
unittest
{
    assert(emit(false, (g) {
            g.writeStartArray();
            g.writeNumber(0);
            g.writeNumber(-1);
            g.writeNumber(int.min);
            g.writeNumber(int.max);
            g.writeNumber(long.min);
            g.writeNumber(long.max);
            g.writeNumber(cast(short)-32_768);
            g.writeNumber("12345678901234567890");
            g.writeEndArray();
        }) == import("core/integers.json"));
}

@("golden: doubles and floats print as Double.toString, NaN and infinities quoted")
unittest
{
    import flint.serde.java_number : formatJavaDouble;

    assert(emit(false, (g) {
            union Bits
            {
                ulong raw;
                double value;
            }

            Bits tiny;
            tiny.raw = 1;
            immutable double[] values = [
                0.0, -0.0, 1.0, 0.1, 100.0, 1.5, 1_234_567.0, 1e7, 1.0E-4, 0.001,
                3.141592653589793, double.max, tiny.value, double.min_normal, 1e21, 1e-7,
                123_456_789.125, double.nan, double.infinity, -double.infinity
            ];
            g.writeStartArray();
            foreach (v; values)
                g.writeNumber(v);
            g.writeNumber(0.1f);
            g.writeNumber(3.4028235e38f);
            g.writeNumber(float.nan);
            g.writeEndArray();
        }) == import("core/doubles.json"));
}

@("golden: nested objects and arrays, compact")
unittest
{
    assert(emit(false, (g) { nested(g); }) == import("core/nested.json"));
}

@("golden: DefaultPrettyPrinter output")
unittest
{
    assert(emit(true, (g) { nested(g); }) == import("core/nested_pretty.json"));
    assert(emit(true, (g) {
            g.writeStartArray();
            g.writeNumber(1);
            g.writeString("two");
            g.writeStartArray();
            g.writeEndArray();
            g.writeStartObject();
            g.writeEndObject();
            g.writeStartArray();
            g.writeBoolean(false);
            g.writeNull();
            g.writeEndArray();
            g.writeEndArray();
        }) == import("core/pretty_array.json"));
}

@("golden: raw values and raw text")
unittest
{
    assert(emit(false, (g) {
            g.writeStartObject();
            g.writeName("raw");
            g.writeRawValue(`{"pre":"formatted"}`);
            g.writeName("next");
            g.writeNumber(1);
            g.writeEndObject();
            g.writeRaw("\n");
        }) == import("core/raw.json"));
}

@("golden: root-level values are separated by a space")
unittest
{
    assert(emit(false, (g) {
            g.writeNumber(1);
            g.writeString("two");
            g.writeStartObject();
            g.writeEndObject();
            g.writeNull();
        }) == import("core/roots.json"));
}
