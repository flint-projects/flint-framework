/++
Flint tests: SerializationFeature.WRITE_EMPTY_JSON_ARRAYS disabled, as Jackson 3.1.8 printed it on Java 21:

    class B { List<String> list = []; int[] arr = {}; Map<String,String> map = {}; String s = ""; List<String> nul = null; }
    -> {"nul":null,"s":""}
    @JsonInclude(NON_NULL) class C { List<String> list = []; String x = null; }  -> {}
    class D { @JsonInclude(ALWAYS) List<String> list = []; }                     -> {}
    List.of(new ArrayList<>()) -> [[]]; Map.of("k", new ArrayList<>()) -> {"k":[]}

Empty container properties are left out whatever the inclusion; null ones, elements and map values are not.
+/
module write_empty_arrays_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.annotation : JsonInclude;
import flint.jackson.databind : JsonMapper, SerializationFeature;
import flint.java.util : ArrayList, HashMap, List, Map;

@safe:

private final class B
{
    List!string list;
    int[] arr = [];
    Map!(string, string) map;
    string s = "";
    List!string nul;

    this()
    {
        list = new ArrayList!string();
        map = new HashMap!(string, string)();
    }
}

@JsonInclude(JsonInclude.Include.NON_NULL)
private final class C
{
    List!string list;
    string x;

    this()
    {
        list = new ArrayList!string();
    }
}

private final class D
{
    @JsonInclude(JsonInclude.Include.ALWAYS) List!string list;

    this()
    {
        list = new ArrayList!string();
    }
}

private JsonMapper mapper(bool writeEmpty)
{
    auto table = DescriptorTable.withBuiltins();
    static foreach (T; imported!"std.meta".AliasSeq!(B, C, D, List!string, ArrayList!string,
            Map!(string, string), HashMap!(string, string), int[], List!(List!string), ArrayList!(List!string)))
        table.add(descriptorOf!T());
    return JsonMapper.builder().descriptors(table)
        .configure(SerializationFeature.WRITE_EMPTY_JSON_ARRAYS, writeEmpty).build();
}

@("WRITE_EMPTY_JSON_ARRAYS disabled leaves out empty container properties, whatever the inclusion")
unittest
{
    auto m = mapper(false);
    assert(m.writeValueAsString(new B()) == `{"nul":null,"s":""}`, m.writeValueAsString(new B()));
    assert(m.writeValueAsString(new C()) == `{}`, m.writeValueAsString(new C()));
    assert(m.writeValueAsString(new D()) == `{}`, m.writeValueAsString(new D()));
    List!(List!string) nested = new ArrayList!(List!string)();
    nested.add(new ArrayList!string());
    assert(m.writeValueAsString(nested) == `[[]]`, m.writeValueAsString(nested));
}

@("WRITE_EMPTY_JSON_ARRAYS enabled (the default) writes them")
unittest
{
    const json = mapper(true).writeValueAsString(new B());
    assert(json == `{"arr":[],"list":[],"map":{},"nul":null,"s":""}`, json);
}
