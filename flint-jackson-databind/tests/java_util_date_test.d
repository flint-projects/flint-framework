/// Flint tests: `java.util.Date` against Jackson 3.1.8. tests/golden/GoldenDates.java ran each case through the real
/// Jackson (the case's format as the Date config override, which Jackson merges like a property's @JsonFormat) and
/// wrote tests/golden/dates.tsv; here the same format is the property format the serializers receive.
module java_util_date_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.annotation : JsonFormat, OptBoolean;
import flint.jackson.core : JacksonException, ObjectWriteContext;
import flint.jackson.core.util : ByteArrayBuilder;
import flint.jackson.databind : JsonMapper;
import flint.jackson.databind.cfg : DateTimeFeature, DeserializationFeature, MapperConfig;
import flint.jackson.databind.deser : deserializeValue;
import flint.jackson.databind.exc : InvalidDefinitionException;
import flint.jackson.databind.ext.javatime : JavaTimeFormat;
import flint.jackson.databind.module_ : JavaUtilDateModule, SimpleModule;
import flint.jackson.databind.ser : serializeValue;
import flint.java.lang : IllegalArgumentException;
import flint.java.util : ArrayList, Date, HashMap, List;

@safe:

private enum DATE = "flint.java.util.date.Date";

// Cases whose Jackson result needs what Flint deliberately lacks (D-JACKSON-9): Flint must refuse them with an
// InvalidDefinitionException rather than give a different answer.
private static immutable string[] gaps = [
    "pattern=EEE;locale=fr", // French day names
];

private struct Case
{
    MapperConfig config;
    JavaTimeFormat format;
}

private Case caseOf(string spec)
{
    import std.array : split;
    import std.conv : ConvException, to;
    import std.string : indexOf;

    auto b = JsonMapper.builder();
    JavaTimeFormat format;
    foreach (part; spec == "-" ? null : spec.split(';'))
    {
        if (part[0] == '+' || part[0] == '-')
        {
            try
                b.configure(part[1 .. $].to!DateTimeFeature, part[0] == '+');
            catch (ConvException)
                b.configure(part[1 .. $].to!DeserializationFeature, part[0] == '+');
            continue;
        }
        const eq = part.indexOf('=');
        const value = part[eq + 1 .. $];
        format.present = true;
        switch (part[0 .. eq])
        {
        case "shape":
            format.shape = value.to!(JsonFormat.Shape);
            break;
        case "pattern":
            format.pattern = value;
            break;
        case "tz":
            format.timezone = value;
            break;
        case "locale":
            format.locale = value;
            break;
        default:
            format.lenient = value == "true" ? OptBoolean.TRUE : OptBoolean.FALSE;
        }
    }
    // The golden cases call the erased serializer and deserializer directly, so they register the module themselves.
    return Case(b.addModule(new JavaUtilDateModule()).build().serializationConfig(), format);
}

private Any dateAt(long millis)
{
    return Any.ofObject(new Date(millis), DATE);
}

private string written(Case c, long millis)
{
    auto target = new ByteArrayBuilder();
    auto g = c.config.factory.createGenerator(ObjectWriteContext.empty(), target);
    auto value = dateAt(millis);
    try
        serializeValue(c.config, value, DATE, g, c.format);
    catch (InvalidDefinitionException e)
        return "!refused: " ~ e.getOriginalMessage();
    catch (JacksonException e)
        return "!" ~ e.getOriginalMessage();
    catch (IllegalArgumentException e)
        return "!IllegalArgumentException: " ~ e.msg;
    g.close();
    return (cast(const(char)[]) target.toByteArray()).idup;
}

private string read(Case c, string json)
{
    import flint.engine.aot.text : decimal;

    auto p = c.config.factory.createParser(json);
    p.nextToken();
    try
    {
        auto value = deserializeValue(c.config, p, DATE, Any.init, c.format);
        return value.isNull() ? "null" : decimal((cast(Date) value.asObject()).getTime());
    }
    catch (JacksonException e)
        return "!" ~ e.getOriginalMessage();
    catch (IllegalArgumentException e)
        return "!IllegalArgumentException: " ~ e.msg;
}

@("java.util.Date: writes, @JsonFormat and reads match Jackson 3.1.8 (dates.tsv)")
unittest
{
    import std.array : split;
    import std.conv : to;
    import std.string : lineSplitter;

    size_t checked, refused;
    string failures;
    foreach (line; import("dates.tsv").lineSplitter)
    {
        const row = line.split("\t");
        if (row[0] == "writekey" || row[0] == "readkey")
            continue;
        auto c = caseOf(row[1]);
        bool gap;
        foreach (g; gaps)
            gap = gap || g == row[1];
        if (gap)
        {
            const outcome = written(c, row[2].to!long);
            if (outcome.length > 9 && outcome[0 .. 9] == "!refused:")
                ++refused;
            else
                failures ~= "  " ~ row[1] ~ ": expected Flint to refuse it, got " ~ outcome ~ "\n";
            continue;
        }
        const got = row[0] == "write" ? written(c, row[2].to!long) : read(c, row[2]);
        ++checked;
        if (got != row[3])
            failures ~= "  " ~ row[0] ~ " " ~ row[1] ~ " " ~ row[2] ~ "\n    jackson: " ~ row[3]
                ~ "\n    flint:   " ~ got ~ "\n";
    }
    assert(failures.length == 0, "java.util.Date cases that differ from Jackson 3.1.8:\n" ~ failures);
    assert(checked > 1100 && refused == gaps.length, checked.to!string ~ " checked");
}

private final class Stamped
{
    Date timestamp;
    @JsonFormat(pattern: "yyyy-MM-dd")
    Date day;
    @JsonFormat(shape: JsonFormat.Shape.NUMBER)
    Date epoch;
    @JsonFormat(timezone: "GMT+2")
    Date local;
}

private final class Journal
{
    string title;
    ArrayList!Date entries;
}

// No JavaUtilDateModule here: the templated methods register it because their types hold a Date.
private JsonMapper mapper()
{
    auto t = DescriptorTable.withBuiltins();
    t.add(descriptorOf!Stamped());
    t.add(descriptorOf!(HashMap!(Date, int))());
    t.add(descriptorOf!Journal());
    t.add(descriptorOf!(ArrayList!Date)());
    return JsonMapper.builder().descriptors(t).build();
}

@("java.util.Date: bean properties carry their @JsonFormat, and Boot's error timestamp keeps three fraction digits")
unittest
{
    auto bean = new Stamped();
    bean.timestamp = new Date(1_795_100_510_000L);
    bean.day = new Date(1_795_100_510_000L);
    bean.epoch = new Date(1_234_567_890_123L);
    bean.local = new Date(0);
    const json = mapper().writeValueAsString(bean);
    assert(json == `{"day":"2026-11-19","epoch":1234567890123,"local":"1970-01-01T02:00:00.000+02:00",`
            ~ `"timestamp":"2026-11-19T15:01:50.000Z"}`, json);
    auto back = mapper().readValue!Stamped(json);
    assert(back.timestamp.getTime() == 1_795_100_510_000L);
    assert(back.day.getTime() == 1_795_046_400_000L);
    assert(back.epoch.getTime() == 1_234_567_890_123L && back.local.getTime() == 0);
}

@("java.util.Date: map keys match Jackson 3.1.8 (dates.tsv)")
unittest
{
    import std.array : split;
    import std.conv : to;
    import std.string : lineSplitter;

    size_t keys;
    foreach (line; import("dates.tsv").lineSplitter)
    {
        const row = line.split("\t");
        if (row[0] == "writekey")
        {
            auto map = new HashMap!(Date, int)();
            map.put(new Date(row[2].to!long), 1);
            auto b = JsonMapper.builder().descriptors(mapper().descriptors());
            if (row[1] != "-")
                b.configure(row[1][1 .. $].to!DateTimeFeature, true);
            const json = b.build().writeValueAsString(map);
            assert(json == row[3], json);
            ++keys;
        }
        else if (row[0] == "readkey")
        {
            string got;
            try
            {
                auto map = mapper().readValue!(HashMap!(Date, int))(row[2]);
                got = map.keySet().iterator().next().getTime().to!string;
            }
            catch (JacksonException e)
                got = "!" ~ e.getOriginalMessage();
            assert(got == row[3], row[2] ~ "\n    jackson: " ~ row[3] ~ "\n    flint:   " ~ got);
            ++keys;
        }
    }
    assert(keys == 7);
}

@("java.util.Date: a region time zone needs the zone database Flint lacks, so it is refused, not guessed")
unittest
{
    const outcome = written(caseOf("tz=Europe/Paris"), 0);
    assert(outcome[0 .. 43] == `!refused: Time zone "Europe/Paris" needs th`, outcome);
}

@("java.util.Date: readValue!Date, a Date nested in a DTO's collection, and a @JsonFormat write need no registration")
unittest
{
    assert(mapper().readValue!Date(`"2009-02-13T23:31:30.123Z"`).getTime() == 1_234_567_890_123L);
    assert(mapper().readValue!Date("0").getTime() == 0);

    auto journal = mapper().readValue!Journal(
            `{"title":"t","entries":["1970-01-01",86400000,"Sat, 17 Jan 2009 06:13:58 GMT"]}`);
    assert(journal.entries.size() == 3 && journal.entries.get(1).getTime() == 86_400_000L);
    assert(journal.entries.get(2).getTime() == 1_232_172_838_000L);
    auto list = mapper().readValue!(ArrayList!Date)(`["1970-01-02T00:00:00Z"]`);
    assert(list.get(0).getTime() == 86_400_000L);

    auto bean = new Stamped();
    bean.day = new Date(0);
    assert(JsonMapper.builder().descriptors(mapper().descriptors()).build()
            .writeValueAsString(bean) == `{"day":"1970-01-01","epoch":null,"local":null,"timestamp":null}`);
}

@("java.util.Date: plain writes need no module; erased reads without one name JavaUtilDateModule (D-JACKSON-10)")
unittest
{
    import flint.engine.aot.any : Any;

    auto plain = JsonMapper.builder().descriptors(mapper().descriptors()).build();
    assert(plain.writeValueAsString(Any.ofObject(new Date(0), DATE)) == `"1970-01-01T00:00:00.000Z"`);
    assert(plain.registeredModules().length == 0);
    try
    {
        plain.readValue(`"1970-01-01"`, DATE);
        assert(false, "expected InvalidDefinitionException");
    }
    catch (InvalidDefinitionException e)
        assert(e.getOriginalMessage()[$ - 24 .. $] == "(deviation D-JACKSON-10)", e.msg);
    auto registered = JsonMapper.builder().addModule(new JavaUtilDateModule())
        .addModule(new JavaUtilDateModule()).build();
    assert(registered.registeredModules().length == 1);
    assert(registered.readValue(`"1970-01-02"`, DATE).isNull() == false);
}

@("JacksonModule: dependencies register first, a registration id registers once, SimpleModule names itself")
unittest
{
    import flint.jackson.databind : JacksonModule;

    static final class Needs : SimpleModule
    {
        this()
        {
            super("Needs");
        }

        override JacksonModule[] getDependencies()
        {
            return [new SimpleModule("Base")];
        }
    }

    auto m = JsonMapper.builder().addModules(new Needs(), new SimpleModule("Base")).build();
    const names = [
        m.registeredModules()[0].getModuleName(), m.registeredModules()[1].getModuleName()
    ];
    assert(m.registeredModules().length == 2 && names == ["Base", "Needs"]);
    assert(new SimpleModule().getModuleName()[0 .. 13] == "SimpleModule-");
}
