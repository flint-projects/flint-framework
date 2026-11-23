/++
Flint tests: an absent creator property of a wrapper type takes null, as Jackson 3.1.8 printed it on Java 21 (classes
compiled with -parameters, as Spring Boot compiles them):

    class Pet { Pet() {}  Pet(String name, Integer id) {...; how = "ctor"}  getters, setters }
    {"name":"Leo"} -> {"name":"Leo","id":null,"how":"ctor"}

The required-args constructor is the creator even beside a no-arg one (data-access, petclinic-rest's openapi DTOs).
+/
module creator_defaults_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : ConstructorDescriptor, DescriptorTable, ParameterDescriptor, descriptorOf;
import flint.jackson.databind : JsonMapper;
import std.typecons : Nullable;

@safe:

private final class Pet
{
    private string name;
    private Nullable!int id;
    private string how = "setters";

    this()
    {
    }

    this(string name, Nullable!int id)
    {
        this.name = name;
        this.id = id;
        how = "ctor";
    }

    string getName()
    {
        return name;
    }

    void setName(string n)
    {
        name = n;
    }

    Nullable!int getId()
    {
        return id;
    }

    void setId(Nullable!int i)
    {
        id = i;
    }

    string getHow()
    {
        return how;
    }
}

@("an absent Nullable!int creator property reads as null")
unittest
{
    // descriptorOf describes the default constructor only; Flint AOT also describes this one, unannotated, and spells
    // the parameter type `std.typecons.Nullable!(int)` where the table has `std.typecons.Nullable!int`.
    auto pet = descriptorOf!Pet();
    pet.constructors = ConstructorDescriptor([
        ParameterDescriptor("name", "string"),
        ParameterDescriptor("id", "std.typecons.Nullable!(int)")
    ], null, (scope Any[] v) => Any.of(new Pet(v[0].get!string(), v[1].get!(Nullable!int)()))) ~ pet.constructors;
    auto table = DescriptorTable.withBuiltins();
    table.add(pet);
    table.add(descriptorOf!(Nullable!int)());
    auto m = JsonMapper.builder().descriptors(table).build();
    auto read = m.readValue!Pet(`{"name":"Leo"}`);
    assert(read.getName() == "Leo" && read.getId().isNull);
    const json = m.writeValueAsString(read);
    assert(json == `{"name":"Leo","id":null,"how":"ctor"}`, json);
}
