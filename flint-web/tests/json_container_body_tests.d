/++
Flint's tests of top-level collection and map bodies in `JacksonJsonHttpMessageConverter`: Spring's converter writes
any type Jackson can serialize, so a `ResponseEntity<List<OwnerDto>>` body is written element by element through the
elements' descriptors, with no descriptor of `List!OwnerDto` itself (spring-petclinic-rest's list endpoints).
+/
module flint.http.converter.json_container_body_tests;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.http : MediaType;
import flint.http.converter.json : JacksonJsonHttpMessageConverter;
import flint.http.testfixture.mock_http_messages : MockHttpOutputMessage;
import flint.jackson.databind : JsonMapper;
import flint.java.nio.charset : StandardCharsets;
import flint.java.util : ArrayList, LinkedHashMap, List, Map, Optional;

@safe:

/// A DTO as openapi-generator writes them: a class with properties.
final class PetTypeDto
{
    private int id;
    private string name;

    this(int id, string name)
    {
        this.id = id;
        this.name = name;
    }

    int getId()
    {
        return id;
    }

    string getName()
    {
        return name;
    }
}

private JacksonJsonHttpMessageConverter converter()
{
    auto table = new DescriptorTable;
    table.add(descriptorOf!PetTypeDto);
    return new JacksonJsonHttpMessageConverter(JsonMapper.builder().descriptors(table).build());
}

private string written(Any value)
{
    auto output = new MockHttpOutputMessage();
    converter().write(value, null, output);
    return output.getBodyAsString(StandardCharsets.UTF_8);
}

@("a List of DTOs is writable without a descriptor of the List and written element by element")
unittest
{
    auto json = MediaType.APPLICATION_JSON;
    assert(converter().canWrite(typeNameOf!(List!PetTypeDto), &json));
    assert(converter().canWrite(typeNameOf!(ArrayList!PetTypeDto), &json));
    assert(converter().canWrite(typeNameOf!(Map!(string, PetTypeDto)), &json));

    List!PetTypeDto types = new ArrayList!PetTypeDto([
        new PetTypeDto(1, "cat"), new PetTypeDto(2, "dog")
    ]);
    assert(written(Any.of(types)) == `[{"id":1,"name":"cat"},{"id":2,"name":"dog"}]`, written(Any.of(types)));
    assert(written(Any.of(cast(List!PetTypeDto) new ArrayList!PetTypeDto())) == "[]");
}

@("a Map of DTOs is written entry by entry")
unittest
{
    Map!(string, PetTypeDto) byName = new LinkedHashMap!(string, PetTypeDto)();
    byName.put("cat", new PetTypeDto(1, "cat"));
    assert(written(Any.of(byName)) == `{"cat":{"id":1,"name":"cat"}}`, written(Any.of(byName)));
}

@("types that are neither described nor java.util containers stay unwritable")
unittest
{
    auto json = MediaType.APPLICATION_JSON;
    assert(!converter().canWrite("app.Unknown", &json));
    assert(!converter().canWrite("flint.java.util.Locale", &json));
    assert(!converter().canWrite(typeNameOf!(Optional!PetTypeDto), &json));
}
