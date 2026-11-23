/// spring-petclinic-rest's DTOs (openapi-generator 7.26.0 models) through Flint's Jackson, against the response
/// bodies the real application wrote under Spring Boot 4.2.0 (benchmarks/spring/suites/golden/petclinic-rest.json,
/// extracted to tests/golden/petclinic.tsv by petclinic_bodies.py): each body reads into the D twin of its DTO and
/// writes back byte for byte. Key order comes from the class, not the input: properties-based creator first
/// (each DTO's all-arguments constructor, SORT_CREATOR_PROPERTIES_FIRST), then the rest alphabetically.
module petclinic_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : ConstructorDescriptor, Descriptor, DescriptorTable,
    ParameterDescriptor, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.jackson.annotation : JsonAnyGetter;
import flint.jackson.databind : JsonMapper;
import flint.java.time : LocalDate;
import flint.java.util : ArrayList, LinkedHashMap, List;

@safe:

private final class PetTypeDto
{
    string name;
    int id;

    this()
    {
    }

    this(string name, int id)
    {
        this.name = name;
        this.id = id;
    }
}

private final class VisitDto
{
    LocalDate date;
    string description;
    int id;
    int petId;

    this()
    {
    }

    this(LocalDate date, string description, int id, int petId)
    {
        this.date = date;
        this.description = description;
        this.id = id;
        this.petId = petId;
    }
}

private final class PetDto
{
    string name;
    LocalDate birthDate;
    PetTypeDto type;
    int id;
    int ownerId;
    List!VisitDto visits;

    this()
    {
        visits = new ArrayList!VisitDto();
    }

    this(string name, LocalDate birthDate, PetTypeDto type, int id, List!VisitDto visits)
    {
        this.name = name;
        this.birthDate = birthDate;
        this.type = type;
        this.id = id;
        this.visits = visits;
    }
}

private final class OwnerDto
{
    string firstName;
    string lastName;
    string address;
    string city;
    string telephone;
    int id;
    List!PetDto pets;

    this()
    {
        pets = new ArrayList!PetDto();
    }

    this(string firstName, string lastName, string address, string city, string telephone, List!PetDto pets)
    {
        this.firstName = firstName;
        this.lastName = lastName;
        this.address = address;
        this.city = city;
        this.telephone = telephone;
        this.pets = pets;
    }
}

private final class SpecialtyDto
{
    int id;
    string name;

    this()
    {
    }

    this(int id, string name)
    {
        this.id = id;
        this.name = name;
    }
}

private final class VetDto
{
    string firstName;
    string lastName;
    List!SpecialtyDto specialties;
    int id;

    this()
    {
        specialties = new ArrayList!SpecialtyDto();
    }

    this(string firstName, string lastName, List!SpecialtyDto specialties, int id)
    {
        this.firstName = firstName;
        this.lastName = lastName;
        this.specialties = specialties;
        this.id = id;
    }
}

private final class RoleDto
{
    string name;

    this()
    {
    }

    this(string name)
    {
        this.name = name;
    }
}

private final class UserDto
{
    string username;
    string password;
    bool enabled;
    List!RoleDto roles;

    this()
    {
        roles = new ArrayList!RoleDto();
    }

    this(string username)
    {
        this();
        this.username = username;
    }
}

private final class OwnerPageDto
{
    List!OwnerDto content;
    int page;
    int size;
    long totalElements;
    int totalPages;

    this()
    {
        content = new ArrayList!OwnerDto();
    }

    this(List!OwnerDto content, int page, int size, long totalElements, int totalPages)
    {
        this.content = content;
        this.page = page;
        this.size = size;
        this.totalElements = totalElements;
        this.totalPages = totalPages;
    }
}

private final class PetPageDto
{
    List!PetDto content;
    int page;
    int size;
    long totalElements;
    int totalPages;

    this()
    {
        content = new ArrayList!PetDto();
    }

    this(List!PetDto content, int page, int size, long totalElements, int totalPages)
    {
        this.content = content;
        this.page = page;
        this.size = size;
        this.totalElements = totalElements;
        this.totalPages = totalPages;
    }
}

/// The application's ValidationMessageDto: `message` plus `@JsonAnyGetter` extra properties. Java's HashMap prints
/// field, defaultMessage, rejectedValue; Flint's HashMap keeps insertion order (a flint.java.util deviation), so the
/// twin inserts in Java's order.
private final class ValidationMessageDto
{
    string message;
    @JsonAnyGetter LinkedHashMap!(string, string) additionalProperties;

    this()
    {
    }

    this(string message)
    {
        this.message = message;
    }

    ValidationMessageDto putAdditionalProperty(string key, string value)
    {
        if (additionalProperties is null)
            additionalProperties = new LinkedHashMap!(string, string)();
        additionalProperties.put(key, value);
        return this;
    }
}

// What Flint AOT emits for a class: its descriptor with every public constructor, parameter names included.
private Descriptor described(T)()
{
    import std.traits : ParameterIdentifierTuple, Parameters;

    auto d = descriptorOf!T();
    static foreach (i, ctor; __traits(getOverloads, T, "__ctor"))
    {
        static if (Parameters!ctor.length > 0)
        {
            {
                ParameterDescriptor[] parameters;
                static foreach (j; 0 .. Parameters!ctor.length)
                    parameters ~= ParameterDescriptor(ParameterIdentifierTuple!ctor[j],
                            typeNameOf!(Parameters!ctor[j]));
                d.constructors ~= ConstructorDescriptor(parameters, null, &construct!(T, i));
            }
        }
    }
    return d;
}

private Any construct(T, size_t i)(scope Any[] arguments) @safe
{
    import std.traits : Parameters;

    alias ctor = __traits(getOverloads, T, "__ctor")[i];
    Parameters!ctor values;
    static foreach (j; 0 .. values.length)
        if (!arguments[j].isNull())
            values[j] = arguments[j].get!(typeof(values[j]))();
    return Any.ofObject(new T(values), typeNameOf!T);
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        described!PetTypeDto(), described!VisitDto(), described!PetDto(), described!OwnerDto(),
        described!SpecialtyDto(), described!VetDto(), described!RoleDto(),
        described!UserDto(), described!OwnerPageDto(), described!PetPageDto(),
        described!ValidationMessageDto(), descriptorOf!(List!VisitDto)(),
        descriptorOf!(ArrayList!VisitDto)(), descriptorOf!(List!PetDto)(),
        descriptorOf!(ArrayList!PetDto)(), descriptorOf!(List!OwnerDto)(),
        descriptorOf!(ArrayList!OwnerDto)(), descriptorOf!(List!SpecialtyDto)(),
        descriptorOf!(ArrayList!SpecialtyDto)(), descriptorOf!(List!RoleDto)(),
        descriptorOf!(ArrayList!RoleDto)(), descriptorOf!(List!PetTypeDto)(),
        descriptorOf!(ArrayList!PetTypeDto)(), descriptorOf!(List!VetDto)(),
        descriptorOf!(ArrayList!VetDto)(), descriptorOf!(LinkedHashMap!(string, string))()
    ])
        t.add(d);
    return t;
}

private string typeOf(string dto)
{
    switch (dto)
    {
        static foreach (T; imported!"std.meta".AliasSeq!(PetTypeDto, VisitDto, PetDto, OwnerDto,
                SpecialtyDto, VetDto, UserDto, OwnerPageDto, PetPageDto))
        {
    case __traits(identifier, T):
            return typeNameOf!T;
    case __traits(identifier, T) ~ "[]":
            return typeNameOf!(List!T);
        }
    default:
        assert(false, dto);
    }
}

@("petclinic: every recorded DTO body reads into its D twin and writes back byte for byte (petclinic.tsv)")
unittest
{
    import std.array : split;
    import std.string : lineSplitter;

    auto mapper = JsonMapper.builder().findAndAddModules().descriptors(table()).build();
    size_t cases;
    foreach (line; import("petclinic.tsv").lineSplitter)
    {
        const row = line.split("\t");
        if (row[1] == "ValidationMessageDto")
            continue;
        auto value = mapper.readValue(row[2], typeOf(row[1]));
        const written = mapper.writeValueAsString(value);
        assert(written == row[2], row[0] ~ "\nflint:      " ~ written ~ "\npetclinic: " ~ row[2]);
        ++cases;
    }
    assert(cases == 14);
}

@("petclinic: a schemaValidationErrors element writes its @JsonAnyGetter map after message")
unittest
{
    import std.array : split;
    import std.string : lineSplitter;

    auto mapper = JsonMapper.builder().findAndAddModules().descriptors(table()).build();
    foreach (line; import("petclinic.tsv").lineSplitter)
    {
        const row = line.split("\t");
        if (row[1] != "ValidationMessageDto")
            continue;
        auto dto = new ValidationMessageDto(`Field 'telephone' must match "^[0-9]{10}$" (rejected value: 01234abcde)`)
            .putAdditionalProperty("field", "telephone").putAdditionalProperty("defaultMessage",
                `must match "^[0-9]{10}$"`).putAdditionalProperty("rejectedValue", "01234abcde");
        const written = mapper.writeValueAsString(dto);
        assert(written == row[2], "\nflint:      " ~ written ~ "\npetclinic: " ~ row[2]);
        return;
    }
    assert(false, "no ValidationMessageDto row");
}

/// openapi-generator's `Integer id` (boxed, nullable) is `Nullable!int` (rulebook R5).
private final class TypeFields
{
    string name;
    imported!"std.typecons".Nullable!int id;

    this()
    {
    }

    this(string name, imported!"std.typecons".Nullable!int id)
    {
        this.name = name;
        this.id = id;
    }
}

@("petclinic: a boxed Integer (Nullable!int) reads absent or null as null, writes null, and round-trips a number")
unittest
{
    import std.typecons : Nullable;

    auto t = table();
    t.add(described!TypeFields());
    t.add(descriptorOf!(Nullable!int)());
    auto mapper = JsonMapper.builder().findAndAddModules().descriptors(t).build();
    // A request body without "id": the creator's missing boxed argument is null, not a FAIL_ON_NULL_FOR_PRIMITIVES
    // failure, as Java binds null to Integer.
    auto created = mapper.readValue!TypeFields(`{"name":"ferret"}`);
    assert(created.name == "ferret" && created.id.isNull);
    assert(mapper.writeValueAsString(created) == `{"name":"ferret","id":null}`);
    const explicit = mapper.readValue!TypeFields(`{"name":"ferret","id":null}`);
    assert(explicit.id.isNull);
    auto numbered = mapper.readValue!TypeFields(`{"id":7,"name":"ferret"}`);
    assert(numbered.id.get == 7 && mapper.writeValueAsString(numbered) == `{"name":"ferret","id":7}`);
}
