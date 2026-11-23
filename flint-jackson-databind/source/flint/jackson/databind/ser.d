/*
 * Ported from Jackson (jackson-databind) 3.1.8, https://github.com/FasterXML/jackson-databind,
 * tag jackson-databind-3.1.8: src/main/java/tools/jackson/databind/ser/{BeanSerializer,
 * BeanPropertyWriter,PropertyWriter}.java, ser/std/{StdScalarSerializer,NumberSerializers,
 * StringSerializer,BooleanSerializer,EnumSerializer,MapSerializer,CollectionSerializer}.java
 * and ser/jdk/*.java
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: one erased serializer walks Flint AOT descriptors
 * instead of a serializer object per Java class (ADR-030 section 5); per-type state
 * is the introspected BeanDescription cached in MapperConfig.
 */

/// Serialization: from boxed values to JSON tokens, driven by descriptors.
module flint.jackson.databind.ser;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, TypeKind;
import flint.jackson.annotation : JsonFormat, JsonInclude;
import flint.jackson.core : JsonGenerator;
import flint.jackson.databind.cfg : EnumFeature, MapperConfig, SerializationFeature;
import flint.jackson.databind.exc : DatabindException, InvalidDefinitionException, Reference;
import flint.jackson.databind.ext.javatime : JavaTimeFormat, writeJavaTime;
import flint.jackson.databind.introspect : BeanDescription, BeanPropertyDefinition;
import flint.jackson.databind.node : JsonNode;
import flint.java.util : RawCollection, RawMap;

@safe:

/// Serialize `value`, whose declared Flint type is `declaredType`, through `g`; `format` is the property's
/// `@JsonFormat`, which the java.time serializers read.
void serializeValue(MapperConfig config, ref Any value, string declaredType, JsonGenerator g,
        JavaTimeFormat format = JavaTimeFormat.init)
{
    if (value.isNull())
    {
        g.writeNull();
        return;
    }
    const type = value.typeName().length ? value.typeName() : declaredType;
    if (writeScalar(value, type, g) || writeJavaTime(config, value, type, g, format))
        return;
    if (writeContainer(config, value, g))
        return;
    const d = config.descriptor(type);
    if (d is null)
        throw new InvalidDefinitionException("No serializer found for class " ~ type
                ~ ": no Flint AOT descriptor (register the type, or let Flint AOT generate it)", type);
    switch (d.kind)
    {
    case TypeKind.enum_:
        return writeEnum(config, d, value, g);
    case TypeKind.struct_:
    case TypeKind.class_:
    case TypeKind.interface_:
        return writeBean(config,
                config.bean(d), value, g);
    default:
        throw new InvalidDefinitionException("Type " ~ type ~ " (" ~ kindName(
                d.kind) ~ ") cannot be serialized until its descriptor carries element access", type);
    }
}

// Trees, maps and collections, which describe themselves.
private bool writeContainer(MapperConfig config, ref Any value, JsonGenerator g)
{
    if (auto node = cast(JsonNode) value.asObject())
        node.serialize(g);
    else if (auto map = cast(RawMap) value.asObject())
        writeMap(config, map, g);
    else if (auto collection = cast(RawCollection) value.asObject())
        writeCollection(config, collection, g);
    else
        return false;
    return true;
}

private string kindName(TypeKind kind) pure nothrow
{
    final switch (kind)
    {
    case TypeKind.scalar:
        return "scalar";
    case TypeKind.string_:
        return "string";
    case TypeKind.enum_:
        return "enum";
    case TypeKind.array:
        return "array";
    case TypeKind.struct_:
        return "struct";
    case TypeKind.class_:
        return "class";
    case TypeKind.interface_:
        return "interface";
    }
}

// The JDK scalars of Jackson's NumberSerializers, StringSerializer and BooleanSerializer.
private bool writeScalar(ref Any value, string type, JsonGenerator g)
{
    switch (type)
    {
    case "string":
        g.writeString(value.get!string());
        return true;
    case "bool":
        g.writeBoolean(value.get!bool());
        return true;
    case "byte", "short", "int", "ubyte", "ushort":
        g.writeNumber(cast(int) value.get!long());
        return true;
    case "long", "uint":
        g.writeNumber(value.get!long());
        return true;
    case "ulong":
        import std.conv : to;

        g.writeNumber(value.get!ulong().to!string);
        return true;
    case "float":
        g.writeNumber(cast(float) value.get!double());
        return true;
    case "double", "real":
        g.writeNumber(value.get!double());
        return true;
    case "char", "wchar", "dchar":
        import std.conv : to;

        // Java's char serializes as a one-character String.
        g.writeString([value.get!dchar()].to!string);
        return true;
    default:
        return false;
    }
}

private void writeEnum(MapperConfig config, const Descriptor d, ref Any value, JsonGenerator g)
{
    import std.conv : to;
    import std.uni : toLower;

    // Any keeps an enum's value; Flint enums count from 0, so the value is the constant's index.
    const index = cast(size_t) value.get!long();
    if (config.isEnabled(EnumFeature.WRITE_ENUMS_USING_INDEX))
    {
        g.writeNumber(cast(int) index);
        return;
    }
    if (index >= d.enumConstants.length)
        throw new InvalidDefinitionException(
                "Enum value " ~ index.to!string ~ " of " ~ d.name ~ " has no constant name in its descriptor", d.name);
    const name = d.enumConstants[index];
    g.writeString(config.isEnabled(EnumFeature.WRITE_ENUMS_TO_LOWERCASE) ? name.toLower() : name);
}

private void writeCollection(MapperConfig config, RawCollection collection, JsonGenerator g)
{
    auto elements = collection.toAnyArray();
    g.writeStartArray();
    foreach (i, ref e; elements)
        withPath(Reference(null, cast(int) i, "java.util.List"), () {
            serializeValue(config, e, null, g);
        });
    g.writeEndArray();
}

private void writeMap(MapperConfig config, RawMap map, JsonGenerator g)
{
    g.writeStartObject();
    foreach (key; map.keysAsAny())
    {
        auto value = map.getAny(key);
        if (!includeContent(config, value))
            continue;
        const name = keyText(config, key);
        g.writeName(name);
        withPath(Reference(name, -1, "java.util.Map"), () { serializeValue(config, value, null, g); });
    }
    g.writeEndObject();
}

private bool includeContent(MapperConfig config, ref Any value)
{
    final switch (config.defaultContentInclusion)
    {
    case JsonInclude.Include.ALWAYS:
    case JsonInclude.Include.USE_DEFAULTS:
    case JsonInclude.Include.CUSTOM:
        return true;
    case JsonInclude.Include.NON_NULL:
    case JsonInclude.Include.NON_ABSENT:
        return !value.isNull();
    case JsonInclude.Include.NON_EMPTY:
    case JsonInclude.Include.NON_DEFAULT:
        return !isEmptyValue(value);
    }
}

// StdKeySerializers: Strings as they are, numbers and booleans as their text, enums by name.
private string keyText(MapperConfig config, ref Any key)
{
    import flint.engine.aot.objects : objectToString;
    import std.conv : to;

    if (key.isNull())
        return "null";
    if (key.holds!string())
        return key.get!string();
    if (auto o = key.asObject())
        return objectToString(o);
    const d = config.descriptor(key.typeName());
    if (d !is null && d.kind == TypeKind.enum_)
    {
        const index = cast(size_t) key.get!long();
        if (index < d.enumConstants.length)
            return d.enumConstants[index];
    }
    if (key.holds!bool())
        return key.get!bool() ? "true" : "false";
    if (key.holds!long())
        return key.get!long().to!string;
    return key.toString();
}

/// Serialize a bean through its introspected properties (Jackson's `BeanSerializer.serialize`).
void writeBean(MapperConfig config, BeanDescription bean, ref Any value, JsonGenerator g)
{
    if (bean.jsonValue !is null)
    {
        auto inner = bean.jsonValue.accessor.get(value);
        serializeValue(config, inner, bean.jsonValue.type, g);
        return;
    }
    if (bean.properties.length == 0 && config.isEnabled(SerializationFeature.FAIL_ON_EMPTY_BEANS))
        throw new InvalidDefinitionException("No serializer found for class " ~ bean.descriptor.name
                ~ " and no properties discovered to create BeanSerializer", bean.descriptor.name);
    g.writeStartObject();
    foreach (p; bean.properties)
    {
        if (!p.isReadable())
            continue;
        auto v = p.accessor.get(value);
        if (!include(config, bean, p, v))
            continue;
        g.writeName(p.name);
        withPath(Reference(p.name, -1, bean.descriptor.simpleName()), () {
            writeProperty(config, p, v, g);
        });
    }
    g.writeEndObject();
}

private void writeProperty(MapperConfig config, BeanPropertyDefinition p, ref Any v, JsonGenerator g)
{
    if (p.rawValue && v.holds!string() && !v.isNull())
    {
        g.writeRawValue(v.get!string());
        return;
    }
    if (p.hasFormat && p.format.shape == JsonFormat.Shape.STRING && !v.isNull() && isNumberOrBoolean(v))
    {
        g.writeString(scalarText(v));
        return;
    }
    serializeValue(config, v, p.type, g, p.hasFormat ? JavaTimeFormat.of(p.format) : JavaTimeFormat.init);
}

private bool isNumberOrBoolean(ref Any v)
{
    return v.asObject() is null && !v.holds!string() && (v.holds!bool() || v.holds!double());
}

private string scalarText(ref Any v)
{
    import flint.serde.java_number : javaDoubleString;

    if (v.holds!bool())
        return v.get!bool() ? "true" : "false";
    if (v.holds!long())
        return v.toString();
    return javaDoubleString(v.get!double());
}

// JsonInclude: the property's setting, else the type's, else the mapper's default.
private bool include(MapperConfig config, BeanDescription bean, BeanPropertyDefinition p, ref Any v)
{
    auto rule = p.inclusion;
    if (rule == JsonInclude.Include.USE_DEFAULTS)
        rule = bean.inclusion;
    if (rule == JsonInclude.Include.USE_DEFAULTS)
        rule = config.defaultInclusion;
    final switch (rule)
    {
    case JsonInclude.Include.ALWAYS:
    case JsonInclude.Include.USE_DEFAULTS:
    case JsonInclude.Include.CUSTOM:
        return true;
    case JsonInclude.Include.NON_NULL:
    case JsonInclude.Include.NON_ABSENT:
        return !v.isNull();
    case JsonInclude.Include.NON_EMPTY:
        return !isEmptyValue(v);
    case JsonInclude.Include.NON_DEFAULT:
        return !isEmptyValue(v) && !isDefaultScalar(v);
    }
}

/// Jackson's "empty": null, an empty String, an empty collection or map.
bool isEmptyValue(ref Any v)
{
    if (v.isNull())
        return true;
    if (v.holds!string())
        return v.get!string().length == 0;
    if (auto o = v.asObject())
    {
        if (auto c = cast(RawCollection) o)
            return c.toAnyArray().length == 0;
        if (auto m = cast(RawMap) o)
            return m.keysAsAny().length == 0;
    }
    return false;
}

private bool isDefaultScalar(ref Any v)
{
    if (v.asObject() !is null || v.holds!string())
        return false;
    if (v.holds!bool())
        return !v.get!bool();
    if (v.holds!long())
        return v.get!long() == 0;
    if (v.holds!double())
        return v.get!double() == 0;
    return false;
}

/// Run `action`, adding `reference` to the path of any `DatabindException` it throws.
void withPath(Reference reference, scope void delegate() @safe action)
{
    try
        action();
    catch (DatabindException e)
        throw e.prependPath(reference);
}
