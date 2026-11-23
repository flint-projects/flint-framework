/*
 * Ported from Jackson (jackson-databind) 3.1.8, https://github.com/FasterXML/jackson-databind,
 * tag jackson-databind-3.1.8: src/main/java/tools/jackson/databind/deser/{BeanDeserializer,
 * BeanDeserializerBase,SettableBeanProperty}.java, deser/impl/PropertyBasedCreator.java,
 * deser/std/{StdDeserializer,NumberDeserializers,StringDeserializer,CollectionDeserializer,
 * MapDeserializer}.java and deser/jdk/*.java
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: one erased deserializer walks Flint AOT descriptors
 * instead of a deserializer object per Java class (ADR-030 section 5). Scalar
 * coercions and their messages follow StdDeserializer.
 */

/// Deserialization: from JSON tokens to boxed values, driven by descriptors.
module flint.jackson.databind.deser;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, TypeKind;
import flint.jackson.core : JsonParser, JsonToken, tokenName;
import flint.jackson.databind.cfg : DeserializationFeature, MapperConfig;
import flint.jackson.databind.exc : DatabindException, InvalidDefinitionException, InvalidFormatException,
    MismatchedInputException, Reference, UnrecognizedPropertyException, ValueInstantiationException;
import flint.jackson.databind.ext.javatime : JavaTimeFormat, isJavaTime, readJavaTime;
import flint.jackson.databind.introspect : BeanDescription, BeanPropertyDefinition;
import flint.jackson.databind.node : readTree;
import flint.java.util : RawCollection, RawMap;

@safe:

/// Jackson's display name of a Flint type in messages: `int`, `java.lang.String`, or the type name.
string javaTypeName(string type) pure nothrow
{
    switch (type)
    {
    case "string":
        return "java.lang.String";
    case "bool":
        return "boolean";
    case "byte", "ubyte":
        return "byte";
    case "char", "wchar", "dchar":
        return "char";
    case "uint":
        return "long";
    case "ulong":
        return "java.math.BigInteger";
    default:
        // flint.java.time.LocalDate is java.time.LocalDate.
        return type.length > 11 && type[0 .. 11] == "flint.java." ? type[6 .. $] : type;
    }
}

/// Deserialize the value at the parser's current token into the Flint type `type`. `existing` is the property's
/// current value: a collection or map without a creator in its descriptor is cleared and refilled.
Any deserializeValue(MapperConfig config, JsonParser p, string type, Any existing = Any.init,
        JavaTimeFormat format = JavaTimeFormat.init)
{
    const t = p.currentToken();
    if (auto scalar = readScalar(config, p, type, t))
        return scalar.value;
    if (isJavaTime(type))
        return readJavaTime(config, p, type, format);
    if (isTreeType(type))
        return Any.ofObject(readTree(p, config.nodeFactory), type);
    if (type == "flint.engine.aot.any.Any" || type == "object.Object")
        return readUntyped(config, p, t);
    const d = resolve(config, type);
    if (d is null)
        throw new InvalidDefinitionException("Cannot construct instance of `" ~ type
                ~ "`: no Flint AOT descriptor (register the type, or let Flint AOT generate it)", type);
    if (t == JsonToken.VALUE_NULL)
        return nullValue(d);
    return readStructured(config, p, d, t, existing);
}

private Any readStructured(MapperConfig config, JsonParser p, const Descriptor d, JsonToken t, Any existing)
{
    if (d.kind == TypeKind.enum_)
        throw new InvalidDefinitionException(
                "Cannot deserialize enum `" ~ d.name ~ "` until its descriptor carries enum values", d.name);
    if (d.kind != TypeKind.struct_ && d.kind != TypeKind.class_ && d.kind != TypeKind.interface_)
        throw new InvalidDefinitionException(
                "Cannot deserialize `" ~ d.name ~ "` until its descriptor carries element access", d.name);
    auto container = d.create !is null ? d.create() : existing;
    if (auto o = container.asObject())
    {
        if (auto collection = cast(RawCollection) o)
        {
            collection.clear();
            return readCollection(config, p, collection, d, container);
        }
        if (auto map = cast(RawMap) o)
            return readMap(config, p, map, d, container);
    }
    if (t != JsonToken.START_OBJECT)
        throw mismatch(d.name, t);
    return readBean(config, p, config.bean(d));
}

// The descriptor of `type`, or of the concrete type Jackson's default abstract type mappings choose for it:
// List and Collection to ArrayList, Set to HashSet, Map to LinkedHashMap.
private const(Descriptor) resolve(MapperConfig config, string type)
{
    auto declared = config.descriptor(type);
    if (declared is null || declared.create !is null)
        return declared;
    auto concrete = config.descriptor(concreteType(type));
    return concrete is null ? declared : concrete;
}

/// The concrete `flint.java.util` type Jackson instantiates for an abstract collection type, or `type` itself.
string concreteType(string type) pure nothrow
{
    static immutable string[2][4] mappings = [
        ["flint.java.util.List!", "flint.java.util.ArrayList!"],
        ["flint.java.util.Collection!", "flint.java.util.ArrayList!"],
        ["flint.java.util.Set!", "flint.java.util.HashSet!"],
        ["flint.java.util.Map!", "flint.java.util.LinkedHashMap!"],
    ];
    foreach (ref m; mappings)
        if (type.length > m[0].length && type[0 .. m[0].length] == m[0])
            return m[1] ~ type[m[0].length .. $];
    return type;
}

// UntypedObjectDeserializer. Jackson builds LinkedHashMap and ArrayList values; Flint builds the equivalent tree
// nodes, which serialize identically, until flint.java.util collections can hold Any.
private Any readUntyped(MapperConfig config, JsonParser p, JsonToken t)
{
    switch (t)
    {
    case JsonToken.VALUE_STRING:
        return Any.of(p.getString());
    case JsonToken.VALUE_NUMBER_INT:
        if (p.getNumberType() == JsonParser.NumberType.INT)
            return Any.of(p.getIntValue());
        if (p.getNumberType() == JsonParser.NumberType.LONG)
            return Any.of(p.getLongValue());
        return Any.of(p.getDoubleValue());
    case JsonToken.VALUE_NUMBER_FLOAT:
        return Any.of(p.getDoubleValue());
    case JsonToken.VALUE_TRUE:
        return Any.of(true);
    case JsonToken.VALUE_FALSE:
        return Any.of(false);
    case JsonToken.VALUE_NULL:
        return Any.init;
    default:
        return Any.ofObject(readTree(p, config.nodeFactory), "flint.jackson.databind.node.JsonNode");
    }
}

private bool isTreeType(string type) pure nothrow @nogc
{
    switch (type)
    {
    case "flint.jackson.databind.node.JsonNode", "flint.jackson.databind.node.ObjectNode",
            "flint.jackson.databind.node.ArrayNode":
            return true;
    default:
        return false;
    }
}

private Any nullValue(const Descriptor d)
{
    if (d.kind == TypeKind.struct_ && d.create !is null)
        return d.create();
    return Any.init;
}

/// The value a missing creator parameter or primitive takes: 0, false, null or a default struct.
Any defaultFor(MapperConfig config, string type)
{
    switch (type)
    {
    case "bool":
        return Any.of(false);
    case "byte", "short", "int", "long", "ubyte", "ushort", "uint", "ulong":
        return Any.of(0L);
    case "float", "double", "real":
        return Any.of(0.0);
    case "char", "wchar", "dchar":
        return Any.of(dchar.init);
    default:
        const d = config.descriptor(type);
        return d !is null && d.kind == TypeKind.struct_ && d.create !is null ? d.create() : Any.init;
    }
}

private struct Scalar
{
    Any value;
}

// The JDK scalars of NumberDeserializers, StringDeserializer and BooleanDeserializer; null for other types.
private Scalar* readScalar(MapperConfig config, JsonParser p, string type, JsonToken t)
{
    switch (type)
    {
    case "string":
        return new Scalar(readString(p, t, type));
    case "bool":
        return new Scalar(Any.of(readBoolean(config, p, t)));
    case "byte", "short", "int", "long", "ubyte", "ushort", "uint":
        return new Scalar(readIntegral(config, p, t, type));
    case "float":
        return new Scalar(Any.of(cast(float) readFloating(config, p, t, type)));
    case "double", "real":
        return new Scalar(Any.of(readFloating(config, p, t, type)));
    case "char", "wchar", "dchar":
        auto text = readString(p, t, type);
        const s = text.isNull() ? "" : text.get!string();
        import std.utf : count;

        if (s.count != 1)
            throw new InvalidFormatException("Cannot deserialize value of type `char` from String \"" ~ s
                    ~ "\": expected either Integer value code or 1-character String", s, type, p.currentLocation());
        size_t next;
        import std.utf : decode;

        return new Scalar(Any.of(decode(s, next)));
    default:
        return null;
    }
}

private Any readString(JsonParser p, JsonToken t, string type)
{
    switch (t)
    {
    case JsonToken.VALUE_STRING:
    case JsonToken.VALUE_NUMBER_INT:
    case JsonToken.VALUE_NUMBER_FLOAT:
    case JsonToken.VALUE_TRUE:
    case JsonToken.VALUE_FALSE:
        return Any.of(p.getString());
    case JsonToken.VALUE_NULL:
        return Any.init;
    default:
        throw mismatch(type, t);
    }
}

private bool readBoolean(MapperConfig config, JsonParser p, JsonToken t)
{
    switch (t)
    {
    case JsonToken.VALUE_TRUE:
        return true;
    case JsonToken.VALUE_FALSE:
        return false;
    case JsonToken.VALUE_NUMBER_INT:
        return p.getLongValue() != 0;
    case JsonToken.VALUE_STRING:
        import std.string : strip;

        const text = p.getString().strip();
        if (text == "true" || text == "True" || text == "TRUE")
            return true;
        if (text == "false" || text == "False" || text == "FALSE")
            return false;
        throw new InvalidFormatException("Cannot deserialize value of type `boolean` from String \""
                ~ text ~ "\": only \"true\" or \"false\" recognized", text, "bool", p.currentLocation());
    case JsonToken.VALUE_NULL:
        nullForPrimitive(config, p, "bool");
        return false;
    default:
        throw mismatch("bool", t);
    }
}

private void nullForPrimitive(MapperConfig config, JsonParser p, string type)
{
    if (config.isEnabled(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES))
    {
        enum hint = " (set DeserializationConfig.DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES"
            ~ " to 'false' to allow)";
        throw new MismatchedInputException("Cannot map `null` into type `" ~ javaTypeName(type) ~ "`" ~ hint,
                type, p.currentLocation());
    }
}

private Any readIntegral(MapperConfig config, JsonParser p, JsonToken t, string type)
{
    long value;
    switch (t)
    {
    case JsonToken.VALUE_NUMBER_INT:
        value = type == "int" ? p.getIntValue() : type == "short"
            ? p.getShortValue() : type == "byte" ? p.getByteValue() : p.getLongValue();
        break;
    case JsonToken.VALUE_NUMBER_FLOAT:
        if (!config.isEnabled(DeserializationFeature.ACCEPT_FLOAT_AS_INT))
            throw new InvalidFormatException(
                    "Cannot coerce Floating-point value (" ~ p.getString() ~ ") to `" ~ javaTypeName(
                    type) ~ "` value (but could if coercion was enabled using `CoercionConfig`)",
                    p.getString(), type, p.currentLocation());
        value = type == "int" ? p.getIntValue() : p.getLongValue();
        break;
    case JsonToken.VALUE_STRING:
        value = parseIntegral(p, type);
        break;
    case JsonToken.VALUE_NULL:
        nullForPrimitive(config, p, type);
        break;
    default:
        throw mismatch(type, t);
    }
    return boxIntegral(value, type, p);
}

private long parseIntegral(JsonParser p, string type)
{
    import std.conv : to;
    import std.string : strip;

    const text = p.getString().strip();
    try
        return text.to!long;
    catch (Exception)
        throw new InvalidFormatException("Cannot deserialize value of type `" ~ javaTypeName(
                type) ~ "` from String \"" ~ text ~ "\": not a valid `" ~ javaTypeName(type) ~ "` value",
                text, type, p.currentLocation());
}

// The Java range each integral type accepts; Java's byte accepts -128 to 255, as Jackson's does.
private long[2] integralRange(string type) pure nothrow @nogc
{
    static immutable string[6] names = ["byte", "short", "int", "ubyte", "ushort", "uint"];
    static immutable long[2][6] ranges = [
        [byte.min, 255], [short.min, short.max], [int.min, int.max], [0, ubyte.max], [0, ushort.max],
        [0, uint.max]
    ];
    foreach (i, name; names)
        if (name == type)
            return ranges[i];
    return [long.min, long.max];
}

private Any boxIntegral(long value, string type, JsonParser p)
{
    import std.conv : to;

    const range = integralRange(type);
    if (value < range[0] || value > range[1])
        throw new InvalidFormatException("Numeric value (" ~ value.to!string ~ ") out of range of `" ~ javaTypeName(
                type) ~ "`", value.to!string, type, p.currentLocation());
    switch (type)
    {
    case "byte":
        return Any.of(cast(byte) value);
    case "short":
        return Any.of(cast(short) value);
    case "int":
        return Any.of(cast(int) value);
    case "ubyte":
        return Any.of(cast(ubyte) value);
    case "ushort":
        return Any.of(cast(ushort) value);
    case "uint":
        return Any.of(cast(uint) value);
    default:
        return Any.of(value);
    }
}

private double readFloating(MapperConfig config, JsonParser p, JsonToken t, string type)
{
    switch (t)
    {
    case JsonToken.VALUE_NUMBER_INT:
    case JsonToken.VALUE_NUMBER_FLOAT:
        return p.getDoubleValue();
    case JsonToken.VALUE_STRING:
        import flint.serde.json_read : parseJsonDecimal;
        import std.string : strip;

        const text = p.getString().strip();
        switch (text)
        {
        case "NaN":
            return double.nan;
        case "Infinity", "INF":
            return double.infinity;
        case "-Infinity", "-INF":
            return -double.infinity;
        default:
            double[1] parsed;
            if (text.length && parseJsonDecimal(cast(const(ubyte)[]) text, parsed[0]))
                return parsed[0];
            throw new InvalidFormatException("Cannot deserialize value of type `" ~ javaTypeName(
                    type) ~ "` from String \"" ~ text ~ "\": not a valid `" ~ javaTypeName(type) ~ "` value",
                    text, type, p.currentLocation());
        }
    case JsonToken.VALUE_NULL:
        nullForPrimitive(config, p, type);
        return 0.0;
    default:
        throw mismatch(type, t);
    }
}

/// The exception for a token the target type cannot start with: StdDeserializer's message.
MismatchedInputException mismatch(string type, JsonToken t)
{
    string shape;
    switch (t)
    {
    case JsonToken.START_OBJECT:
    case JsonToken.PROPERTY_NAME:
    case JsonToken.END_OBJECT:
        shape = "Object value";
        break;
    case JsonToken.START_ARRAY:
    case JsonToken.END_ARRAY:
        shape = "Array value";
        break;
    case JsonToken.VALUE_STRING:
        shape = "String value";
        break;
    case JsonToken.VALUE_NUMBER_INT:
        shape = "Integer value";
        break;
    case JsonToken.VALUE_NUMBER_FLOAT:
        shape = "Floating-point value";
        break;
    case JsonToken.VALUE_TRUE:
    case JsonToken.VALUE_FALSE:
        shape = "Boolean value";
        break;
    case JsonToken.VALUE_NULL:
        shape = "Null value";
        break;
    default:
        shape = "No content";
        break;
    }
    return new MismatchedInputException("Cannot deserialize value of type `" ~ javaTypeName(
            type) ~ "` from " ~ shape ~ " (token `JsonToken." ~ tokenName(t) ~ "`)", type);
}

private Any readCollection(MapperConfig config, JsonParser p, RawCollection target, const Descriptor d, Any boxed)
{
    if (p.currentToken() != JsonToken.START_ARRAY)
        throw mismatch(d.name, p.currentToken());
    int index;
    for (auto t = p.nextToken(); t != JsonToken.END_ARRAY; t = p.nextToken())
    {
        Any element;
        withPath(Reference(null, index++, d.simpleName()), () {
            element = deserializeValue(config, p, d.elementType);
        });
        target.addAny(element);
    }
    return boxed;
}

private Any readMap(MapperConfig config, JsonParser p, RawMap target, const Descriptor d, Any boxed)
{
    if (p.currentToken() != JsonToken.START_OBJECT)
        throw mismatch(d.name, p.currentToken());
    for (auto t = p.nextToken(); t == JsonToken.PROPERTY_NAME; t = p.nextToken())
    {
        const name = p.currentName();
        p.nextToken();
        Any value;
        withPath(Reference(name, -1, d.simpleName()), () {
            value = deserializeValue(config, p, d.elementType);
        });
        target.putAny(Any.of(name), value);
    }
    return boxed;
}

// BeanDeserializer: a properties-based creator buffers its arguments; otherwise the default instance is
// created first and properties are set as they arrive.
private Any readBean(MapperConfig config, JsonParser p, BeanDescription bean)
{
    if (bean.creator !is null)
        return readWithCreator(config, p, bean);
    const d = bean.descriptor;
    if (d.create is null)
    {
        enum detail = " (no Creators, like default constructor, exist): cannot deserialize from Object value"
            ~ " (no delegate- or property-based Creator)";
        throw new InvalidDefinitionException("Cannot construct instance of `" ~ d.name ~ "`" ~ detail, d.name);
    }
    auto instance = d.create();
    for (auto t = p.nextToken(); t == JsonToken.PROPERTY_NAME; t = p.nextToken())
    {
        const name = p.currentName();
        p.nextToken();
        auto property = bean.findForInput(name);
        if (property is null || !property.isWritable())
        {
            unknown(config, p, bean, name, property !is null);
            continue;
        }
        Any current;
        if (property.accessor !is null && property.accessor.get !is null)
            current = property.accessor.get(instance);
        auto value = readProperty(config, p, bean, property, current);
        property.accessor.set(instance, value);
    }
    return instance;
}

private Any readProperty(MapperConfig config, JsonParser p, BeanDescription bean,
        BeanPropertyDefinition property, Any current)
{
    Any value;
    withPath(Reference(property.name, -1, bean.descriptor.simpleName()), () {
        value = deserializeValue(config, p, property.type, current, property.hasFormat
            ? JavaTimeFormat.of(property.format) : JavaTimeFormat.init);
    });
    return value;
}

// PropertyBasedCreator: buffer creator arguments, construct at the end, then set the other properties.
private Any readWithCreator(MapperConfig config, JsonParser p, BeanDescription bean)
{
    struct Pending
    {
        BeanPropertyDefinition property;
        Any value;
    }

    auto arguments = new Any[bean.creator.parameters.length];
    auto seen = new bool[arguments.length];
    Pending[] pending;
    for (auto t = p.nextToken(); t == JsonToken.PROPERTY_NAME; t = p.nextToken())
    {
        const name = p.currentName();
        p.nextToken();
        auto property = bean.findForInput(name);
        if (property is null || !property.isWritable())
        {
            unknown(config, p, bean, name, property !is null);
            continue;
        }
        auto value = readProperty(config, p, bean, property, Any.init);
        if (property.creatorIndex >= 0)
        {
            arguments[property.creatorIndex] = value;
            seen[property.creatorIndex] = true;
        }
        else
            pending ~= Pending(property, value);
    }
    foreach (i, parameter; bean.creator.parameters)
        if (!seen[i])
            arguments[i] = defaultFor(config, parameter.type);
    auto instance = construct(bean, arguments);
    foreach (ref item; pending)
        item.property.accessor.set(instance, item.value);
    return instance;
}

private Any construct(BeanDescription bean, Any[] arguments)
{
    const d = bean.descriptor;
    try
        return bean.creator.invoke(arguments);
    catch (DatabindException e)
        throw e;
    catch (Exception e)
        throw new ValueInstantiationException(
                "Cannot construct instance of `" ~ d.name ~ "`, problem: " ~ e.msg, d.name, e);
}

private void unknown(MapperConfig config, JsonParser p, BeanDescription bean, string name, bool readOnly)
{
    if (readOnly || name in bean.ignoredNames || bean.ignoreUnknown
            || !config.isEnabled(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES))
    {
        p.skipChildren();
        return;
    }
    string[] known;
    foreach (property; bean.properties)
        known ~= property.name;
    string list;
    foreach (i, k; known)
        list ~= (i ? ", " : "") ~ "\"" ~ k ~ "\"";
    import std.conv : to;

    throw new UnrecognizedPropertyException("Unrecognized property \"" ~ name ~ "\" (class " ~ bean.descriptor.name
            ~ "), not marked as ignorable (" ~ known.length.to!string ~ " known properties: " ~ list ~ "])",
            name, bean.descriptor.name, known, p.currentLocation());
}

/// Fail when content follows the root value (`DeserializationFeature.FAIL_ON_TRAILING_TOKENS`).
void verifyNoTrailingTokens(MapperConfig config, JsonParser p, string type)
{
    if (!config.isEnabled(DeserializationFeature.FAIL_ON_TRAILING_TOKENS))
        return;
    const t = p.nextToken();
    if (t != JsonToken.NOT_AVAILABLE)
        throw new MismatchedInputException(
                "Trailing token (of type " ~ tokenName(t) ~ ") found after value (bound as `" ~ javaTypeName(
                type) ~ "`): not allowed as per `DeserializationFeature.FAIL_ON_TRAILING_TOKENS`",
                type, p.currentLocation());
}

private void withPath(Reference reference, scope void delegate() @safe action)
{
    try
        action();
    catch (DatabindException e)
        throw e.prependPath(reference);
}
