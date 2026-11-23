/*
 * Ported from Jackson (jackson-databind) 3.1.8, https://github.com/FasterXML/jackson-databind,
 * tag jackson-databind-3.1.8: src/main/java/tools/jackson/databind/cfg/{DateTimeFeature,
 * EnumFeature,ConstructorDetector,MapperConfig}.java and
 * src/main/java/tools/jackson/databind/{SerializationFeature,DeserializationFeature,MapperFeature}.java
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D (rulebook v2). The three mapper
 * feature enums are declared here and re-exported by flint.jackson.databind, so
 * the serializers can read them without importing the mapper.
 */

/// Datatype features and creator detection of the mapper configuration.
module flint.jackson.databind.cfg;

@safe:

/// Configurable on/off features for date/time handling.
enum DateTimeFeature
{
    /// Whether dates are adjusted to the context time zone on read. Default: true.
    ADJUST_DATES_TO_CONTEXT_TIME_ZONE,
    /// Whether stringified timestamps are accepted. Default: false.
    ALWAYS_ALLOW_STRINGIFIED_DATE_TIMESTAMPS,
    /// Whether zone ids are normalized on read. Default: true.
    NORMALIZE_DESERIALIZED_ZONE_ID,
    /// Whether months are one-based in numeric forms. Default: true.
    ONE_BASED_MONTHS,
    /// Whether numeric timestamps are read as nanoseconds. Default: true.
    READ_DATE_TIMESTAMPS_AS_NANOSECONDS,
    /// Whether values are truncated to milliseconds on read. Default: false.
    TRUNCATE_TO_MSECS_ON_READ,
    /// Whether values are truncated to milliseconds on write. Default: false.
    TRUNCATE_TO_MSECS_ON_WRITE,
    /// Whether lenient date parsing uses the time zone. Default: false.
    USE_TIME_ZONE_FOR_LENIENT_DATE_PARSING,
    /// Whether dates are written as numeric timestamps. Default: false (ISO-8601 strings).
    WRITE_DATES_AS_TIMESTAMPS,
    /// Whether date map keys are written as timestamps. Default: false.
    WRITE_DATE_KEYS_AS_TIMESTAMPS,
    /// Whether numeric timestamps include nanoseconds. Default: true.
    WRITE_DATE_TIMESTAMPS_AS_NANOSECONDS,
    /// Whether dates are written in the context time zone. Default: true.
    WRITE_DATES_WITH_CONTEXT_TIME_ZONE,
    /// Whether zoned values include the zone id. Default: false.
    WRITE_DATES_WITH_ZONE_ID,
    /// Whether durations are written as numeric timestamps. Default: false (ISO-8601 `PT..`).
    WRITE_DURATIONS_AS_TIMESTAMPS,
    /// Whether UTC is written as "+00:00" instead of "Z". Default: false.
    WRITE_UTC_AS_OFFSET,
}

/// Whether the date/time feature is enabled by default (Jackson 3.1.8).
bool enabledByDefault(DateTimeFeature f) pure nothrow @nogc
{
    switch (f)
    {
    case DateTimeFeature.ADJUST_DATES_TO_CONTEXT_TIME_ZONE:
    case DateTimeFeature.NORMALIZE_DESERIALIZED_ZONE_ID:
    case DateTimeFeature.ONE_BASED_MONTHS:
    case DateTimeFeature.READ_DATE_TIMESTAMPS_AS_NANOSECONDS:
    case DateTimeFeature.WRITE_DATE_TIMESTAMPS_AS_NANOSECONDS:
    case DateTimeFeature.WRITE_DATES_WITH_CONTEXT_TIME_ZONE:
        return true;
    default:
        return false;
    }
}

/// New Datatype-specific configuration options related to handling of `Enum` types.
enum EnumFeature
{
    /// Whether enum map keys are read by index. Default: false.
    READ_ENUM_KEYS_USING_INDEX,
    /// Whether numbers are refused for enums. Default: false.
    FAIL_ON_NUMBERS_FOR_ENUMS,
    /// Whether enums are read by their `toString()`. Default: true.
    READ_ENUMS_USING_TO_STRING,
    /// Whether unknown enum values read as null. Default: false.
    READ_UNKNOWN_ENUM_VALUES_AS_NULL,
    /// Whether unknown enum values read as the `@JsonEnumDefaultValue`. Default: false.
    READ_UNKNOWN_ENUM_VALUES_USING_DEFAULT_VALUE,
    /// Whether enums are written in lower case. Default: false.
    WRITE_ENUMS_TO_LOWERCASE,
    /// Whether enums are written with their `toString()`. Default: true.
    WRITE_ENUMS_USING_TO_STRING,
    /// Whether enums are written as their index. Default: false.
    WRITE_ENUMS_USING_INDEX,
    /// Whether enum map keys are written as their index. Default: false.
    WRITE_ENUM_KEYS_USING_INDEX,
}

/// Whether the enum feature is enabled by default (Jackson 3.1.8).
bool enabledByDefault(EnumFeature f) pure nothrow @nogc
{
    return f == EnumFeature.READ_ENUMS_USING_TO_STRING || f == EnumFeature.WRITE_ENUMS_USING_TO_STRING;
}

/**
 * Configurable on/off features to configure how creators are detected. Jackson
 * 3's `ConstructorDetector.DEFAULT` lets one public non-default constructor
 * whose parameters are all named be the properties-based creator, even next to
 * a default constructor; `requireCtorAnnotation` turns that off.
 */
struct ConstructorDetector
{
    /// Whether an explicit `@JsonCreator` is required for constructors other than the default one.
    bool requireCtorAnnotation;
    /// Whether an implicit properties-based creator may be found when a default constructor exists.
    bool allowImplicitWithDefaultConstructor = true;

    /// The default detection.
    enum ConstructorDetector DEFAULT = ConstructorDetector.init;
    /// Detection that requires `@JsonCreator` on every non-default creator.
    enum ConstructorDetector EXPLICIT_ONLY = ConstructorDetector(true, true);
}

/// Enumeration that defines simple on/off features that affect the way Java objects are serialized.
enum SerializationFeature
{
    /// Default: false.
    WRAP_ROOT_VALUE,
    /// Default: false.
    INDENT_OUTPUT,
    /// Default: false.
    FAIL_ON_EMPTY_BEANS,
    /// Default: true.
    FAIL_ON_SELF_REFERENCES,
    /// Default: true.
    WRAP_EXCEPTIONS,
    /// Default: true.
    FAIL_ON_UNWRAPPED_TYPE_IDENTIFIERS,
    /// Default: false.
    WRITE_SELF_REFERENCES_AS_NULL,
    /// Default: false.
    CLOSE_CLOSEABLE,
    /// Default: true.
    FLUSH_AFTER_WRITE_VALUE,
    /// Default: false.
    WRITE_CHAR_ARRAYS_AS_JSON_ARRAYS,
    /// Default: true.
    WRITE_EMPTY_JSON_ARRAYS,
    /// Default: false.
    WRITE_SINGLE_ELEM_ARRAYS_UNWRAPPED,
    /// Default: false.
    ORDER_MAP_ENTRIES_BY_KEYS,
    /// Default: false.
    FAIL_ON_ORDER_MAP_BY_INCOMPARABLE_KEY,
    /// Default: false.
    APPLY_JSON_INCLUDE_FOR_CONTAINERS,
    /// Default: true.
    EAGER_SERIALIZER_FETCH,
    /// Default: false.
    USE_EQUALITY_FOR_OBJECT_ID,
}

/// Whether the feature is enabled by default (Jackson 3.1.8).
bool enabledByDefault(SerializationFeature f) pure nothrow @nogc
{
    switch (f)
    {
    case SerializationFeature.FAIL_ON_SELF_REFERENCES:
    case SerializationFeature.WRAP_EXCEPTIONS:
    case SerializationFeature.FAIL_ON_UNWRAPPED_TYPE_IDENTIFIERS:
    case SerializationFeature.FLUSH_AFTER_WRITE_VALUE:
    case SerializationFeature.WRITE_EMPTY_JSON_ARRAYS:
    case SerializationFeature.EAGER_SERIALIZER_FETCH:
        return true;
    default:
        return false;
    }
}

/// Enumeration that defines simple on/off features that affect the way Java objects are deserialized from JSON.
enum DeserializationFeature
{
    /// Default: false.
    USE_BIG_DECIMAL_FOR_FLOATS,
    /// Default: false.
    USE_BIG_INTEGER_FOR_INTS,
    /// Default: false.
    USE_LONG_FOR_INTS,
    /// Default: false.
    USE_JAVA_ARRAY_FOR_JSON_ARRAY,
    /// Default: false.
    USE_NULL_FOR_MISSING_REFERENCE_VALUES,
    /// Default: false.
    USE_NULL_FOR_EMPTY_UNWRAPPED,
    /// Default: false.
    FAIL_ON_UNKNOWN_PROPERTIES,
    /// Default: true.
    FAIL_ON_NULL_FOR_PRIMITIVES,
    /// Default: true.
    FAIL_ON_INVALID_SUBTYPE,
    /// Default: true.
    IGNORE_ABSTRACT_TYPES_FOR_DEDUCTION,
    /// Default: false.
    FAIL_ON_READING_DUP_TREE_KEY,
    /// Default: false.
    FAIL_ON_IGNORED_PROPERTIES,
    /// Default: true.
    FAIL_ON_UNRESOLVED_OBJECT_IDS,
    /// Default: false.
    FAIL_ON_MISSING_CREATOR_PROPERTIES,
    /// Default: false.
    FAIL_ON_NULL_CREATOR_PROPERTIES,
    /// Default: true.
    FAIL_ON_MISSING_EXTERNAL_TYPE_ID_PROPERTY,
    /// Default: true.
    FAIL_ON_TRAILING_TOKENS,
    /// Default: false.
    FAIL_ON_SUBTYPE_CLASS_NOT_REGISTERED,
    /// Default: true.
    WRAP_EXCEPTIONS,
    /// Default: false.
    FAIL_ON_UNEXPECTED_VIEW_PROPERTIES,
    /// Default: true.
    FAIL_ON_UNKNOWN_INJECT_VALUE,
    /// Default: false.
    ACCEPT_SINGLE_VALUE_AS_ARRAY,
    /// Default: false.
    UNWRAP_SINGLE_VALUE_ARRAYS,
    /// Default: false.
    UNWRAP_ROOT_VALUE,
    /// Default: false.
    ACCEPT_EMPTY_STRING_AS_NULL_OBJECT,
    /// Default: false.
    ACCEPT_EMPTY_ARRAY_AS_NULL_OBJECT,
    /// Default: true.
    ACCEPT_FLOAT_AS_INT,
    /// Default: true.
    EAGER_DESERIALIZER_FETCH,
}

/// Whether the feature is enabled by default (Jackson 3.1.8).
bool enabledByDefault(DeserializationFeature f) pure nothrow @nogc
{
    switch (f)
    {
    case DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES:
    case DeserializationFeature.FAIL_ON_INVALID_SUBTYPE:
    case DeserializationFeature.IGNORE_ABSTRACT_TYPES_FOR_DEDUCTION:
    case DeserializationFeature.FAIL_ON_UNRESOLVED_OBJECT_IDS:
    case DeserializationFeature.FAIL_ON_MISSING_EXTERNAL_TYPE_ID_PROPERTY:
    case DeserializationFeature.FAIL_ON_TRAILING_TOKENS:
    case DeserializationFeature.WRAP_EXCEPTIONS:
    case DeserializationFeature.FAIL_ON_UNKNOWN_INJECT_VALUE:
    case DeserializationFeature.ACCEPT_FLOAT_AS_INT:
    case DeserializationFeature.EAGER_DESERIALIZER_FETCH:
        return true;
    default:
        return false;
    }
}

/// Enumeration that defines simple on/off features to set for `ObjectMapper`, and accessible (but not changeable) via `ObjectReader` and `ObjectWriter` (as well as through various convenience methods through context objects).
enum MapperFeature
{
    /// Default: true.
    USE_ANNOTATIONS,
    /// Default: false.
    USE_GETTERS_AS_SETTERS,
    /// Default: false.
    PROPAGATE_TRANSIENT_MARKER,
    /// Default: false.
    REQUIRE_SETTERS_FOR_GETTERS,
    /// Default: false.
    ALLOW_FINAL_FIELDS_AS_MUTATORS,
    /// Default: true.
    INFER_PROPERTY_MUTATORS,
    /// Default: true.
    INFER_CREATOR_FROM_CONSTRUCTOR_PROPERTIES,
    /// Default: false.
    ALLOW_IS_GETTERS_FOR_NON_BOOLEAN,
    /// Default: false.
    INFER_RECORD_GETTERS_FROM_COMPONENTS_ONLY,
    /// Default: true.
    ALLOW_VOID_VALUED_PROPERTIES,
    /// Default: true.
    DETECT_PARAMETER_NAMES,
    /// Default: true.
    CAN_OVERRIDE_ACCESS_MODIFIERS,
    /// Default: true.
    OVERRIDE_PUBLIC_ACCESS_MODIFIERS,
    /// Default: false.
    INVERSE_READ_WRITE_ACCESS,
    /// Default: false.
    USE_STATIC_TYPING,
    /// Default: false.
    USE_BASE_TYPE_AS_DEFAULT_IMPL,
    /// Default: true.
    INFER_BUILDER_TYPE_BINDINGS,
    /// Default: true.
    REQUIRE_TYPE_ID_FOR_SUBTYPES,
    /// Default: false.
    DEFAULT_VIEW_INCLUSION,
    /// Default: true.
    SORT_PROPERTIES_ALPHABETICALLY,
    /// Default: true.
    SORT_CREATOR_PROPERTIES_FIRST,
    /// Default: false.
    ACCEPT_CASE_INSENSITIVE_PROPERTIES,
    /// Default: false.
    ACCEPT_CASE_INSENSITIVE_ENUMS,
    /// Default: false.
    ACCEPT_CASE_INSENSITIVE_VALUES,
    /// Default: false.
    USE_WRAPPER_NAME_AS_PROPERTY_NAME,
    /// Default: false.
    ALLOW_EXPLICIT_PROPERTY_RENAMING,
    /// Default: true.
    FIX_FIELD_NAME_UPPER_CASE_PREFIX,
    /// Default: true.
    ALLOW_COERCION_OF_SCALARS,
    /// Default: false.
    WRAPPERS_DEFAULT_TO_NULL,
    /// Default: true.
    IGNORE_MERGE_FOR_UNMERGEABLE,
    /// Default: true.
    APPLY_DEFAULT_VALUES,
}

/// Whether the feature is enabled by default (Jackson 3.1.8).
bool enabledByDefault(MapperFeature f) pure nothrow @nogc
{
    switch (f)
    {
    case MapperFeature.USE_ANNOTATIONS:
    case MapperFeature.INFER_PROPERTY_MUTATORS:
    case MapperFeature.INFER_CREATOR_FROM_CONSTRUCTOR_PROPERTIES:
    case MapperFeature.ALLOW_VOID_VALUED_PROPERTIES:
    case MapperFeature.DETECT_PARAMETER_NAMES:
    case MapperFeature.CAN_OVERRIDE_ACCESS_MODIFIERS:
    case MapperFeature.OVERRIDE_PUBLIC_ACCESS_MODIFIERS:
    case MapperFeature.INFER_BUILDER_TYPE_BINDINGS:
    case MapperFeature.REQUIRE_TYPE_ID_FOR_SUBTYPES:
    case MapperFeature.SORT_PROPERTIES_ALPHABETICALLY:
    case MapperFeature.SORT_CREATOR_PROPERTIES_FIRST:
    case MapperFeature.FIX_FIELD_NAME_UPPER_CASE_PREFIX:
    case MapperFeature.ALLOW_COERCION_OF_SCALARS:
    case MapperFeature.IGNORE_MERGE_FOR_UNMERGEABLE:
    case MapperFeature.APPLY_DEFAULT_VALUES:
        return true;
    default:
        return false;
    }
}

/// The bits of features enabled by default, one bit per member.
ulong defaultFeatures(E)() pure nothrow @nogc
{
    ulong mask;
    foreach (member; __traits(allMembers, E))
        if (enabledByDefault(__traits(getMember, E, member)))
            mask |= 1UL << __traits(getMember, E, member);
    return mask;
}

/**
 * The immutable configuration a mapper hands to its serializers and
 * deserializers: feature bits, naming, inclusion defaults and the descriptor
 * table. Introspected beans are cached here, as Jackson caches serializers.
 */
final class MapperConfig
{
    import flint.engine.aot.descriptor : Descriptor, DescriptorTable;
    import flint.jackson.annotation : JsonInclude;
    import flint.jackson.core.json : JsonFactory;
    import flint.jackson.databind.introspect : BeanDescription, NameTranslator, POJOPropertiesCollector;
    import flint.jackson.databind.node : JsonNodeFactory;

    /// Enabled `SerializationFeature`s.
    ulong serialization = defaultFeatures!SerializationFeature();
    /// Enabled `DeserializationFeature`s.
    ulong deserialization = defaultFeatures!DeserializationFeature();
    /// Enabled `MapperFeature`s.
    ulong mapper = defaultFeatures!MapperFeature();
    /// Enabled `DateTimeFeature`s.
    ulong dateTime = defaultFeatures!DateTimeFeature();
    /// Enabled `EnumFeature`s.
    ulong enums = defaultFeatures!EnumFeature();
    /// The naming strategy applied to implicit names, or null.
    NameTranslator naming;
    /// The strategy a `@JsonNaming` class names, or null when it has no binding.
    NameTranslator function(string strategyClass) @safe classNaming;
    /// Default inclusion of property values (`JsonInclude.Include.ALWAYS`).
    JsonInclude.Include defaultInclusion = JsonInclude.Include.ALWAYS;
    /// Default inclusion of map and collection contents.
    JsonInclude.Include defaultContentInclusion = JsonInclude.Include.ALWAYS;
    /// Creator detection.
    ConstructorDetector constructorDetector;
    /// Descriptors by Flint type name.
    DescriptorTable descriptors;
    /// The streaming factory.
    JsonFactory factory;
    /// The tree node factory.
    JsonNodeFactory nodeFactory;

    private BeanDescription[string] beans;

    /// Whether `f` is enabled.
    bool isEnabled(SerializationFeature f) const pure nothrow @nogc
    {
        return (serialization & (1UL << f)) != 0;
    }

    /// ditto
    bool isEnabled(DeserializationFeature f) const pure nothrow @nogc
    {
        return (deserialization & (1UL << f)) != 0;
    }

    /// ditto
    bool isEnabled(MapperFeature f) const pure nothrow @nogc
    {
        return (mapper & (1UL << f)) != 0;
    }

    /// ditto
    bool isEnabled(DateTimeFeature f) const pure nothrow @nogc
    {
        return (dateTime & (1UL << f)) != 0;
    }

    /// ditto
    bool isEnabled(EnumFeature f) const pure nothrow @nogc
    {
        return (enums & (1UL << f)) != 0;
    }

    /// The descriptor named `type`, or null.
    const(Descriptor) descriptor(scope const(char)[] type)
    {
        return descriptors is null ? null : descriptors.find(type);
    }

    /// The introspected bean of `d`, collected once per configuration.
    BeanDescription bean(const Descriptor d)
    {
        synchronized (this)
        {
            if (auto found = d.name in beans)
                return *found;
        }
        POJOPropertiesCollector collector;
        collector.sortAlphabetically = isEnabled(MapperFeature.SORT_PROPERTIES_ALPHABETICALLY);
        collector.sortCreatorPropertiesFirst = isEnabled(MapperFeature.SORT_CREATOR_PROPERTIES_FIRST);
        collector.implicitCreators = !constructorDetector.requireCtorAnnotation;
        collector.naming = naming;
        collector.classNaming = classNaming;
        auto collected = collector.collect(d);
        synchronized (this)
            beans[d.name] = collected;
        return collected;
    }

    /// A copy with an empty bean cache, for a builder to change.
    MapperConfig copy()
    {
        auto c = new MapperConfig();
        c.serialization = serialization;
        c.deserialization = deserialization;
        c.mapper = mapper;
        c.dateTime = dateTime;
        c.enums = enums;
        c.naming = naming;
        c.classNaming = classNaming;
        c.defaultInclusion = defaultInclusion;
        c.defaultContentInclusion = defaultContentInclusion;
        c.constructorDetector = constructorDetector;
        c.descriptors = descriptors;
        c.factory = factory;
        c.nodeFactory = nodeFactory;
        return c;
    }
}
