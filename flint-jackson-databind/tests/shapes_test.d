/// Jackson 3.1.8 under Spring Boot 4.2's default mapper on arrays, byte[], Optional, maps, enums, records and
/// @JsonNaming: each case is the D twin of a case in tests/golden/GoldenShapes.java, whose results the real Jackson
/// wrote to tests/golden/shapes.tsv. Java's nested class names (`GoldenShapes$Color`) read as this module's
/// (`shapes_test.Color`).
module shapes_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : ConstructorDescriptor, Descriptor, DescriptorTable,
    ParameterDescriptor, descriptorOf;
import flint.jackson.core : JacksonException;
import flint.jackson.annotation : JsonIgnore, JsonProperty, JsonUnwrapped;
import flint.jackson.databind : JsonMapper, PropertyNamingStrategies;
import flint.jackson.databind.annotation : JsonNaming;
import flint.jackson.databind.deser : compactKeyOrder;
import flint.java.lang : classOf;
import flint.java.util : ArrayList, List, Optional;

@safe:

private enum Color
{
    RED,
    GREEN,
    BLUE,
}

/// A record (rulebook R11); Flint AOT gives it a canonical constructor, built by hand below.
private struct Point
{
    int x;
    int y;
    string label;
}

private final class Shapes
{
    int[] counts = [1, 2, 3];
    string[] names = ["a", "b"];
    byte[] bytes = [1, 2, 3, -1];
    double[] empty = [];
    Optional!string present;
    Optional!string absent;
    Optional!int number;
    int[string] scores;
    Color color = Color.GREEN;
    List!Color palette;
    Point point = Point(1, 2, "p");
    Point[] points = [Point(3, 4, null)];

    this()
    {
        present = Optional!string.of("here");
        number = Optional!int.of(7);
        scores = ["ann": 3];
        palette = new ArrayList!Color();
        palette.add(Color.BLUE);
        palette.add(Color.RED);
    }
}

@JsonNaming(classOf!(PropertyNamingStrategies.SnakeCaseStrategy))
private final class Snaked
{
    string firstName = "Ann";
    int zipCode = 53_703;
    @JsonProperty("Explicit") string renamed = "kept";

    override string toString() const
    {
        import std.conv : to;

        return firstName ~ " " ~ zipCode.to!string ~ " " ~ renamed;
    }
}

@JsonNaming(classOf!(PropertyNamingStrategies.KebabCaseStrategy))
private struct Kebab
{
    string homeTown;
    int areaCode;
}

private Any invokeKebab(scope Any[] arguments) @safe
{
    return Any.of(Kebab(arguments[0].get!string(), arguments[1].get!int()));
}

private Descriptor kebabDescriptor()
{
    auto d = descriptorOf!Kebab();
    d.constructors = ConstructorDescriptor([
        ParameterDescriptor("homeTown", "string"), ParameterDescriptor("areaCode", "int")
    ], null, &invokeKebab, true) ~ d.constructors;
    return d;
}

private struct Status
{
    string code = "UP";
    string description = "ok";
}

private final class StatusClass
{
    string code = "UP";
}

private struct Inner
{
    @JsonUnwrapped(prefix : "in_") Status status;
    int level = 3;
}

/// Boot's HealthDescriptor shape: unwrapped values, a prefixed and suffixed one, a nested one and a null one.
private final class Unwrapping
{
    @JsonUnwrapped Status status;
    int count = 2;
    @JsonUnwrapped(prefix : "x_", suffix:
            "_y") Status other;
    @JsonUnwrapped(prefix : "deep_") Inner inner;
    @JsonUnwrapped StatusClass none;
}

/// An ignored property and another renamed to the ignored one's name (Boot's getStatus/getStatusCode).
private final class Renamed
{
    @JsonIgnore string status = "ignored";
    @JsonProperty("status") string statusCode = "UP";
    string name = "n";
}

private Any invokePoint(scope Any[] arguments) @safe
{
    return Any.of(Point(arguments[0].get!int(), arguments[1].get!int(), arguments[2].get!string()));
}

private Descriptor pointDescriptor()
{
    auto d = descriptorOf!Point();
    d.constructors = [
        ConstructorDescriptor([
            ParameterDescriptor("x", "int"), ParameterDescriptor("y", "int"),
            ParameterDescriptor("label", "string")
        ], null, &invokePoint, true)
    ] ~ d.constructors;
    return d;
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    t.add(descriptorOf!Shapes());
    t.add(pointDescriptor());
    t.add(kebabDescriptor());
    static foreach (T; imported!"std.meta".AliasSeq!(Color, int[], string[], byte[], double[],
            Optional!string, Optional!int, int[string], List!Color, ArrayList!Color, Point[],
            Snaked, Status, Inner, StatusClass, Unwrapping, Renamed))
        t.add(descriptorOf!T());
    return t;
}

private JsonMapper mapper()
{
    return JsonMapper.builder().findAndAddModules().descriptors(table()).build();
}

// The value each `write` case of GoldenShapes.java serializes with the default mapper.
private struct WriteCase
{
    string name;
    Any function() @safe value;
}

private static immutable WriteCase[] writeCases = [
    WriteCase("shapes", () => Any.of(new Shapes())), WriteCase("color", () => Any.of(Color.BLUE)),
    WriteCase("point", () => Any.of(Point(5, 6, "q"))), WriteCase("ints", () => Any.of([4, 5])),
    WriteCase("bytes_empty", () => Any.of(cast(byte[])[])),
    WriteCase("optional_empty", () => Any.of(Optional!string.init)),
    WriteCase("snaked", () => Any.of(new Snaked())),
    WriteCase("kebab", () => Any.of(Kebab("Madison", 608))),
    WriteCase("unwrapping", () => Any.of(new Unwrapping())),
    WriteCase("renamed", () => Any.of(new Renamed())),
];

private string written(string name)
{
    if (name == "kebab_over_global")
        return JsonMapper.builder().findAndAddModules().descriptors(table()).propertyNamingStrategy(
                PropertyNamingStrategies.UPPER_CAMEL_CASE()).build().writeValueAsString(Kebab("Madison", 608));
    foreach (ref c; writeCases)
        if (c.name == name)
            return mapper().writeValueAsString(c.value());
    assert(false, name);
}

// Java's Arrays.toString, List.toString and record toString.
private string list(T)(const(T)[] items)
{
    import std.conv : to;

    string text = "[";
    foreach (i, item; items)
    {
        static if (is(T == string))
            const shown = item is null ? "null" : item;
        else static if (is(T == Point))
            const shown = point(item);
        else static if (is(T == double))
            const shown = imported!"flint.serde.java_number".javaDoubleString(item);
        else
            const shown = item.to!string;
        text ~= (i ? ", " : "") ~ shown;
    }
    return text ~ "]";
}

private string point(const Point p)
{
    import std.conv : to;

    const label = p.label is null ? "null" : p.label;
    return "Point[x=" ~ p.x.to!string ~ ", y=" ~ p.y.to!string ~ ", label=" ~ label ~ "]";
}

private string optional(T)(Optional!T o)
{
    import std.conv : to;

    return o.isPresent() ? "Optional[" ~ o.get().to!string ~ "]" : "Optional.empty";
}

private string shapes(Shapes s)
{
    import std.conv : to;

    string scores = "{";
    foreach (k, v; s.scores)
        scores ~= (scores.length > 1 ? ", " : "") ~ k ~ "=" ~ v.to!string;
    Color[] palette;
    foreach (c; s.palette.toArray())
        palette ~= c;
    return list(s.counts) ~ " " ~ list(s.names) ~ " " ~ list(s.bytes) ~ " " ~ list(
            s.empty) ~ " " ~ optional(s.present) ~ " " ~ optional(s.absent) ~ " " ~ optional(
            s.number) ~ " " ~ scores ~ "} " ~ s.color.to!string ~ " " ~ list(palette) ~ " " ~ point(
            s.point) ~ " " ~ list(s.points);
}

private string read(string type, string json)
{
    import std.conv : to;

    auto m = mapper();
    try
    {
        switch (type)
        {
        case "Color":
            auto v = m.readValue(json, descriptorOf!Color().name);
            return v.isNull() ? "null" : v.get!Color().to!string;
        case "Ints":
            return list(m.readValue!(int[])(json));
        case "Strings":
            return list(m.readValue!(string[])(json));
        case "Bytes":
            return list(m.readValue!(byte[])(json));
        case "Point":
            return point(m.readValue!Point(json));
        case "Snaked":
            return m.readValue!Snaked(json).toString();
        case "Kebab":
            const k = m.readValue!Kebab(json);
            return "Kebab[homeTown=" ~ k.homeTown ~ ", areaCode=" ~ k.areaCode.to!string ~ "]";
        default:
            return shapes(m.readValue!Shapes(json));
        }
    }
    catch (JacksonException e)
        return "!" ~ e.getOriginalMessage();
}

@("shapes: arrays, byte[], Optional, maps, enums and records match Jackson 3.1.8 (shapes.tsv)")
unittest
{
    import std.array : replace, split;
    import std.string : lineSplitter;

    size_t writes, reads;
    foreach (line; import("shapes.tsv").lineSplitter)
    {
        const row = line.split("\t");
        const expected = row[3].replace("GoldenShapes$", "shapes_test.");
        const got = row[0] == "write" ? written(row[1]) : read(row[1], row[2]);
        assert(got == expected, row[1] ~ " " ~ row[2] ~ "\nflint:   " ~ got ~ "\njackson: " ~ expected);
        ++(row[0] == "write" ? writes : reads);
    }
    assert(writes == 11 && reads == 20);
}

@("CompactStringObjectMap key order: primary slots, then secondary slots, then the spill area")
unittest
{
    assert(compactKeyOrder(["RED", "GREEN", "BLUE"]) == "RED, BLUE, GREEN");
    assert(compactKeyOrder(["A"]) == "A");
}
