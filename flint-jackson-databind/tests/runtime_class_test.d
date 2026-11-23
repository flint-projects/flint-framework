/// Flint tests: a value of a non-final declared type is written by its runtime class, as Jackson's
/// BeanSerializerFactory does (boot's error attributes: ObjectError and FieldError in a
/// List<MessageSourceResolvable>); a runtime class without a descriptor keeps the declared type's.
module runtime_class_test;

import flint.engine.aot.descriptor : DescriptorTable, descriptorOf;
import flint.jackson.databind : JsonMapper;
import flint.java.util : ArrayList, List;

@safe:

private interface Resolvable
{
    string getCode();
}

private class ObjectError : Resolvable
{
    string getCode()
    {
        return "c";
    }

    string getObjectName()
    {
        return "o";
    }
}

// descriptorOf describes a class's own members (Flint AOT's generated descriptors add the inherited ones), so these
// implement the interface directly.
private final class FieldError : Resolvable
{
    string getCode()
    {
        return "c";
    }

    string getField()
    {
        return "f";
    }
}

private final class Undescribed : Resolvable
{
    string getCode()
    {
        return "u";
    }

    string getSecret()
    {
        return "s";
    }
}

private final class Holder
{
    List!Resolvable errors;
    Resolvable single;
}

private JsonMapper mapper()
{
    auto table = DescriptorTable.withBuiltins();
    table.add(descriptorOf!Resolvable());
    table.add(descriptorOf!ObjectError());
    table.add(descriptorOf!FieldError());
    table.add(descriptorOf!Holder());
    table.add(descriptorOf!(List!Resolvable)());
    table.add(descriptorOf!(ArrayList!Resolvable)());
    return JsonMapper.builder().descriptors(table).build();
}

@("list elements and properties are written by their runtime class")
unittest
{
    auto holder = new Holder();
    holder.errors = new ArrayList!Resolvable();
    holder.errors.add(new ObjectError());
    holder.errors.add(new FieldError());
    holder.single = new FieldError();
    const json = mapper().writeValueAsString(holder);
    assert(json == `{"errors":[{"code":"c","objectName":"o"},{"code":"c","field":"f"}],`
            ~ `"single":{"code":"c","field":"f"}}`, json);
}

@("a runtime class without a descriptor is written as its declared type")
unittest
{
    auto holder = new Holder();
    holder.single = new Undescribed();
    const json = mapper().writeValueAsString(holder);
    // The declared interface's descriptor, which descriptorOf gives no properties.
    assert(json == `{"errors":null,"single":{}}`, json);
}
