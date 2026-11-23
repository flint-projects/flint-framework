/// Byte equality with Jackson 3.1.8 under Spring Boot 4.2's default mapper: each case is the D twin of a case in
/// tests/golden/GoldenDatabind.java, whose output the real Jackson wrote to tests/golden/databind/.
///
/// Descriptors come from `descriptorOf!T`, the reflective builder that produces what Flint AOT generates; the one
/// constructor descriptor Flint AOT emits for a class with a parameterized constructor is written by hand below.
module golden_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : ConstructorDescriptor, Descriptor, DescriptorTable,
    ParameterDescriptor, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.jackson.annotation : JsonIgnore, JsonInclude, JsonProperty, JsonPropertyOrder;
import flint.jackson.databind : JsonMapper, PropertyNamingStrategies, SerializationFeature;
import flint.jackson.databind.node : ArrayNode, JsonNode, ObjectNode;
import flint.java.util : ArrayList, LinkedHashMap, List, Map;

@safe:

/// gs-rest-service's Greeting: a record, so a struct (rulebook R11).
private struct Greeting
{
    long id;
    string content;
}

private final class Owner
{
    long id = 1;
    string lastName = "Franklin";
    string firstName = "George";
    string address = "110 W. Liberty St.";
    string city = "Madison";
    string telephone = "6085551023";
    List!string pets;

    this()
    {
        pets = new ArrayList!string();
        pets.add("Leo");
    }
}

@JsonPropertyOrder(["id", "name", "birthDate", "type"])
private final class Pet
{
    int id = 7;
    string type = "cat";
    string name = "Leo";
    string birthDate = "2010-09-07";
    string owner;
}

private final class Annotated
{
    @JsonProperty("first_name")
    string firstName = "Betty";
    @JsonIgnore
    string password = "secret";
    @JsonInclude(JsonInclude.Include.NON_NULL)
    string nickname;
    @JsonInclude(JsonInclude.Include.NON_EMPTY)
    List!string tags;
    @JsonInclude(JsonInclude.Include.NON_EMPTY)
    string note = "";
    string lastName = "Davis";
    string middle;

    this()
    {
        tags = new ArrayList!string();
    }
}

@JsonInclude(JsonInclude.Include.NON_NULL)
private final class Sparse
{
    string present = "yes";
    string absent;
    Object count;
    int zero;
}

private final class Vet
{
    private int id_;
    private string lastName_;
    private string firstName_;

    this(int id, string lastName, string firstName)
    {
        id_ = id;
        lastName_ = lastName;
        firstName_ = firstName;
    }

    int getId()
    {
        return id_;
    }

    string getLastName()
    {
        return lastName_;
    }

    string getFirstName()
    {
        return firstName_;
    }

    int getAlphaFirst()
    {
        return 9;
    }

    string getZulu()
    {
        return "z";
    }
}

private final class Numbers
{
    int anInt = -42;
    long aLong = 9_007_199_254_740_993L;
    double aDouble = 0.1;
    double big = 1e21;
    double integral = 100.0;
    float aFloat = 1.1f;
    bool flag = true;
    char letter = 'x';
    short aShort = -7;
    byte aByte = 5;
}

private final class Nested
{
    Greeting greeting = Greeting(2, "nested");
    Object none;
    Map!(string, int) counts;
    List!Greeting greetings;

    this()
    {
        counts = new LinkedHashMap!(string, int)();
        counts.put("b", 2);
        counts.put("a", 1);
        greetings = new ArrayList!Greeting();
        greetings.add(Greeting(3, "x"));
        greetings.add(Greeting(4, "y"));
    }
}

private final class Snake
{
    string firstName = "Helen";
    int visitCount = 3;
    string homePageUrl = "/vets";
}

// What Flint AOT emits for Vet's only constructor: its parameters by name and an invoker.
private Descriptor vetDescriptor()
{
    auto d = descriptorOf!Vet();
    static Any invoke(scope Any[] a) @safe
    {
        return Any.of(new Vet(a[0].get!int(), a[1].get!string(), a[2].get!string()));
    }

    d.constructors = [
        ConstructorDescriptor([
            ParameterDescriptor("id", "int"), ParameterDescriptor("lastName", "string"),
            ParameterDescriptor("firstName", "string")
        ], null, &invoke)
    ];
    return d;
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!Greeting(), descriptorOf!Owner(), descriptorOf!Pet(),
        descriptorOf!Annotated(), descriptorOf!Sparse(), vetDescriptor(), descriptorOf!Numbers(),
        descriptorOf!Nested(), descriptorOf!Snake(), descriptorOf!(ArrayList!string)(),
        descriptorOf!(List!string)(), descriptorOf!(ArrayList!Greeting)()
    ])
        t.add(d);
    return t;
}

private JsonMapper.Builder builder()
{
    return JsonMapper.builder().findAndAddModules().descriptors(table());
}

private void same(string actual, string expected)
{
    assert(actual == expected, "\nflint:   " ~ actual ~ "\njackson: " ~ expected);
}

@("golden: gs-rest-service's Greeting record keeps its component order")
unittest
{
    same(builder().build().writeValueAsString(Greeting(1, "Hello, World!")), import("databind/greeting.json"));
}

@("golden: a Java Beans class prints alphabetically (SORT_PROPERTIES_ALPHABETICALLY, Jackson 3's default)")
unittest
{
    same(builder().build().writeValueAsString(new Owner()), import("databind/owner.json"));
}

@("golden: @JsonPropertyOrder names first, then the rest alphabetically")
unittest
{
    same(builder().build().writeValueAsString(new Pet()), import("databind/pet.json"));
}

@("golden: @JsonProperty, @JsonIgnore and property-level @JsonInclude")
unittest
{
    same(builder().build().writeValueAsString(new Annotated()), import("databind/annotated.json"));
}

@("golden: class-level @JsonInclude(NON_NULL)")
unittest
{
    same(builder().build().writeValueAsString(new Sparse()), import("databind/sparse.json"));
}

@("golden: a properties-based creator's parameters come first, in constructor order")
unittest
{
    same(builder().build().writeValueAsString(new Vet(5, "Carter", "James")), import("databind/vet.json"));
}

@("golden: Java numbers, booleans and char")
unittest
{
    same(builder().build().writeValueAsString(new Numbers()), import("databind/numbers.json"));
}

@("golden: nested records, null references, LinkedHashMap and List")
unittest
{
    same(builder().build().writeValueAsString(new Nested()), import("databind/nested.json"));
}

@("golden: a List of records at the root")
unittest
{
    auto list = new ArrayList!Greeting();
    list.add(Greeting(1, "a"));
    list.add(Greeting(2, "b"));
    same(builder().build().writeValueAsString(list), import("databind/greeting_list.json"));
}

@("golden: writerWithDefaultPrettyPrinter and INDENT_OUTPUT")
unittest
{
    same(builder().build().writerWithDefaultPrettyPrinter().writeValueAsString(new Owner()),
            import("databind/owner_pretty.json"));
    same(builder().enable(SerializationFeature.INDENT_OUTPUT).build()
            .writeValueAsString(new Nested()), import("databind/nested_indent.json"));
}

@("golden: SNAKE_CASE and KEBAB_CASE naming strategies, applied before sorting")
unittest
{
    same(builder().propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE).build()
            .writeValueAsString(new Snake()), import("databind/snake.json"));
    same(builder().propertyNamingStrategy(PropertyNamingStrategies.KEBAB_CASE).build()
            .writeValueAsString(new Snake()), import("databind/kebab.json"));
}

@("golden: a NON_NULL default inclusion (Boot's flint.jackson.default-property-inclusion)")
unittest
{
    same(builder().changeDefaultPropertyInclusion(JsonInclude.Include.NON_NULL).build()
            .writeValueAsString(new Pet()), import("databind/default_non_null.json"));
}

@("golden: a tree built with ObjectNode and ArrayNode, compact and pretty")
unittest
{
    auto mapper = builder().build();
    ObjectNode tree = mapper.createObjectNode();
    tree.put("name", "tree").put("count", 3).put("ratio", 0.5).put("ok", false).putNull("missing");
    ArrayNode items = tree.putArray("items");
    items.add(1).add("two").addObject().put("three", 3L);
    tree.putObject("empty");
    same(tree.toString(), import("databind/tree.json"));
    same(tree.toPrettyString(), import("databind/tree_pretty.json"));
}

@("golden: readTree then toString round-trips numbers, nulls and nesting")
unittest
{
    auto mapper = builder().build();
    same(mapper.readTree(`{"b":[1,2.5,"x",null,true],"a":{"c":12345678901}}`).toString(),
            import("databind/tree_roundtrip.json"));
}

@("golden: readValue into a record skips unknown properties (FAIL_ON_UNKNOWN_PROPERTIES is false)")
unittest
{
    auto mapper = builder().build();
    auto read = mapper.readValue!Greeting(`{"content":"Hi","extra":[1,{"x":2}],"id":7}`);
    assert(read == Greeting(7, "Hi"));
    same(mapper.writeValueAsString(read), import("databind/read_greeting.json"));
}

@("golden: readValue into a Java Beans class keeps defaults for absent properties and fills a List")
unittest
{
    auto mapper = builder().build();
    auto owner = mapper.readValue!Owner(`{"firstName":"Jean","id":6,"pets":["Max","Samantha"]}`);
    same(mapper.writeValueAsString(owner), import("databind/read_owner.json"));
}

@("golden: readValue through a properties-based creator")
unittest
{
    auto mapper = builder().build();
    auto vet = mapper.readValue!Vet(`{"firstName":"Linda","lastName":"Douglas","id":3}`);
    same(mapper.writeValueAsString(vet), import("databind/read_vet.json"));
}

@("golden: scalar coercions: numeric strings, float to long, \"NaN\", \"false\", a one-character String to char")
unittest
{
    auto mapper = builder().build();
    auto numbers = mapper.readValue!Numbers(`{"anInt":"12","aLong":3.9,"aDouble":"NaN","flag":"false","letter":"q"}`);
    same(mapper.writeValueAsString(numbers), import("databind/read_numbers.json"));
}

@("golden: convertValue from a record to an untyped value (Jackson's Map, Flint's tree)")
unittest
{
    auto mapper = builder().build();
    auto converted = mapper.convertValue!ObjectNode(Greeting(8, "converted"));
    same(mapper.writeValueAsString(converted), import("databind/convert_map.json"));
}
