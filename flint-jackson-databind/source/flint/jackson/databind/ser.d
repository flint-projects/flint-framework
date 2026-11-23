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
import flint.jackson.databind.cfg : EnumFeature, MapperConfig, MapperFeature, SerializationFeature;
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
    const type = value.typeName().length ? value.typeName() : declaredType;
    if (value.isNull())
        return writeNull(type, g);
    if (writeScalar(value, type, g) || writeBytes(value, type, g) || writeJavaTime(config, value, type, g, format))
        return;
    if (!writeContainer(config, value, g))
        writeDescribed(config, value, type, g, format);
}

// Values serialized through their descriptor: Optional, arrays, associative arrays, enums and beans.
private void writeDescribed(MapperConfig config, ref Any value, string type, JsonGenerator g, JavaTimeFormat format)
{
    if (auto o = value.asObject())
    {
        // BeanSerializerFactory: a value of a non-final declared type is written by its runtime class, when that
        // class is described (an ObjectError in a List!MessageSourceResolvable writes ObjectError's properties).
        const runtime = typeid(o).name;
        if (runtime != type)
            if (auto actual = config.descriptor(runtime))
            {
                auto exact = Any.ofObject(o, runtime);
                return writeDescribed(config, exact, runtime, g, format);
            }
    }
    const d = config.descriptor(type);
    if (d is null)
        throw new InvalidDefinitionException("No serializer found for class " ~ type
                ~ ": no Flint AOT descriptor (register the type, or let Flint AOT generate it)", type);
    if (writeShaped(config, d, value, g, format))
        return;
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

// D has no null array distinct from an empty one (`[]` is null), so an array writes as empty: `[]`, or "" for
// Base64 bytes (deviation D-JACKSON-6). Every other null writes as null.
private void writeNull(string type, JsonGenerator g)
{
    const array = type.length > 2 && type[$ - 2 .. $] == "[]";
    if (array && (type == "byte[]" || type == "ubyte[]"))
        g.writeString("");
    else if (array)
    {
        g.writeStartArray();
        g.writeEndArray();
    }
    else
        g.writeNull();
}

// Types whose descriptors carry erased access: Optional (Jdk8OptionalSerializer writes the value or null), arrays and
// collections without RawCollection (ObjectArraySerializer and the primitive array serializers), and associative
// arrays (MapSerializer).
private bool writeShaped(MapperConfig config, const Descriptor d, ref Any value, JsonGenerator g, JavaTimeFormat format)
{
    if (d.unwrap !is null)
    {
        auto inner = d.unwrap(value);
        serializeValue(config, inner, d.elementType, g, format);
    }
    else if (d.length !is null && d.element !is null)
    {
        const count = d.length(value);
        g.writeStartArray();
        foreach (i; 0 .. count)
        {
            auto e = d.element(value, i);
            withPath(Reference(null, cast(int) i, null, d.name), () {
                serializeValue(config, e, d.elementType, g);
            });
        }
        g.writeEndArray();
    }
    else if (d.toKeys !is null && d.toValues !is null)
        writeEntries(config, d.toKeys(value), d.toValues(value), d.elementType, g);
    else
        return false;
    return true;
}

private void writeEntries(MapperConfig config, Any[] keys, Any[] values, string valueType, JsonGenerator g)
{
    g.writeStartObject();
    foreach (i, ref key; keys)
    {
        if (!includeContent(config, values[i]))
            continue;
        const name = keyText(config, key);
        g.writeName(name);
        withPath(Reference(name, -1, "java.util.Map"), () {
            serializeValue(config, values[i], valueType, g);
        });
    }
    g.writeEndObject();
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
        import flint.engine.aot.text : decimal;

        g.writeNumber(decimal(value.get!ulong()));
        return true;
    case "float":
        g.writeNumber(cast(float) value.get!double());
        return true;
    case "double", "real":
        g.writeNumber(value.get!double());
        return true;
    case "char", "wchar", "dchar":
        // Java's char serializes as a one-character String.
        g.writeString(imported!"flint.engine.aot.text".utf8(value.get!dchar()));
        return true;
    default:
        return false;
    }
}

// ByteArraySerializer: Base64 (MIME without line feeds, padded).
private bool writeBytes(ref Any value, string type, JsonGenerator g)
{
    import flint.jackson.databind.base64 : encodeBase64;

    if (type == "byte[]")
        g.writeString(encodeBase64(cast(const(ubyte)[]) value.get!(byte[])()));
    else if (type == "ubyte[]")
        g.writeString(encodeBase64(value.get!(ubyte[])()));
    else
        return false;
    return true;
}

/// The declaration index of an enum value: the position of its bits in `Descriptor.enumValues`, or the bits
/// themselves when the descriptor lists no values.
size_t enumIndex(const Descriptor d, ref Any value)
{
    const bits = value.isEnum() ? value.enumBits() : value.get!long();
    foreach (i, v; d.enumValues)
        if (v == bits)
            return i;
    return cast(size_t) bits;
}

private void writeEnum(MapperConfig config, const Descriptor d, ref Any value, JsonGenerator g)
{
    import flint.engine.aot.text : decimal;
    import flint.jackson.databind : lowerCase;

    const index = enumIndex(d, value);
    if (config.isEnabled(EnumFeature.WRITE_ENUMS_USING_INDEX))
    {
        g.writeNumber(cast(int) index);
        return;
    }
    if (index >= d.enumConstants.length)
        throw new InvalidDefinitionException("Enum value " ~ decimal(
                cast(ulong) index) ~ " of " ~ d.name ~ " has no constant name in its descriptor", d.name);
    const name = d.enumConstants[index];
    g.writeString(config.isEnabled(EnumFeature.WRITE_ENUMS_TO_LOWERCASE) ? lowerCase(name) : name);
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

private bool includeContent(MapperConfig config, ref Any content)
{
    auto value = unwrapNullable(config, content);
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
    import flint.engine.aot.text : decimal;

    if (key.isNull())
        return "null";
    if (key.holds!string())
        return key.get!string();
    if (auto o = key.asObject())
        return objectToString(o);
    const d = config.descriptor(key.typeName());
    if (d !is null && d.kind == TypeKind.enum_)
    {
        const index = enumIndex(d, key);
        if (index < d.enumConstants.length)
            return d.enumConstants[index];
    }
    if (key.holds!bool())
        return key.get!bool() ? "true" : "false";
    if (key.holds!long())
        return decimal(key.get!long());
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
    writeFields(config, bean, value, g, null, null);
    g.writeEndObject();
}

// The properties of a bean, each name wrapped in `prefix` and `suffix` (an @JsonUnwrapped property's renaming).
// As Jackson's BeanSerializer orders them: the regular properties, then the unwrapped ones, then the any-getter.
private void writeFields(MapperConfig config, BeanDescription bean, ref Any value, JsonGenerator g,
        string prefix, string suffix)
{
    foreach (unwrappedPass; [false, true])
        foreach (p; bean.properties)
            if (p.unwrapped == unwrappedPass)
                writeField(config, bean, p, value, g, prefix, suffix);
    if (bean.anyGetter !is null)
        writeAnyGetter(config, bean, value, g);
}

private void writeField(MapperConfig config, BeanDescription bean, BeanPropertyDefinition p,
        ref Any value, JsonGenerator g, string prefix, string suffix)
{
    {
        if (!p.isReadable())
            return;
        auto v = p.accessor.get(value);
        if (!include(config, bean, p, v))
            return;
        // BeanPropertyWriter._handleSelfReference: a property whose value is the bean itself.
        if (auto self = v.asObject())
            if (self is value.asObject() && !p.unwrapped && bean.jsonValue is null)
            {
                if (config.isEnabled(SerializationFeature.WRITE_SELF_REFERENCES_AS_NULL))
                {
                    g.writeName(prefix.length || suffix.length ? prefix ~ p.name ~ suffix : p.name);
                    g.writeNull();
                    return;
                }
                if (config.isEnabled(SerializationFeature.FAIL_ON_SELF_REFERENCES))
                    throw new InvalidDefinitionException("Direct self-reference leading to cycle", bean.descriptor.name)
                        .prependPath(Reference(p.name, -1, null, bean.descriptor.name));
            }
        withPath(Reference(p.name, -1, null, bean.descriptor.name), () {
            if (p.unwrapped)
                return writeUnwrapped(config, p, v, g, prefix ~ p.unwrapPrefix, p.unwrapSuffix ~ suffix);
            g.writeName(prefix.length || suffix.length ? prefix ~ p.name ~ suffix : p.name);
            writeProperty(config, p, v, g);
        });
    }
}

// UnwrappingBeanSerializer: a null value writes nothing; a bean writes its properties into the enclosing object.
private void writeUnwrapped(MapperConfig config, BeanPropertyDefinition p, ref Any v, JsonGenerator g,
        string prefix, string suffix)
{
    if (v.isNull())
        return;
    const type = v.typeName().length ? v.typeName() : p.type;
    const d = config.descriptor(type);
    if (d is null || (d.kind != TypeKind.struct_ && d.kind != TypeKind.class_))
        throw new InvalidDefinitionException("@JsonUnwrapped property `" ~ p.internalName
                ~ "` of type " ~ type ~ " is not a bean with a Flint AOT descriptor", type);
    writeFields(config, config.bean(d), v, g, prefix, suffix);
}

// AnyGetterWriter: the map's entries, in its iteration order, as further properties; nothing for a null map.
private void writeAnyGetter(MapperConfig config, BeanDescription bean, ref Any value, JsonGenerator g)
{
    auto map = bean.anyGetter.accessor.get(value);
    if (map.isNull())
        return;
    Any[] keys, values;
    if (auto raw = cast(RawMap) map.asObject())
    {
        keys = raw.keysAsAny();
        foreach (ref key; keys)
            values ~= raw.getAny(key);
    }
    else if (auto d = config.descriptor(map.typeName()))
    {
        if (d.toKeys is null || d.toValues is null)
            throw new InvalidDefinitionException("@JsonAnyGetter property `" ~ bean.anyGetter.internalName
                    ~ "` of " ~ bean.descriptor.name ~ " is not a map", bean.descriptor.name);
        keys = d.toKeys(map);
        values = d.toValues(map);
    }
    foreach (i, ref key; keys)
    {
        if (!includeContent(config, values[i]))
            continue;
        const name = keyText(config, key);
        g.writeName(name);
        withPath(Reference(name, -1, null, bean.descriptor.name), () {
            serializeValue(config, values[i], null, g);
        });
    }
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

// A `std.typecons.Nullable!T` value is Java's boxed wrapper (`Integer`, `Boolean`): null when empty, otherwise its
// value. Anything else is returned as it is.
private Any unwrapNullable(MapperConfig config, ref Any value, out bool wrapper)
{
    enum prefix = "std.typecons.Nullable!";
    const type = value.typeName();
    if (type.length > prefix.length && type[0 .. prefix.length] == prefix)
        if (auto d = config.descriptor(type))
            if (d.unwrap !is null)
            {
                wrapper = true;
                return d.unwrap(value);
            }
    return value;
}

// ditto
private Any unwrapNullable(MapperConfig config, ref Any value)
{
    bool wrapper;
    return unwrapNullable(config, value, wrapper);
}

// JsonInclude: the property's setting, else the type's, else the mapper's default.
private bool include(MapperConfig config, BeanDescription bean, BeanPropertyDefinition p, ref Any property)
{
    bool wrapper;
    auto v = unwrapNullable(config, property, wrapper);
    // With WRITE_EMPTY_JSON_ARRAYS disabled an empty container property is left out, whatever the inclusion.
    if (!config.isEnabled(SerializationFeature.WRITE_EMPTY_JSON_ARRAYS) && isEmptyContainer(config, v))
        return false;
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
        return includeNonDefault(config, p, v, wrapper);
    }
}

// NON_DEFAULT: unequal to the property's value in a default-constructed bean when the type is NON_DEFAULT
// (PropertyBuilder's real defaults), otherwise neither empty nor its type's default (0, false).
private bool includeNonDefault(MapperConfig config, BeanPropertyDefinition p, ref Any v, bool wrapper)
{
    if (p.realDefault)
    {
        bool defaultWrapper;
        auto defaultValue = p.defaultValue;
        auto suppressed = unwrapNullable(config, defaultValue, defaultWrapper);
        return suppressed.isNull() ? !v.isNull() : !valueEquals(config, v, suppressed);
    }
    // [databind#5570]: with WRAPPERS_DEFAULT_TO_NULL a wrapper's default is null, not its primitive's.
    if (wrapper && config.isEnabled(MapperFeature.WRAPPERS_DEFAULT_TO_NULL))
        return !v.isNull();
    return !isEmptyValue(v) && !isDefaultScalar(v);
}

// `Object.equals` for a property value and its default: equal scalars and Strings, `equals` for references, and
// arrays element by element (ArrayBuilders' comparator).
private bool valueEquals(MapperConfig config, ref Any a, ref Any b)
{
    import flint.engine.aot.objects : objectEquals;

    if (a.isNull() || b.isNull())
        return a.isNull() && b.isNull();
    if (a == b)
        return true;
    if (a.typeName() != b.typeName())
        return false;
    if (auto o = a.asObject())
        return objectEquals(o, b.asObject());
    const d = config.descriptor(a.typeName());
    if (d is null || d.length is null || d.element is null || d.length(a) != d.length(b))
        return false;
    foreach (i; 0 .. d.length(a))
    {
        auto x = d.element(a, i);
        auto y = d.element(b, i);
        if (!valueEquals(config, x, y))
            return false;
    }
    return true;
}

// A Collection, Map, array or associative array without elements (Jackson's container types); null is not one.
private bool isEmptyContainer(MapperConfig config, ref Any v)
{
    if (v.holds!string())
        return false;
    if (auto o = v.asObject())
    {
        if (auto c = cast(RawCollection) o)
            return c.toAnyArray().length == 0;
        if (auto m = cast(RawMap) o)
            return m.keysAsAny().length == 0;
        return false;
    }
    const d = v.typeName().length ? config.descriptor(v.typeName()) : null;
    if (d is null)
        return false;
    // A null D array is the empty array (D-JACKSON-6).
    if (d.kind == TypeKind.array)
        return v.isNull() || (d.length !is null && d.length(v) == 0);
    return !v.isNull() && d.toKeys !is null && d.toKeys(v).length == 0;
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
