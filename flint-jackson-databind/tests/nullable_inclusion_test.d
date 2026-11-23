/// Flint tests: a `std.typecons.Nullable!T` property is Java's boxed wrapper (rulebook R5), so the inclusion rules
/// Spring applications set (`flint.jackson.default-property-inclusion: non_null`) treat an empty one as null.
module nullable_inclusion_test;

import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.annotation : JsonInclude;
import flint.jackson.databind : JsonMapper;
import std.typecons : Nullable;

@safe:

private final class Dto
{
    string name = "Leo";
    Nullable!int age;
    Nullable!bool active;
    Nullable!string nickname;
}

private JsonMapper mapper(JsonInclude.Include inclusion)
{
    auto table = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!Dto(), descriptorOf!(Nullable!int)(), descriptorOf!(Nullable!bool)(),
        descriptorOf!(Nullable!string)()
    ])
        table.add(d);
    return JsonMapper.builder().descriptors(table).changeDefaultPropertyInclusion(inclusion).build();
}

@("an empty Nullable is left out under NON_NULL, NON_ABSENT and NON_EMPTY, and written as null under ALWAYS")
unittest
{
    auto dto = new Dto;
    assert(mapper(JsonInclude.Include.ALWAYS)
            .writeValueAsString(dto) == `{"active":null,"age":null,"name":"Leo","nickname":null}`);
    foreach (inclusion; [
        JsonInclude.Include.NON_NULL, JsonInclude.Include.NON_ABSENT, JsonInclude.Include.NON_EMPTY
    ])
        assert(mapper(inclusion).writeValueAsString(dto) == `{"name":"Leo"}`);
    dto.age = 0;
    dto.active = false;
    dto.nickname = "";
    assert(mapper(JsonInclude.Include.NON_NULL)
            .writeValueAsString(dto) == `{"active":false,"age":0,"name":"Leo","nickname":""}`);
    assert(mapper(JsonInclude.Include.NON_EMPTY).writeValueAsString(dto) == `{"active":false,"age":0,"name":"Leo"}`);
}
