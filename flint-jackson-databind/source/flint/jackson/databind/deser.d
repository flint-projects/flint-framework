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
import flint.jackson.databind.stddateformat : dateKey, isJavaUtilDate, readJavaUtilDate;
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
    case "flint.java.util.date.Date":
        return "java.util.Date";
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
    if (isJavaUtilDate(type))
        return readJavaUtilDate(config, p, type, format);
    if (isBinary(type, t))
        return readBytes(p, type, t);
    if (isTreeType(type))
        return Any.ofObject(readTree(p, config.nodeFactory), type);
    if (type == "flint.engine.aot.any.Any" || type == "object.Object")
        return readUntyped(config, p, t);
    const d = resolve(config, type);
    if (d is null)
        throw new InvalidDefinitionException("Cannot construct instance of `" ~ type
                ~ "`: no Flint AOT descriptor (register the type, or let Flint AOT generate it)", type);
    if (t == JsonToken.VALUE_NULL || emptyAsNull(config, p, t))
        return nullValue(d);
    return readStructured(config, p, d, t, existing);
}

// A byte[] written as Base64 text or as an array of numbers.
private bool isBinary(string type, JsonToken t) pure nothrow @nogc
{
    return (type == "byte[]" || type == "ubyte[]") && (t == JsonToken.VALUE_STRING || t == JsonToken.START_ARRAY);
}

// CoercionConfigs: under ACCEPT_EMPTY_STRING_AS_NULL_OBJECT an empty String is AsNull for structured types.
private bool emptyAsNull(MapperConfig config, JsonParser p, JsonToken t)
{
    return t == JsonToken.VALUE_STRING && p.getString().length == 0
        && config.isEnabled(DeserializationFeature.ACCEPT_EMPTY_STRING_AS_NULL_OBJECT);
}

private Any readStructured(MapperConfig config, JsonParser p, const Descriptor d, JsonToken t, Any existing)
{
    auto shaped = readShaped(config, p, d, t, existing);
    if (shaped.done)
        return shaped.value;
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

private struct Shaped
{
    bool done;
    Any value;
}

// Enums, Optional, associative arrays, arrays and element-built collections, through their descriptor thunks.
private Shaped readShaped(MapperConfig config, JsonParser p, const Descriptor d, JsonToken t, Any existing)
{
    if (d.kind == TypeKind.enum_)
        return Shaped(true, readEnum(p, d, t));
    if (d.wrap !is null)
    {
        // A wrapper of a JDK scalar (Integer, Boolean, Character...) reads "", a blank String or "null" as null.
        if (t == JsonToken.VALUE_STRING && isPrimitive(d.elementType)
                && emptyScalarText(d.elementType, p.getString()) != EmptyText.none)
            return Shaped(true, d.wrap(Any.init));
        return Shaped(true, d.wrap(deserializeValue(config, p, d.elementType)));
    }
    if (d.fromEntries !is null && d.create is null)
        return Shaped(true, readEntries(config, p, d, t));
    if (d.fromElements !is null && (d.kind == TypeKind.array || (d.create is null && existing.isNull())))
        return Shaped(true, readElements(config, p, d, t));
    return Shaped.init;
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
    if (d.wrap !is null)
        return d.wrap(Any.init); // Optional.empty()
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
        // A wrapper (Nullable!T for Java's Integer, Optional!T) takes its null or empty value.
        const d = config.descriptor(type);
        return d is null ? Any.init : nullValue(d);
    }
}

private struct Scalar
{
    Any value;
}

// The JDK scalars of NumberDeserializers, StringDeserializer and BooleanDeserializer; null for other types.
private Scalar* readScalar(MapperConfig config, JsonParser p, string type, JsonToken t)
{
    if (auto empty = readEmptyScalar(config, p, type, t))
        return empty;
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
        import flint.engine.aot.text : codePointCount, decodeUtf8;

        const s = text.isNull() ? "" : text.get!string();
        if (codePointCount(s) != 1)
            throw new InvalidFormatException("Cannot deserialize value of type `char` from String \"" ~ s
                    ~ "\": expected either Integer value code or 1-character String", s, type, p.currentLocation());
        size_t next;
        return new Scalar(Any.of(decodeUtf8(s, next)));
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
        import flint.engine.aot.text : stripWhite;

        const text = stripWhite(p.getString());
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

// NumberDeserializers.getNullValue for a primitive.
private MismatchedInputException nullPrimitive(string type, JsonParser p)
{
    enum hint = " (set `DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES` to 'false' to allow)";
    return new MismatchedInputException("Cannot map `null` into type `" ~ javaTypeName(type) ~ "`" ~ hint,
            type, p.currentLocation());
}

// An empty, blank or textual-null String for a primitive, or null.
private Scalar* readEmptyScalar(MapperConfig config, JsonParser p, string type, JsonToken t)
{
    if (t != JsonToken.VALUE_STRING || !isPrimitive(type))
        return null;
    const empty = emptyScalarText(type, p.getString());
    return empty == EmptyText.none ? null : new Scalar(emptyForPrimitive(config, p, type, empty));
}

// How a String reads for a JDK scalar under Jackson's default coercion: "" (and, except for char, a String of
// characters up to U+0020) as an empty value, "null" as a textual null; both become null for a wrapper.
private enum EmptyText
{
    none,
    empty,
    textualNull,
}

private EmptyText emptyScalarText(string type, scope const(char)[] text) pure nothrow @nogc
{
    const isChar = type == "char" || type == "wchar" || type == "dchar";
    if (text == "null" && !isChar)
        return EmptyText.textualNull;
    if (isChar && text.length)
        return EmptyText.none;
    foreach (c; text)
        if (c > ' ')
            return EmptyText.none;
    return EmptyText.empty;
}

// StdDeserializer._coerceEmptyString / _checkTextualNull for a primitive: its default (0, false, '\0') unless
// FAIL_ON_NULL_FOR_PRIMITIVES, which Jackson 3 enables by default.
private Any emptyForPrimitive(MapperConfig config, JsonParser p, string type, EmptyText empty)
{
    if (config.isEnabled(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES))
    {
        enum hint = " value (disable `DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES` to allow)";
        if (type == "char" || type == "wchar" || type == "dchar")
            throw nullPrimitive(type, p);
        const what = empty == EmptyText.textualNull ? "String \"null\" to Null value as" : "`null` to";
        throw new MismatchedInputException("Cannot coerce " ~ what ~ " `" ~ javaTypeName(type) ~ "`" ~ hint,
                type, p.currentLocation());
    }
    switch (type)
    {
    case "bool":
        return Any.of(false);
    case "float":
        return Any.of(0.0f);
    case "double", "real":
        return Any.of(0.0);
    case "char", "wchar", "dchar":
        return Any.of(cast(dchar) 0);
    default:
        return boxIntegral(0, type, p);
    }
}

private bool isPrimitive(string type) pure nothrow @nogc
{
    switch (type)
    {
    case "bool", "byte", "short", "int", "long", "ubyte", "ushort", "uint", "ulong", "float",
            "double", "real", "char", "wchar", "dchar":
            return true;
    default:
        return false;
    }
}

private void nullForPrimitive(MapperConfig config, JsonParser p, string type)
{
    if (config.isEnabled(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES))
    {
        throw nullPrimitive(type, p);
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
    import flint.engine.aot.text : stripWhite, tryParseLong;

    const text = stripWhite(p.getString());
    const parsed = tryParseLong(text);
    if (parsed.ok)
        return parsed.value;
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
    import flint.engine.aot.text : decimal;

    const range = integralRange(type);
    if (value < range[0] || value > range[1])
        throw new InvalidFormatException("Numeric value (" ~ decimal(
                value) ~ ") out of range of `" ~ javaTypeName(type) ~ "`", decimal(value), type, p.currentLocation());
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
        import flint.jackson.core.io : NumberInput;
        import flint.engine.aot.text : stripWhite;

        const text = stripWhite(p.getString());
        switch (text)
        {
        case "NaN":
            return double.nan;
        case "Infinity", "INF":
            return double.infinity;
        case "-Infinity", "-INF":
            return -double.infinity;
        default:
            double parsed;
            if (NumberInput.parseDouble(text, parsed))
                return parsed;
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
    {
        target.addAny(singleElement(config, p, d, p.currentToken()));
        return boxed;
    }
    int index;
    for (auto t = p.nextToken(); t != JsonToken.END_ARRAY; t = p.nextToken())
    {
        Any element;
        withPath(Reference(null, index++, null, d.name), () {
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
        withPath(Reference(name, -1, null, d.name), () {
            value = deserializeValue(config, p, d.elementType);
        });
        // MapDeserializer: the key deserializer of the key type converts each property name.
        target.putAny(d.keyType.length ? keyFrom(config, name, d.keyType, p) : Any.of(name), value);
    }
    return boxed;
}

// PrimitiveArrayDeserializers.ByteDeser: Base64 text, or numbers from -128 to 255 (wrapping to a byte).
private Any readBytes(JsonParser p, string type, JsonToken t)
{
    import flint.jackson.databind.base64 : decodeBase64;

    ubyte[] bytes;
    if (t == JsonToken.VALUE_STRING)
    {
        const text = p.getString();
        string error;
        bytes = decodeBase64(text, error);
        if (error !is null)
            throw new InvalidFormatException("Cannot deserialize value of type `byte[]` from String \"" ~ text
                    ~ "\": Failed to decode VALUE_STRING as base64 (MIME-NO-LINEFEEDS): " ~ error,
                    text, type, p.currentLocation());
    }
    else
    {
        for (auto e = p.nextToken(); e != JsonToken.END_ARRAY; e = p.nextToken())
        {
            const value = e == JsonToken.VALUE_NUMBER_INT ? p.getLongValue() : long.max;
            enum overflow = ": overflow, value cannot be represented as 8-bit value";
            if (value < -128 || value > 255)
                throw new InvalidFormatException("Cannot deserialize value of type `byte` from " ~ (value == long.max
                        ? "non-integer token" : "Integer value") ~ overflow, p.getString(),
                        "byte", p.currentLocation());
            bytes ~= cast(ubyte) value;
        }
    }
    return type == "byte[]" ? Any.of(cast(byte[]) bytes) : Any.of(bytes);
}

// ObjectArrayDeserializer and the primitive array deserializers, and collections built from their elements.
private Any readElements(MapperConfig config, JsonParser p, const Descriptor d, JsonToken t)
{
    if (t != JsonToken.START_ARRAY)
        return d.fromElements([singleElement(config, p, d, t)]);
    Any[] elements;
    int index;
    for (auto e = p.nextToken(); e != JsonToken.END_ARRAY; e = p.nextToken())
        withPath(Reference(null, index++, null, d.name), () {
            elements ~= deserializeValue(config, p, d.elementType);
        });
    return d.fromElements(elements);
}

// CollectionDeserializer.handleNonArray: under ACCEPT_SINGLE_VALUE_AS_ARRAY a value that is not an array is the
// container's one element; otherwise the token is unexpected.
private Any singleElement(MapperConfig config, JsonParser p, const Descriptor d, JsonToken t)
{
    if (!config.isEnabled(DeserializationFeature.ACCEPT_SINGLE_VALUE_AS_ARRAY))
        throw mismatch(d.name, t);
    Any element;
    withPath(Reference(null, 0, null, d.name), () {
        element = t == JsonToken.VALUE_NULL ? Any.init : deserializeValue(config, p, d.elementType);
    });
    return element;
}

// MapDeserializer into an associative array: keys convert from property names (StdKeyDeserializer).
private Any readEntries(MapperConfig config, JsonParser p, const Descriptor d, JsonToken t)
{
    if (t != JsonToken.START_OBJECT)
        throw mismatch(d.name, t);
    Any[] keys, values;
    for (auto e = p.nextToken(); e == JsonToken.PROPERTY_NAME; e = p.nextToken())
    {
        const name = p.currentName();
        p.nextToken();
        keys ~= keyFrom(config, name, d.keyType, p);
        withPath(Reference(name, -1, null, d.name), () {
            values ~= deserializeValue(config, p, d.elementType);
        });
    }
    return d.fromEntries(keys, values);
}

private Any keyFrom(MapperConfig config, string name, string keyType, JsonParser p)
{
    if (keyType == "string")
        return Any.of(name);
    bool scalar, valid;
    auto key = scalarKey(name, keyType, scalar, valid);
    if (scalar && !valid)
        throw new InvalidFormatException("Cannot deserialize Map key of type `" ~ javaTypeName(
                keyType) ~ "` from String \"" ~ name ~ "\": not a valid representation", name,
                keyType, p.currentLocation());
    if (scalar)
        return key;
    if (isJavaUtilDate(keyType))
        return dateKey(config, name, p);
    const d = config.descriptor(keyType);
    if (d !is null && d.kind == TypeKind.enum_)
        foreach (i, constant; d.enumConstants)
            if (constant == name)
                return enumConstant(d, i);
    throw new InvalidDefinitionException(
            "Cannot find a (Map) Key deserializer for type `" ~ javaTypeName(keyType) ~ "`", keyType);
}

private Any enumConstant(const Descriptor d, size_t index)
{
    if (d.enumValue !is null)
        return d.enumValue(cast(long) index);
    return Any.ofEnum(d.name, index < d.enumValues.length ? d.enumValues[index] : cast(long) index);
}

// EnumDeserializer: by name (READ_ENUMS_USING_TO_STRING reads Java's toString, the name), by index, or by a
// stringified index; Jackson's messages list the names in CompactStringObjectMap order.
private Any readEnum(JsonParser p, const Descriptor d, JsonToken t)
{
    import flint.engine.aot.text : decimal;

    if (t == JsonToken.VALUE_NUMBER_INT)
    {
        const index = p.getLongValue();
        if (index >= 0 && index < d.enumConstants.length)
            return enumConstant(d, cast(size_t) index);
        throw new InvalidFormatException(
                "Cannot deserialize value of type `" ~ javaTypeName(d.name) ~ "` from number " ~ decimal(
                index) ~ ": index value outside legal index range [0.." ~ decimal(
                cast(long) d.enumConstants.length - 1) ~ "]", decimal(index), d.name, p.currentLocation());
    }
    if (t != JsonToken.VALUE_STRING)
        throw mismatch(d.name, t);
    return enumFromString(p, d, p.getString());
}

private Any enumFromString(JsonParser p, const Descriptor d, string text)
{
    import flint.engine.aot.text : stripWhite;

    const name = stripWhite(text);
    foreach (i, constant; d.enumConstants)
        if (constant == text || constant == name)
            return enumConstant(d, i);
    if (name.length == 0)
        throw new InvalidFormatException("Cannot coerce " ~ (text.length
                ? "blank String (all whitespace)" : `empty String ("")`) ~ " to `" ~ javaTypeName(
                d.name) ~ "` value (but could if coercion was enabled using `CoercionConfig`)",
                text, d.name, p.currentLocation());
    const index = stringifiedIndex(name);
    if (index >= 0 && index < d.enumConstants.length)
        return enumConstant(d, cast(size_t) index);
    const accepted = "not one of the values accepted for Enum class: [" ~ compactKeyOrder(d.enumConstants) ~ "]";
    throw new InvalidFormatException("Cannot deserialize value of type `" ~ javaTypeName(
            d.name) ~ "` from String \"" ~ name ~ "\": " ~ accepted, name, d.name, p.currentLocation());
}

// A quoted enum index such as "1" (not "01"); -1 when the text is not one.
private long stringifiedIndex(string name) pure nothrow @nogc
{
    if (name[0] < '0' || name[0] > '9' || (name[0] == '0' && name.length > 1) || name.length > 9)
        return -1;
    long index;
    foreach (c; name)
    {
        if (c < '0' || c > '9')
            return -1;
        index = index * 10 + (c - '0');
    }
    return index;
}

/// The keys of a CompactStringObjectMap built from `keys`, in its hash-area order, joined with ", ".
string compactKeyOrder(scope const(string)[] keys) pure nothrow
{
    import flint.java.lang : stringHashCode;

    size_t size = keys.length <= 5 ? 8 : keys.length <= 12 ? 16 : 32;
    while (keys.length > 12 && size < keys.length + (keys.length >> 2))
        size += size;
    const mask = cast(int)(size - 1);
    auto area = new string[size + (size >> 1)];
    string[] spill;
    foreach (key; keys)
    {
        const slot = cast(size_t)(stringHashCode(key) & mask);
        if (area[slot] is null)
            area[slot] = key;
        else if (area[size + (slot >> 1)] is null)
            area[size + (slot >> 1)] = key;
        else
            spill ~= key;
    }
    string text;
    foreach (key; area ~ spill)
        if (key !is null)
            text ~= (text.length ? ", " : "") ~ key;
    return text;
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
    withPath(Reference(property.name, -1, null, bean.descriptor.name), () {
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
    {
        if (seen[i])
            continue;
        // PropertyValueBuffer: a missing primitive takes its deserializer's null value, which may fail.
        if (isPrimitive(parameter.type) && config.isEnabled(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES))
            throw nullPrimitive(parameter.type, p);
        arguments[i] = defaultFor(config, parameter.type);
    }
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
    import flint.engine.aot.text : decimal;

    throw new UnrecognizedPropertyException("Unrecognized property \"" ~ name ~ "\" (class " ~ bean.descriptor.name
            ~ "), not marked as ignorable (" ~ decimal(cast(ulong) known.length) ~ " known properties: " ~ list ~ "])",
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

// ASCII case-insensitive equality with a lower-case `expected`.
private bool asciiLowerEquals(scope const(char)[] text, string expected) pure nothrow @nogc
{
    if (text.length != expected.length)
        return false;
    foreach (i, c; text)
        if ((c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c) != expected[i])
            return false;
    return true;
}

// An int, long or bool Map key read as to!int, to!long and to!bool read it; `scalar` is false for other key types.
private Any scalarKey(string name, string keyType, out bool scalar, out bool valid)
{
    import flint.engine.aot.text : tryParseInt, tryParseLong;

    scalar = keyType == "int" || keyType == "long" || keyType == "bool";
    if (keyType == "int")
    {
        const parsed = tryParseInt(name);
        valid = parsed.ok;
        return valid ? Any.of(cast(int) parsed.value) : Any.init;
    }
    if (keyType == "long")
    {
        const parsed = tryParseLong(name);
        valid = parsed.ok;
        return valid ? Any.of(parsed.value) : Any.init;
    }
    // to!bool: "true" or "false" in any case.
    valid = asciiLowerEquals(name, "true") || asciiLowerEquals(name, "false");
    return valid ? Any.of(asciiLowerEquals(name, "true")) : Any.init;
}
