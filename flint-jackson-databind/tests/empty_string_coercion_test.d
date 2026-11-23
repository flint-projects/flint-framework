/++
Flint tests: Jackson 3.1.8's default coercion of an empty String to a JDK scalar, as this probe printed it on Java 21
(JsonMapper.builder().build(), so FAIL_ON_NULL_FOR_PRIMITIVES is on):

    {"i":""}, {"i":"  "}, {"i":"\u000b"} and {"i":"null"} into Integer, Long, Double, Boolean... -> null
    {"c":""} into Character -> null; {"c":" "} -> " "
    {"i":" "} into Integer -> InvalidFormatException (U+00A0 is not blank)
    {"i":""} into int -> "Cannot coerce `null` to `int` value (disable `DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES` to allow)"
    {"i":"null"} into int -> "Cannot coerce String "null" to Null value as `int` value (disable ... to allow)"
    {"c":""} into char -> "Cannot map `null` into type `char` (set `DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES` to 'false' to allow)"
+/
module empty_string_coercion_test;

import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.databind : JsonMapper;
import flint.jackson.databind.exc : InvalidFormatException, MismatchedInputException;
import std.typecons : Nullable;

@safe:

private final class Wrappers
{
    Nullable!int i;
    Nullable!long l;
    Nullable!double d;
    Nullable!bool z;
    Nullable!wchar c;
    string str;
}

private final class Primitives
{
    int i = 7;
    bool z = true;
    wchar c = 'x';
}

private JsonMapper mapper()
{
    auto table = DescriptorTable.withBuiltins();
    table.add(descriptorOf!Wrappers());
    table.add(descriptorOf!Primitives());
    table.add(descriptorOf!(Nullable!int)());
    table.add(descriptorOf!(Nullable!long)());
    table.add(descriptorOf!(Nullable!double)());
    table.add(descriptorOf!(Nullable!bool)());
    table.add(descriptorOf!(Nullable!wchar)());
    return JsonMapper.builder().descriptors(table).build();
}

private string failure(string json)
{
    try
    {
        mapper().readValue!Primitives(json);
        return null;
    }
    catch (MismatchedInputException e)
    {
        return e.getOriginalMessage();
    }
}

@("an empty, blank or textual-null String reads as null for a scalar wrapper")
unittest
{
    auto m = mapper();
    foreach (text; [``, `  `, `\u000b`, `null`])
    {
        const json = `{"i":"` ~ text ~ `","l":"` ~ text ~ `","d":"` ~ text ~ `","z":"` ~ text ~ `"}`;
        const bean = m.readValue!Wrappers(json);
        assert(bean.i.isNull && bean.l.isNull && bean.d.isNull && bean.z.isNull, json);
    }
    assert(m.readValue!Wrappers(`{"c":""}`).c.isNull);
    assert(m.readValue!Wrappers(`{"c":" "}`).c.get == ' ');
    assert(m.readValue!Wrappers(`{"str":""}`).str == "");
    assert(m.readValue!(Nullable!int)(`""`).isNull);
    try
    {
        m.readValue!Wrappers(`{"i":" "}`);
        assert(false, "U+00A0 is not blank");
    }
    catch (InvalidFormatException)
    {
    }
}

@("an empty String for a primitive fails under FAIL_ON_NULL_FOR_PRIMITIVES with Jackson's messages")
unittest
{
    enum hint = " value (disable `DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES` to allow)";
    assert(failure(`{"i":""}`) == "Cannot coerce `null` to `int`" ~ hint, failure(`{"i":""}`));
    assert(failure(`{"z":"  "}`) == "Cannot coerce `null` to `boolean`" ~ hint);
    assert(failure(`{"i":"null"}`) == "Cannot coerce String \"null\" to Null value as `int`" ~ hint);
    assert(failure(`{"c":""}`) == "Cannot map `null` into type `char` (set "
            ~ "`DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES` to 'false' to allow)", failure(`{"c":""}`));
}

@("without FAIL_ON_NULL_FOR_PRIMITIVES an empty String gives the primitive's default")
unittest
{
    import flint.jackson.databind : DeserializationFeature;

    auto table = DescriptorTable.withBuiltins();
    table.add(descriptorOf!Primitives());
    auto m = JsonMapper.builder().descriptors(table)
        .disable(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES).build();
    const bean = m.readValue!Primitives(`{"i":"","z":"","c":""}`);
    assert(bean.i == 0 && !bean.z && bean.c == 0);
}
