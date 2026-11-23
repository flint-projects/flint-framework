/++
Ported from FasterXML/jackson-databind 3.1.8,
src/test/java/tools/jackson/databind/ext/javatime/deser/LocalDateDeserTest.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: `DateTimeTestBase.newMapper()` and `mapperBuilder()` are mappers over the test's
Flint AOT descriptors with `JsonWriteFeature.ESCAPE_FORWARD_SLASHES` disabled; their `defaultLocale(Locale.ENGLISH)`
has no Flint counterpart (flint.java.time formats in English only); `READER` and `READER_USING_TIME_ZONE`, readers
for `LocalDate` without further configuration, are their mappers' `readValue!LocalDate`, and a value Jackson reads
as null is checked through the erased `readValue(json, type)`; `TypeReference<Map<String, LocalDate>>` is the
template argument `Map!(string, Nullable!LocalDate)` (a `LocalDate` that may be null, rulebook R5); the
parameterized testLenientDeserializationAsString04 runs its four CSV rows in one unittest. Cases that need parts of
flint.jackson that are not ported yet, or that it handles differently, wait behind versions.
+/
module local_date_deser_test;

import databind_test_util : a2q, assertThrows, jsonMapperBuilder, q, verifyException;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.jackson.annotation : JsonFormat, OptBoolean;
import flint.jackson.core.json : JsonWriteFeature;
import flint.jackson.databind : JsonMapper, ObjectMapper;
import flint.jackson.databind.cfg : DateTimeFeature;
import flint.jackson.databind.exc : InvalidFormatException, MismatchedInputException;
import flint.java.time : Instant, LocalDate, LocalDateTime, Month, ZoneOffset;
import flint.java.util : LinkedHashMap, Map;
import std.typecons : Nullable;

@safe:

private final class Wrapper
{
    @JsonFormat(pattern : "yyyy_MM_dd'T'HH:mmZ", shape:
            JsonFormat.Shape.STRING) LocalDate value;

    this()
    {
    }

    this(LocalDate v)
    {
        value = v;
    }
}

private final class ShapeWrapper
{
    @JsonFormat(shape : JsonFormat.Shape.NUMBER_INT) LocalDate date;

    this()
    {
    }

    this(LocalDate v)
    {
        date = v;
    }
}

private final class StrictWrapperWithFormat
{
    @JsonFormat(pattern : "yyyy-MM-dd", lenient:
            OptBoolean.FALSE) LocalDate value;

    this()
    {
    }

    this(LocalDate v)
    {
        value = v;
    }
}

private final class StrictWrapperWithYearOfEra
{
    @JsonFormat(pattern : "yyyy-MM-dd G", lenient:
            OptBoolean.FALSE) LocalDate value;

    this()
    {
    }

    this(LocalDate v)
    {
        value = v;
    }
}

private final class StrictWrapperWithYearWithoutEra
{
    @JsonFormat(pattern : "uuuu-MM-dd", lenient:
            OptBoolean.FALSE) LocalDate value;

    this()
    {
    }

    this(LocalDate v)
    {
        value = v;
    }
}

private alias DateMap = Map!(string, Nullable!LocalDate);

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!Wrapper(), descriptorOf!ShapeWrapper(), descriptorOf!StrictWrapperWithFormat(),
        descriptorOf!StrictWrapperWithYearOfEra(), descriptorOf!StrictWrapperWithYearWithoutEra(),
        descriptorOf!(Nullable!LocalDate)(), descriptorOf!DateMap(),
        descriptorOf!(LinkedHashMap!(string, Nullable!LocalDate))(),
        descriptorOf!(Map!(string, string))(), descriptorOf!(LinkedHashMap!(string, string))()
    ])
        t.add(d);
    return t;
}

// DateTimeTestBase.newMapperBuilder() and mapperBuilder().
private JsonMapper.Builder newMapperBuilder()
{
    return jsonMapperBuilder(table()).disable(JsonWriteFeature.ESCAPE_FORWARD_SLASHES);
}

private ObjectMapper newMapper()
{
    return newMapperBuilder().build();
}

private alias mapperBuilder = newMapperBuilder;

// `READER = MAPPER.readerFor(LocalDate.class)`.
private LocalDate read(string json)
{
    return newMapper().readValue!LocalDate(json);
}

// `READER_USING_TIME_ZONE`.
private LocalDate readUsingTimeZone(string json)
{
    return newMapperBuilder().enable(DateTimeFeature.USE_TIME_ZONE_FOR_LENIENT_DATE_PARSING)
        .build().readValue!LocalDate(json);
}

// DateTimeTestBase.asMap: a single-entry map.
private Map!(string, string) asMap(string key, string value)
{
    auto result = new LinkedHashMap!(string, string)();
    result.put(key, value);
    return result;
}

/*
 * Deserialization from Int array representation
 */

@("LocalDateDeserTest.testDeserializationAsTimestamp01")
unittest
{
    assert(LocalDate.of(1986, Month.JANUARY, 17) == read("[1986,1,17]"));
}

@("LocalDateDeserTest.testDeserializationAsTimestamp02")
unittest
{
    assert(LocalDate.of(2013, Month.AUGUST, 21) == read("[2013,8,21]"));
}

/*
 * Deserialization from String representation
 */

@("LocalDateDeserTest.testDeserializationAsString01")
unittest
{
    assert(LocalDate.of(2000, Month.JANUARY, 1) == read(q("2000-01-01")));

    auto date = LocalDate.of(1986, Month.JANUARY, 17);
    assert(date == read('"' ~ date.toString() ~ '"'));

    date = LocalDate.of(2013, Month.AUGUST, 21);
    assert(date == read('"' ~ date.toString() ~ '"'));
}

@("LocalDateDeserTest.testDeserializationAsString02")
unittest
{
    const date = LocalDateTime.now();
    assert(date.toLocalDate() == read('"' ~ date.toString() ~ '"'), date.toString());
}

@("LocalDateDeserTest.testLenientDeserializationAsString01")
unittest
{
    const instant = Instant.now();
    const value = read(q(instant.toString()));
    assert(LocalDateTime.ofInstant(instant, ZoneOffset.UTC.toZoneId()).toLocalDate() == value);
}

// flint.jackson has no ObjectReader (with(TimeZone)).
version (FlintJacksonObjectReader)
{
    @("LocalDateDeserTest.testLenientDeserializationAsString02")
    unittest
    {
        auto reader = newMapper().readerFor!LocalDate().with_(TimeZone.getTimeZone(ZoneId.of("Europe/Budapest")));
        const instant = Instant.now();
        const value = reader.readValue!LocalDate(q(instant.toString()));
        assert(LocalDateTime.ofInstant(instant, ZoneOffset.UTC.toZoneId()).toLocalDate() == value);
    }
}

@("LocalDateDeserTest.testLenientDeserializationAsString03")
unittest
{
    const instant = Instant.now();
    const value = readUsingTimeZone(q(instant.toString()));
    assert(LocalDateTime.ofInstant(instant, ZoneOffset.UTC.toZoneId()).toLocalDate() == value);
}

// flint.jackson has no ObjectReader (with(TimeZone)).
version (FlintJacksonObjectReader)
{
    @("LocalDateDeserTest.testLenientDeserializationAsString04")
    unittest
    {
        static immutable string[3][] rows = [
            ["Europe/Budapest", "2024-07-21T21:59:59Z", "2024-07-21"],
            ["Europe/Budapest", "2024-07-21T22:00:00Z", "2024-07-22"],
            ["America/Chicago", "2024-07-22T04:59:59Z", "2024-07-21"],
            ["America/Chicago", "2024-07-22T05:00:00Z", "2024-07-22"],
        ];
        foreach (row; rows)
        {
            auto reader = newMapperBuilder().enable(DateTimeFeature.USE_TIME_ZONE_FOR_LENIENT_DATE_PARSING)
                .build().readerFor!LocalDate().with_(TimeZone.getTimeZone(row[0]));
            const value = reader.readValue!LocalDate(q(row[1]));
            assert(LocalDate.parse(row[2]) == value, row[1]);
        }
    }
}

@("LocalDateDeserTest.testBadDeserializationAsString01")
unittest
{
    auto e = assertThrows!MismatchedInputException(() { read(q("notalocaldate")); });
    verifyException(e, "Cannot deserialize value of type");
    verifyException(e, "from String \"");
}

@("LocalDateDeserTest.testBadDeserializationAsString02")
unittest
{
    auto e = assertThrows!MismatchedInputException(() { read(q("2015-06-19TShouldNotParse")); });
    verifyException(e, "Cannot deserialize value of type");
    verifyException(e, "from String \"");
}

// flint.jackson has no mix-ins (addMixIn) nor @JsonTypeInfo type ids.
version (FlintJacksonMixIns)
{
    @("LocalDateDeserTest.testDeserializationWithTypeInfo01")
    unittest
    {
        auto mapper = mapperBuilder().addMixIn!(Temporal, MockObjectConfiguration)().build();
        const date = LocalDate.of(2005, Month.NOVEMBER, 5);
        const value = mapper.readValue!Temporal(`["` ~ typeNameOf!LocalDate ~ `","` ~ date.toString() ~ `"]`);
        assert(date == value);
    }
}

/*
 * Deserialization from alternate representation: int (number of days since Epoch)
 */

// By default, lenient handling on so we can do this:
@("LocalDateDeserTest.testLenientDeserializeFromInt")
unittest
{
    assert(LocalDate.of(1970, Month.JANUARY, 3) == read("2"));

    assert(LocalDate.of(1970, Month.FEBRUARY, 10) == read("40"));
}

// LIKELY BUG: flint.jackson has no tools.jackson.databind.ext.javatime.DateTimeParseException, and an out-of-range
// epoch day escapes unwrapped as flint.java.time's DateTimeException "Invalid value for Year (valid values
// -999999999 - 999999999): -2525271523"; Jackson throws "Failed to deserialize java.time.LocalDate ... Invalid value
// for EpochDay ... -922337203685".
version (FlintJacksonJavaTimeParseException)
{
    @("LocalDateDeserTest.testInvalidEpochDayValueInLenientMode")
    unittest
    {
        import flint.jackson.databind.ext.javatime : DateTimeParseException;

        auto e = assertThrows!DateTimeParseException(() { read("-922337203685"); });
        verifyException(e, "Failed to deserialize");
        verifyException(e, "java.time.LocalDate");
        verifyException(e, "-922337203685");
        verifyException(e, "Invalid value for EpochDay");
    }
}

// flint.jackson has no per-type config overrides (withConfigOverride).
version (FlintJacksonConfigOverrides)
{
    // But with alternate setting, not so
    @("LocalDateDeserTest.testStricDeserializeFromInt")
    unittest
    {
        auto mapper = mapperBuilder().withConfigOverride!LocalDate((c) {
            c.setFormat(JsonFormat.Value.forLeniency(false));
        }).build();
        auto e = assertThrows!MismatchedInputException(() { mapper.readValue!LocalDate("2"); });
        verifyException(e, "Cannot deserialize instance of");
        verifyException(e, "not allowed because 'strict' mode set for property or type");
    }
}

/*
 * Tests for empty string handling
 */

@("LocalDateDeserTest.testLenientDeserializeFromEmptyString")
unittest
{
    const key = "date";
    auto mapper = newMapper();

    const string dateValAsNullStr = null;
    const dateValAsEmptyStr = "";

    const valueFromNullStr = mapper.writeValueAsString(asMap(key, dateValAsNullStr));
    auto actualMapFromNullStr = mapper.readValue!DateMap(valueFromNullStr);
    const actualDateFromNullStr = actualMapFromNullStr.get(key);
    assert(actualDateFromNullStr.isNull, valueFromNullStr);

    const valueFromEmptyStr = mapper.writeValueAsString(asMap(key, dateValAsEmptyStr));
    auto actualMapFromEmptyStr = mapper.readValue!DateMap(valueFromEmptyStr);
    const actualDateFromEmptyStr = actualMapFromEmptyStr.get(key);
    assert(actualDateFromEmptyStr.isNull, "empty string failed to deserialize to null with lenient setting");
}

// flint.jackson has no per-type config overrides (withConfigOverride).
version (FlintJacksonConfigOverrides)
{
    @("LocalDateDeserTest.testStrictDeserializeFromEmptyString")
    unittest
    {
        const key = "date";
        auto mapper = mapperBuilder().withConfigOverride!LocalDate((c) {
            c.setFormat(JsonFormat.Value.forLeniency(false));
        }).build();
        const string dateValAsNullStr = null;

        // even with strict, null value should be deserialized without throwing an exception
        const valueFromNullStr = mapper.writeValueAsString(asMap(key, dateValAsNullStr));
        assert(mapper.readValue!DateMap(valueFromNullStr).get(key).isNull);

        const dateValAsEmptyStr = "";
        const valueFromEmptyStr = mapper.writeValueAsString(asMap("date", dateValAsEmptyStr));
        // with strict, deserializing an empty string is not permitted
        assertThrows!MismatchedInputException(() { mapper.readValue!DateMap(valueFromEmptyStr); });
    }
}

/*
 * Tests for alternate array handling
 */

// LIKELY BUG: `["2000-01-01"]` read as a LocalDate fails with "Unexpected token (non-integer), expected END_ARRAY:
// Expected array to end"; Jackson's message is "Unexpected token (VALUE_STRING) within Array, expected
// VALUE_NUMBER_INT".
version (FlintJacksonJavaTimeArrayTokenMessage)
{
    @("LocalDateDeserTest.testDeserializationAsArrayDisabled")
    unittest
    {
        auto e = assertThrows!MismatchedInputException(() { read(`["2000-01-01"]`); });
        verifyException(e, "Unexpected token (VALUE_STRING) within Array");
    }
}

// LIKELY BUG: `[]` read as a LocalDate throws MismatchedInputException "Unexpected number of elements in the array
// for `java.time.LocalDate`"; Jackson reads null.
version (FlintJacksonJavaTimeEmptyArray)
{
    @("LocalDateDeserTest.testDeserializationAsEmptyArrayDisabled")
    unittest
    {
        // works even without the feature enabled
        assert(newMapper().readValue("[]", typeNameOf!LocalDate).isNull());
    }
}

// flint.jackson has no ObjectReader (with(DeserializationFeature)).
version (FlintJacksonObjectReader)
{
    @("LocalDateDeserTest.testDeserializationAsArrayEnabled")
    unittest
    {
        const actual = newMapper().readerFor!LocalDate()
            .with_(DeserializationFeature.UNWRAP_SINGLE_VALUE_ARRAYS).readValue!LocalDate(`["2000-01-01"]`);
        assert(LocalDate.of(2000, 1, 1) == actual);
    }

    @("LocalDateDeserTest.testDeserializationAsEmptyArrayEnabled")
    unittest
    {
        const value = newMapper().readerFor!LocalDate().with_(DeserializationFeature.UNWRAP_SINGLE_VALUE_ARRAYS,
                DeserializationFeature.ACCEPT_EMPTY_ARRAY_AS_NULL_OBJECT).readValue("[]");
        assert(value.isNull());
    }
}

/*
 * Custom format
 */

// for [datatype-jsr310#37]
@("LocalDateDeserTest.testCustomFormat")
unittest
{
    const w = newMapper().readValue!Wrapper(`{"value":"2015_07_28T13:53+0300"}`);
    const date = w.value;
    assert(28 == date.getDayOfMonth());
}

/*
 * Strict Custom format
 */

// for [modules-java8#148]
@("LocalDateDeserTest.testStrictWithCustomFormat")
unittest
{
    auto e = assertThrows!InvalidFormatException(() {
        newMapper().readValue!StrictWrapperWithFormat(`{"value":"2019-11-31"}`);
    });
    verifyException(e, "Cannot deserialize value of type `java.time.LocalDate` from String");
    verifyException(e, `"2019-11-31"`);
}

// LIKELY BUG: @JsonFormat(lenient = FALSE) is not read: `"2019-11-30"` under the strict pattern "yyyy-MM-dd" reads as
// 2019-11-30; Jackson's STRICT resolver rejects a year-of-era without an era (InvalidFormatException).
version (FlintJacksonJsonFormatLenient)
{
    @("LocalDateDeserTest.testStrictCustomFormatForInvalidFormat")
    unittest
    {
        auto e = assertThrows!InvalidFormatException(() {
            newMapper().readValue!StrictWrapperWithFormat(`{"value":"2019-11-30"}`);
        });
        // 25-Mar-2021, tatu: Really bad exception message we got... but it is what it is
        verifyException(e, "Cannot deserialize value of type `java.time.LocalDate` from String");
        verifyException(e, `"2019-11-30"`);
    }
}

// flint.java.time's DateTimeFormatter has no era pattern letter (G): the pattern itself fails to compile.
version (FlintJacksonEraPattern)
{
    @("LocalDateDeserTest.testStrictCustomFormatForInvalidFormatWithEra")
    unittest
    {
        assertThrows!InvalidFormatException(() {
            newMapper().readValue!StrictWrapperWithYearOfEra(`{"value":"2019-11-30"}`);
        });
    }

    @("LocalDateDeserTest.testStrictCustomFormatForInvalidDateWithEra")
    unittest
    {
        assertThrows!InvalidFormatException(() {
            newMapper().readValue!StrictWrapperWithYearOfEra(`{"value":"2019-11-31 AD"}`);
        });
    }

    @("LocalDateDeserTest.testStrictCustomFormatForValidDateWithEra")
    unittest
    {
        const w = newMapper().readValue!StrictWrapperWithYearOfEra(`{"value":"2019-11-30 AD"}`);
        assert(w.value == LocalDate.of(2019, 11, 30));
    }
}

@("LocalDateDeserTest.testStrictCustomFormatForInvalidFormatWithoutEra")
unittest
{
    assertThrows!InvalidFormatException(() {
        newMapper().readValue!StrictWrapperWithYearWithoutEra(`{"value":"2019-11-30 AD"}`);
    });
}

@("LocalDateDeserTest.testStrictCustomFormatForInvalidDateWithoutEra")
unittest
{
    assertThrows!InvalidFormatException(() {
        newMapper().readValue!StrictWrapperWithYearWithoutEra(`{"value":"2019-11-31"}`);
    });
}

@("LocalDateDeserTest.testStrictCustomFormatForValidDateWithoutEra")
unittest
{
    const w = newMapper().readValue!StrictWrapperWithYearWithoutEra(`{"value":"2019-11-30"}`);
    assert(w.value == LocalDate.of(2019, 11, 30));
}

// flint.jackson has no per-type config overrides (withConfigOverride), nor ObjectReader.
version (FlintJacksonConfigOverrides)
{
    /*
     * Case-insensitive tests
     */

    @("LocalDateDeserTest.testDeserializationCaseInsensitiveEnabledOnValue")
    unittest
    {
        auto mapper = newMapperBuilder().withConfigOverride!LocalDate((o) {
            o.setFormat(JsonFormat.Value.forPattern("dd-MMM-yyyy")
                .withFeature(JsonFormat.Feature.ACCEPT_CASE_INSENSITIVE_VALUES));
        }).build();
        auto reader = mapper.readerFor!LocalDate();
        foreach (json; [q("01-Jan-2000"), q("01-JAN-2000"), q("01-jan-2000")])
            expectSuccess(reader, LocalDate.of(2000, Month.JANUARY, 1), json);
    }

    @("LocalDateDeserTest.testDeserializationCaseInsensitiveEnabled")
    unittest
    {
        auto mapper = mapperBuilder().enable(MapperFeature.ACCEPT_CASE_INSENSITIVE_VALUES)
            .withConfigOverride!LocalDate((o) {
                o.setFormat(JsonFormat.Value.forPattern("dd-MMM-yyyy"));
            }).build();
        auto reader = mapper.readerFor!LocalDate();
        foreach (json; [q("01-Jan-2000"), q("01-JAN-2000"), q("01-jan-2000")])
            expectSuccess(reader, LocalDate.of(2000, Month.JANUARY, 1), json);
    }

    @("LocalDateDeserTest.testDeserializationCaseInsensitiveDisabled")
    unittest
    {
        auto mapper = mapperBuilder().configure(MapperFeature.ACCEPT_CASE_INSENSITIVE_VALUES,
                false).withConfigOverride!LocalDate((o) {
            o.setFormat(JsonFormat.Value.forPattern("dd-MMM-yyyy"));
        }).build();
        auto reader = mapper.readerFor!LocalDate();
        expectSuccess(reader, LocalDate.of(2000, Month.JANUARY, 1), q("01-Jan-2000"));
    }

    @("LocalDateDeserTest.testDeserializationCaseInsensitiveDisabled_InvalidDate")
    unittest
    {
        auto mapper = mapperBuilder().configure(MapperFeature.ACCEPT_CASE_INSENSITIVE_VALUES,
                false).withConfigOverride!LocalDate((o) {
            JsonFormat.Value.forPattern("dd-MMM-yyyy");
        }).build();
        auto reader = mapper.readerFor!LocalDate();
        foreach (json; [q("01-JAN-2000"), q("01-jan-2000")])
        {
            auto e = assertThrows!MismatchedInputException(() {
                reader.readValue!LocalDate(a2q(json));
            });
            verifyException(e, "Cannot deserialize value of type `java.time.LocalDate` from String ");
        }
    }

    /*
     * Tests for issue 58 - NUMBER_INT should be specified when deserializing LocalDate as EpochDays
     */

    @("LocalDateDeserTest.testLenientDeserializeFromNumberInt")
    unittest
    {
        auto mapper = newMapperBuilder().withConfigOverride!LocalDate((o) {
            o.setFormat(JsonFormat.Value.forShape(JsonFormat.Shape.NUMBER_INT));
        }).build();

        assert(LocalDate.of(1970, Month.MAY, 4) == mapper.readValue!LocalDate("123"));
    }

    @("LocalDateDeserTest.testStrictDeserializeFromNumberInt")
    unittest
    {
        auto mapper = newMapperBuilder().withConfigOverride!LocalDate((o) {
            o.setFormat(JsonFormat.Value.forLeniency(false));
        }).build();

        const w = mapper.readValue!ShapeWrapper(`{"date":123}`);
        assert(LocalDate.of(1970, Month.MAY, 4) == w.date);
    }

    @("LocalDateDeserTest.testStrictDeserializeFromString")
    unittest
    {
        auto mapper = newMapperBuilder().withConfigOverride!LocalDate((o) {
            o.setFormat(JsonFormat.Value.forLeniency(false));
        }).build();
        auto e = assertThrows!MismatchedInputException(() {
            mapper.readValue!Wrapper(`{"value":123}`);
        });
        verifyException(e, "Cannot deserialize instance of `java.time.LocalDate`");
    }

    @("LocalDateDeserTest.testInvalidEpochDayValue")
    unittest
    {
        import flint.jackson.databind.ext.javatime : DateTimeParseException;

        // Test with an invalid epoch day value that causes DateTimeException
        auto mapper = newMapperBuilder().withConfigOverride!LocalDate((o) {
            o.setFormat(JsonFormat.Value.forShape(JsonFormat.Shape.NUMBER_INT));
        }).build();
        auto e = assertThrows!DateTimeParseException(() {
            mapper.readValue!LocalDate("-922337203685");
        });
        verifyException(e, "Failed to deserialize");
        verifyException(e, "java.time.LocalDate");
        verifyException(e, "-922337203685");
        verifyException(e, "Invalid value for EpochDay");
    }

    private void expectSuccess(ObjectReader reader, LocalDate exp, string json)
    {
        const value = reader.readValue!LocalDate(a2q(json));
        assert(exp == value);
    }
}

// flint.jackson has no coercion configuration (withCoercionConfig, CoercionAction).
version (FlintJacksonCoercionConfig)
{
    /*
     * coercion config test
     */

    @("LocalDateDeserTest.testDeserializeFromIntegerWithCoercionActionFail")
    unittest
    {
        auto mapper = newMapperBuilder().withCoercionConfig!LocalDate((cfg) {
            cfg.setCoercion(CoercionInputShape.Integer, CoercionAction.Fail);
        }).build();
        auto exception = assertThrows!MismatchedInputException(() {
            mapper.readValue!LocalDate("123");
        });
        verifyException(exception, "Cannot coerce Integer value (123) to `java.time.LocalDate`");
    }

    @("LocalDateDeserTest.testDeserializeFromEmptyStringWithCoercionActionFail")
    unittest
    {
        auto mapper = newMapperBuilder().withCoercionConfig!LocalDate((cfg) {
            cfg.setCoercion(CoercionInputShape.EmptyString, CoercionAction.Fail);
        }).build();
        auto exception = assertThrows!MismatchedInputException(() {
            mapper.readValue!Wrapper(a2q("{'value':''}"));
        });
        verifyException(exception, "Cannot coerce empty String (\"\") to `java.time.LocalDate`");
    }
}
