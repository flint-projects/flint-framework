/// The generator's growing buffer: documents larger than its first block and than the 8000-byte flush threshold
/// come out whole, through a sink (flushed in pieces) and collected in one buffer.
module flint.jackson.buffer_test;

import flint.jackson.core.json : JsonFactory;

@safe:

private string document(size_t length)
{
    if (length == 0)
        return ""; // not null: a null String writes as null
    auto text = new char[length];
    foreach (i, ref c; text)
        c = cast(char)('a' + i % 26);
    return text.idup;
}

@("UTF8JsonGenerator: a sink receives every byte of documents past the first block and the flush threshold")
unittest
{
    foreach (length; [0, 10, 300, 7990, 8000, 8001, 20_000, 70_000])
    {
        const text = document(length);
        ubyte[] received;
        size_t chunks;
        auto g = new JsonFactory().createGenerator((scope const(ubyte)[] bytes) {
            received ~= bytes;
            ++chunks;
        });
        g.writeStartArray();
        g.writeString(text);
        g.writeNumber(cast(long) length);
        g.writeEndArray();
        g.close();
        const expected = `["` ~ text ~ `",` ~ imported!"std.conv".to!string(length) ~ "]";
        assert(cast(const(char)[]) received == expected, imported!"std.conv".to!string(length) ~ ": got "
                ~ imported!"std.conv".to!string(received.length) ~ " bytes, expected "
                ~ imported!"std.conv".to!string(expected.length));
        assert(length < 7990 ? chunks == 1 : chunks >= 1);
    }
}

@("UTF8JsonGenerator: a buffered generator collects documents of any length in one buffer")
unittest
{
    foreach (length; [0, 255, 256, 257, 8000, 50_000])
    {
        const text = document(length);
        auto g = new JsonFactory().createBufferedGenerator(null);
        g.writeString(text);
        g.close();
        assert(cast(const(char)[]) g.collected() == `"` ~ text ~ `"`);
    }
}
