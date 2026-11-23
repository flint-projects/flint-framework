/++
Ported from FasterXML/jackson-databind 3.1.8,
src/test/java/tools/jackson/databind/ext/javatime/ser/LocalDateSerTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: `DateTimeTestBase.newMapper()` is a mapper over the test's Flint AOT descriptors with
`JsonWriteFeature.ESCAPE_FORWARD_SLASHES` disabled; its `defaultLocale(Locale.ENGLISH)` has no Flint counterpart
(flint.java.time formats in English only); `Class<T>` arguments are template parameters; `java.time.LocalDate` is
`flint.java.time.LocalDate`. Cases that need parts of flint.jackson that are not ported yet wait behind versions.
+/
module local_date_ser_test;

import databind_test_util : a2q, jsonMapperBuilder;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.annotation : JsonFormat;
import flint.jackson.core.json : JsonWriteFeature;
import flint.jackson.databind : JsonMapper, ObjectMapper;
import flint.jackson.databind.cfg : DateTimeFeature;
import flint.java.time : LocalDate, Month;

@safe:

private final class EpochDayWrapper
{
    @JsonFormat(shape : JsonFormat.Shape.NUMBER_INT) LocalDate value;

    this()
    {
    }

    this(LocalDate v)
    {
        value = v;
    }
}

private final class VanillaWrapper
{
    LocalDate value;

    this()
    {
    }

    this(LocalDate v)
    {
        value = v;
    }
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    t.add(descriptorOf!EpochDayWrapper());
    t.add(descriptorOf!VanillaWrapper());
    return t;
}

// DateTimeTestBase.newMapperBuilder().
private JsonMapper.Builder newMapperBuilder()
{
    return jsonMapperBuilder(table()).disable(JsonWriteFeature.ESCAPE_FORWARD_SLASHES);
}

// DateTimeTestBase.newMapper().
private ObjectMapper newMapper()
{
    return newMapperBuilder().build();
}

// flint.jackson's ObjectWriter has no with/without(feature).
version (FlintJacksonObjectWriterConfig)
{
    @("LocalDateSerTest.testSerializationAsTimestamp01")
    unittest
    {
        const date = LocalDate.of(1986, Month.JANUARY, 17);
        const value = newMapper().writer().with_(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS).writeValueAsString(date);
        assert(value !is null);
        assert(value == "[1986,1,17]", value);
    }

    @("LocalDateSerTest.testSerializationAsTimestamp02")
    unittest
    {
        const date = LocalDate.of(2013, Month.AUGUST, 21);
        const value = newMapper().writer().with_(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS).writeValueAsString(date);
        assert(value !is null);
        assert(value == "[2013,8,21]", value);
    }

    @("LocalDateSerTest.testSerializationAsString01")
    unittest
    {
        const date = LocalDate.of(1986, Month.JANUARY, 17);
        const value = newMapper().writer().without(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS).writeValueAsString(date);
        assert(value !is null);
        assert(value == '"' ~ date.toString() ~ '"', value);
    }

    @("LocalDateSerTest.testSerializationAsString02")
    unittest
    {
        const date = LocalDate.of(2013, Month.AUGUST, 21);
        const value = newMapper().writer().without(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS).writeValueAsString(date);
        assert(value !is null);
        assert(value == '"' ~ date.toString() ~ '"', value);
    }
}

// flint.jackson has no mix-ins (addMixIn) nor @JsonTypeInfo type ids.
version (FlintJacksonMixIns)
{
    @("LocalDateSerTest.testSerializationWithTypeInfo01")
    unittest
    {
        auto mapper = newMapperBuilder().disable(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS)
            .addMixIn!(Temporal, MockObjectConfiguration)().build();
        const date = LocalDate.of(2005, Month.NOVEMBER, 5);
        const value = mapper.writeValueAsString(date);
        assert(value !is null);
        assert(value == `["` ~ typeNameOf!LocalDate ~ `","` ~ date.toString() ~ `"]`, value);
    }
}

// flint.jackson has no @JsonTypeInfo type ids (nor ObjectWriter.with).
version (FlintJacksonGenericTypes)
{
    // [modules-java8#46]
    private final class Holder46
    {
        LocalDate localDate;
        @JsonTypeInfo(use : JsonTypeInfo.Id.CLASS, include:
                JsonTypeInfo.As.WRAPPER_OBJECT) Any object;

        this(LocalDate localDate, Any object)
        {
            this.localDate = localDate;
            this.object = object;
        }
    }

    // [modules-java8#46]
    @("LocalDateSerTest.testSerializationWithTypeInfo02")
    unittest
    {
        const localDate = LocalDate.of(2017, 12, 5);
        const json = newMapper().writer().with_(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS)
            .writeValueAsString(new Holder46(localDate, Any.of(localDate)));
        assert(json == a2q(`{"localDate":[2017,12,5],"object":{"java.time.LocalDate":[2017,12,5]}}`), json);
    }
}

// flint.jackson has no per-type config overrides (withConfigOverride).
version (FlintJacksonConfigOverrides)
{
    @("LocalDateSerTest.testConfigOverrides")
    unittest
    {
        auto mapper = newMapperBuilder().withConfigOverride!LocalDate((o) {
            o.setFormat(JsonFormat.Value.forPattern("yyyy_MM_dd"));
        }).build();
        const date = LocalDate.of(2005, Month.NOVEMBER, 5);
        auto input = new VanillaWrapper(date);
        enum expDate = `"2005_11_05"`;
        const json = mapper.writeValueAsString(input);
        assert(json == `{"value":` ~ expDate ~ "}", json);
        assert(expDate == mapper.writeValueAsString(date));

        // and read back, too
        const output = mapper.readValue!VanillaWrapper(json);
        assert(input.value == output.value);
        assert(date == mapper.readValue!LocalDate(expDate));
    }

    @("LocalDateSerTest.testConfigOverridesToEpochDay")
    unittest
    {
        auto mapper = newMapperBuilder().withConfigOverride!LocalDate((o) {
            o.setFormat(JsonFormat.Value.forShape(JsonFormat.Shape.NUMBER_INT));
        }).build();
        const date = LocalDate.ofEpochDay(1000);
        auto input = new VanillaWrapper(date);
        enum expDate = "1000";
        const json = mapper.writeValueAsString(input);
        assert(json == `{"value":` ~ expDate ~ "}", json);
        assert(expDate == mapper.writeValueAsString(date));

        // and read back, too
        const output = mapper.readValue!VanillaWrapper(json);
        assert(input.value == output.value);
        assert(date == mapper.readValue!LocalDate(expDate));
    }
}

@("LocalDateSerTest.testCustomFormatToEpochDay")
unittest
{
    const w = newMapper().readValue!EpochDayWrapper(`{"value": 1000}`);
    const date = w.value;
    assert(LocalDate.ofEpochDay(1000) == date);
}
