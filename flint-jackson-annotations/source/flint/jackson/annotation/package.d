/*
 * Ported from Jackson (jackson-annotations) 2.21, https://github.com/FasterXML/jackson-annotations,
 * tag jackson-annotations-2.21, src/main/java/com/fasterxml/jackson/annotation/:
 *   JsonAlias.java JsonAnyGetter.java JsonAnySetter.java JsonAutoDetect.java JsonBackReference.java
 *   JsonClassDescription.java JsonCreator.java JsonEnumDefaultValue.java JsonFilter.java JsonFormat.java
 *   JsonGetter.java JsonIgnore.java JsonIgnoreProperties.java JsonIgnoreType.java JsonInclude.java
 *   JsonIncludeProperties.java JsonKey.java JsonManagedReference.java JsonMerge.java
 *   JsonPropertyDescription.java JsonProperty.java JsonPropertyOrder.java JsonRawValue.java JsonRootName.java
 *   JsonSetter.java JsonTypeId.java JsonTypeName.java JsonUnwrapped.java JsonValue.java
 *   JacksonAnnotation.java JacksonAnnotationsInside.java JacksonInject.java OptBoolean.java Nulls.java
 *   PropertyAccessor.java
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: each annotation is a D UDA struct with the same
 * elements and defaults (rulebook R2); nested enums stay nested (R13). Elements
 * typed Class<?> (JsonInclude.valueFilter, JsonTypeInfo, JsonSubTypes,
 * JsonIdentityInfo, JsonView, JsonSerializeAs, JsonDeserializeAs) follow once
 * flint.java.lang has ClassRef (see docs/spring/phase1/third-party.md).
 */

/**
 * Jackson's general-purpose annotations, which `flint.jackson.databind` reads
 * from Flint AOT descriptors. A bare `@JsonIgnore` attaches the type and reads
 * as `JsonIgnore.init`; `@JsonProperty("id")` sets the first element, `value`.
 */
module flint.jackson.annotation;

@safe:

/// Optional Boolean value ("nullean"). Used in cases where annotations need to explicitly specify a third, "default" state.
enum OptBoolean
{
    /// Value that indicates that the annotation property is explicitly defined to be enabled, or true.
    TRUE,
    /// Value that indicates that the annotation property is explicitly defined to be disabled, or false.
    FALSE,
    /// Value that indicates that the annotation property does NOT have an explicit definition of enabled/disabled (or true/false); instead, a higher-level configuration value is used.
    DEFAULT,
}

/// Value that indicates what to do with `null` values: `SET` sets it, `SKIP` skips, `FAIL` throws, `AS_EMPTY` substitutes the empty value, `DEFAULT` uses the configured default.
enum Nulls
{
    ///
    SET,
    ///
    SKIP,
    ///
    FAIL,
    ///
    AS_EMPTY,
    ///
    DEFAULT,
}

/// Enumeration used to define kinds of elements (called "property accessors") that annotations like `JsonAutoDetect` apply to.
enum PropertyAccessor
{
    ///
    GETTER,
    ///
    SETTER,
    ///
    FIELD,
    ///
    IS_GETTER,
    ///
    CREATOR,
    ///
    SCALAR_CONSTRUCTOR,
    ///
    NONE,
    ///
    ALL,
}

/// Meta-annotation (annotations used on other annotations) used for marking all annotations that are part of Jackson package.
struct JacksonAnnotation
{
}

/// Meta-annotation (annotations used on other annotations) used for indicating that instead of using target annotation (annotation annotated with this annotation), Jackson should use meta-annotations it has.
struct JacksonAnnotationsInside
{
}

/// Marker annotation that can be used to define a non-static method as a "setter" or "getter" for a logical property (depending on its signature), or non-static object field to be used (serialized, deserialized) as a logical property (to assign value or get value from).
struct JsonProperty
{
    /// Special value that indicates that handlers should use the default name (derived from method or field name) for property.
    enum string USE_DEFAULT_NAME = "";

    /// Marker value used to indicate that no index has been specified.
    enum int INDEX_UNKNOWN = -1;

    /// Various options for `access` property, specifying how property may be accessed during serialization ("read") and deserialization ("write").
    enum Access
    {
        ///
        AUTO,
        ///
        READ_ONLY,
        ///
        WRITE_ONLY,
        ///
        READ_WRITE,
    }

    /// Defines name of the logical property, i.e. JSON object property name to use for the property. If value is empty String (which is the default), will try to use name of the field that is annotated.
    string value = "";

    /// Optional namespace to use with data formats that support such concept (specifically XML).
    string namespace = "";

    /// Property that indicates whether a value (which may be explicit null) is expected for property during deserialization or not.
    bool required = false;

    /// Property that indicates whether a value is expected for property during deserialization, with a third, default state.
    OptBoolean isRequired = OptBoolean.DEFAULT;

    /// Property that indicates numerical index of this property (relative to other properties specified for the Object).
    int index = INDEX_UNKNOWN;

    /// Property that may be used to document expected default value for the property.
    string defaultValue = "";

    /// Optional property that may be used to change the way visibility of accessors (getter, field-as-getter) and mutators (constructor parameter, setter, field-as-setter) is determined.
    Access access = Access.AUTO;
}

/// Marker annotation that indicates that the logical property that the accessor (field, getter/setter method or Creator parameter [of JsonCreator-annotated constructor or factory method]) is to be ignored by introspection-based serialization and deserialization functionality.
struct JsonIgnore
{
    /// Optional argument that defines whether this annotation is active or not.
    bool value = true;
}

/// Annotation used to indicate when value of the annotated property (when used for a field, method or constructor parameter), or all properties of the annotated class, is to be serialized.
struct JsonInclude
{
    /// Enumeration used with `JsonInclude` to define which properties of Java Beans are to be included in serialization.
    enum Include
    {
        ///
        ALWAYS,
        ///
        NON_NULL,
        ///
        NON_ABSENT,
        ///
        NON_EMPTY,
        ///
        NON_DEFAULT,
        ///
        CUSTOM,
        ///
        USE_DEFAULTS,
    }

    /// Inclusion rule to use for instances (values) of types (Classes) or properties annotated.
    Include value = Include.ALWAYS;

    /// Inclusion rule to use for entries ("content") of java.util.Map types annotated.
    Include content = Include.ALWAYS;
}

/// General-purpose annotation used for configuring details of how values of properties are to be serialized.
struct JsonFormat
{
    /// Value that indicates that default `java.util.Locale` (from deserialization or serialization context) should be used.
    enum string DEFAULT_LOCALE = "##default";

    /// Value that indicates that default `java.util.TimeZone` (from deserialization or serialization context) should be used.
    enum string DEFAULT_TIMEZONE = "##default";

    /// Value that indicates the default radix (10) for integral numbers.
    enum int DEFAULT_RADIX = -1;

    /// Value enumeration used for indicating preferred Shape; translates loosely to JSON types, with some extra values to indicate less precise choices.
    enum Shape
    {
        ///
        BINARY,
        ///
        BOOLEAN,
        ///
        NUMBER,
        ///
        NUMBER_FLOAT,
        ///
        NUMBER_INT,
        ///
        STRING,
        ///
        SCALAR,
        ///
        ARRAY,
        ///
        OBJECT,
        ///
        ANY,
        ///
        NATURAL,
        ///
        POJO,
    }

    /// Set of features that can be enabled/disabled for property annotated.
    enum Feature
    {
        ///
        ACCEPT_SINGLE_VALUE_AS_ARRAY,
        ///
        ACCEPT_CASE_INSENSITIVE_PROPERTIES,
        ///
        READ_UNKNOWN_ENUM_VALUES_AS_NULL,
        ///
        READ_UNKNOWN_ENUM_VALUES_USING_DEFAULT_VALUE,
        ///
        READ_DATE_TIMESTAMPS_AS_NANOSECONDS,
        ///
        ACCEPT_CASE_INSENSITIVE_VALUES,
        ///
        WRITE_DATE_TIMESTAMPS_AS_NANOSECONDS,
        ///
        WRITE_DATES_WITH_ZONE_ID,
        ///
        WRITE_SINGLE_ELEM_ARRAYS_UNWRAPPED,
        ///
        WRITE_SORTED_MAP_ENTRIES,
        ///
        ADJUST_DATES_TO_CONTEXT_TIME_ZONE,
    }

    /// Datatype-specific additional piece of configuration that may be used to further refine formatting aspects.
    string pattern = "";

    /// Structure to use for serialization: definition of mapping depends on datatype, but usually has straight-forward counterpart in data format (JSON).
    Shape shape = Shape.ANY;

    /// Locale to use for serialization (if needed).
    string locale = DEFAULT_LOCALE;

    /// TimeZone to use for serialization (if needed).
    string timezone = DEFAULT_TIMEZONE;

    /// Property that indicates whether "lenient" handling should be enabled or disabled.
    OptBoolean lenient = OptBoolean.DEFAULT;

    /// Radix to use for serializing and deserializing integral numbers.
    int radix = DEFAULT_RADIX;

    /// Set of `JsonFormat.Feature`s to explicitly enable with respect to handling of annotated property (Java's `with`, a D keyword).
    Feature[] with_ = [];

    /// Set of `JsonFormat.Feature`s to explicitly disable with respect to handling of annotated property.
    Feature[] without = [];
}

/// Marker annotation that can be used to define constructors and factory methods as one to use for instantiating new instances of the associated class.
struct JsonCreator
{
    /// How a creator binds its arguments.
    enum Mode
    {
        ///
        DEFAULT,
        ///
        DELEGATING,
        ///
        PROPERTIES,
        ///
        DISABLED,
    }

    /// Property that is used to indicate how argument(s) is/are bound for creator.
    Mode mode = Mode.DEFAULT;
}

/// Annotation that can be used to define one or more alternative names for a property, accepted during deserialization as alternative to the official name.
struct JsonAlias
{
    /// One or more secondary names to accept as aliases to the official name.
    string[] value = [];
}

/// Annotation that may be used to define ordering (possibly partial) to use when serializing object properties.
struct JsonPropertyOrder
{
    /// Order in which properties of annotated object are to be serialized in.
    string[] value = [];

    /// Property that defines what to do regarding ordering of properties not explicitly included in annotation instance.
    bool alphabetic = false;
}

/// Annotation that can be used to either suppress serialization of properties (during serialization), or ignore processing of JSON properties read (during deserialization).
struct JsonIgnoreProperties
{
    /// Names of properties to ignore.
    string[] value = [];

    /// Property that defines whether it is ok to just ignore any unrecognized properties during deserialization.
    bool ignoreUnknown = false;

    /// Property that can be enabled to allow "getters" to be used (that is, prevent ignoral of getters for properties listed in `value()`).
    bool allowGetters = false;

    /// Property that can be enabled to allow "setters" to be used (that is, prevent ignoral of setters for properties listed in `value()`).
    bool allowSetters = false;
}

/// Annotation that can be used to either only include serialization of properties (during serialization), or only include processing of JSON properties read (during deserialization).
struct JsonIncludeProperties
{
    /// Names of properties to include.
    string[] value = [];
}

/// Marker annotation that indicates that all properties that have type annotated with this annotation are to be ignored during serialization and deserialization.
struct JsonIgnoreType
{
    /// Optional argument that defines whether this annotation is active or not.
    bool value = true;
}

/// Marker annotation that indicates that the value of annotated accessor (either field or "getter" method [a method with non-void return type, no args]) is to be used as the single value to serialize for the instance, instead of the usual method of collecting properties of value.
struct JsonValue
{
    /// Optional argument that defines whether this annotation is active or not.
    bool value = true;
}

/// Marker annotation that can be used to define a non-static, no-argument value-returning (non-void) method to be used as a "getter" for a logical property.
struct JsonGetter
{
    /// Defines name of the logical property this method is used to access ("get").
    string value = "";
}

/// Annotation that can be used to define a non-static, single-argument method to be used as a "setter" for a logical property as an alternative to recommended `JsonProperty` annotation; or (since 2.9) to specify additional aspects of the assignment.
struct JsonSetter
{
    /// Optional default argument that defines logical property this method is used to modify ("set").
    string value = "";

    /// Specifies action to take when input contains explicit `null` value (if format has one).
    Nulls nulls = Nulls.DEFAULT;

    /// Specifies action to take when input to match into content value (of a `Collection`, `Map`, array, or referential value) contains explicit `null` value (if format has one) to bind.
    Nulls contentNulls = Nulls.DEFAULT;
}

/// Marker annotation that can be used to define a non-static, no-argument method to be an "any getter"; accessor for getting a set of key/value pairs, to be serialized as part of containing POJO (similar to unwrapping) along with regular property values it has.
struct JsonAnyGetter
{
    /// Optional argument that defines whether this annotation is active or not.
    bool enabled = true;
}

/// Marker annotation that can be used to define a logical "any setter" mutator -- either using non-static two-argument method (first argument name of property, second value to set) or a field (of type `java.util.Map` or POJO) - to be used as a "fallback" handler for all otherwise unrecognized properties found from JSON content.
struct JsonAnySetter
{
    /// Optional argument that defines whether this annotation is active or not.
    bool enabled = true;
}

/// Marker annotation that indicates that the annotated method or field should be serialized by including literal String value of the property as is, without quoting of characters.
struct JsonRawValue
{
    /// Optional argument that defines whether this annotation is active or not.
    bool value = true;
}

/// Annotation similar to `javax.xml.bind.annotation.XmlRootElement`, used to indicate name to use for root-level wrapping, if wrapping is enabled.
struct JsonRootName
{
    /// Root name to use.
    string value = "";

    /// Optional namespace to use with data formats that support such concept (specifically XML).
    string namespace = "";

    /// Whether the root value is wrapped even when root wrapping is otherwise disabled.
    bool alwaysWrap = false;
}

/// Marker annotation that can be used to define a non-static, no-argument method or member field as something of a reverse of `JsonAnySetter` method; basically being used like a getter but such that it contains a single value to serialize when the object is used as a Map key.
struct JsonKey
{
    /// Optional argument that defines whether this annotation is active or not.
    bool value = true;
}

/// Annotation to specify whether annotated property value should use "merging" approach: merging meaning that the current value is first accessed (with a getter or field) and then modified with incoming data.
struct JsonMerge
{
    /// Whether merging should or should not be enabled for the annotated property.
    OptBoolean value = OptBoolean.TRUE;
}

/// Annotation used to indicate that a property should be serialized "unwrapped" -- that is, if it would be serialized as Object value, its properties are instead included as properties of its containing Object -- and deserialized reproducing "missing" structure.
struct JsonUnwrapped
{
    /// Property that is usually only used when overriding (masking) annotations, using mix-in annotations.
    bool enabled = true;

    /// Optional property that can be used to add prefix String to use in front of names of properties that are unwrapped.
    string prefix = "";

    /// Optional property that can be used to add suffix String to append at the end of names of properties that are unwrapped.
    string suffix = "";
}

/// Class annotation that can be used to define which kinds of Methods are to be detected by auto-detection, and with what minimum access level.
struct JsonAutoDetect
{
    /// Enumeration for possible visibility thresholds (minimum visibility) that can be used to limit which methods (and fields) are auto-detected.
    enum Visibility
    {
        ///
        ANY,
        ///
        NON_PRIVATE,
        ///
        PROTECTED_AND_PUBLIC,
        ///
        PUBLIC_ONLY,
        ///
        NONE,
        ///
        DEFAULT,
    }

    /// Minimum visibility required for auto-detecting regular getter methods.
    Visibility getterVisibility = Visibility.DEFAULT;

    /// Minimum visibility required for auto-detecting is-getter methods.
    Visibility isGetterVisibility = Visibility.DEFAULT;

    /// Minimum visibility required for auto-detecting setter methods.
    Visibility setterVisibility = Visibility.DEFAULT;

    /// Minimum visibility required for auto-detecting Creator methods, except for no-argument constructors (which are always detected no matter what).
    Visibility creatorVisibility = Visibility.DEFAULT;

    /// Minimum visibility required for auto-detecting single-scalar-argument constructors.
    Visibility scalarConstructorVisibility = Visibility.DEFAULT;

    /// Minimum visibility required for auto-detecting member fields.
    Visibility fieldVisibility = Visibility.DEFAULT;
}

/// Annotation used to indicate that associated property is part of two-way linkage between fields; and that its role is "child" (or "back") link.
struct JsonBackReference
{
    /// Logical have for the reference property pair; used to link managed and back references.
    string value = "defaultReference";
}

/// Annotation used to indicate that annotated property is part of two-way linkage between fields; and that its role is "parent" (or "forward") link.
struct JsonManagedReference
{
    /// Logical have for the reference property pair; used to link managed and back references.
    string value = "defaultReference";
}

/// Jackson-specific annotation used for indicating that value of annotated property will be "injected", i.e. set based on value configured by `ObjectMapper` (usually on per-call basis).
struct JacksonInject
{
    /// Logical id of the value to inject; if not specified (or specified as empty String), will use id based on declared type of property.
    string value = "";

    /// Whether matching value from input (if any) is used for annotated property or not.
    OptBoolean useInput = OptBoolean.DEFAULT;

    /// Whether to avoid throwing an exception when the `ObjectMapper` does not find the value to inject.
    OptBoolean optional = OptBoolean.DEFAULT;
}

/// Annotation used for binding logical name that the annotated class has.
struct JsonTypeName
{
    /// Logical type name for annotated type.
    string value = "";
}

/// Marker annotation that can be used on a property accessor (field, getter or setter, constructor parameter) to indicate that the property is to contain type id to use when including polymorphic type information.
struct JsonTypeId
{
}

/// Annotation used to indicate which logical filter is to be used for filtering out properties of type (class) annotated; association made by this annotation declaring ids of filters, and `ObjectMapper` (or objects it delegates to) providing matching filters by id.
struct JsonFilter
{
    /// Id of filter to use.
    string value = "";
}

/// Annotation used to define a human readable description for a logical property.
struct JsonPropertyDescription
{
    /// The value.
    string value = "";
}

/// Annotation used to define a human readable description for annotated type (class).
struct JsonClassDescription
{
    /// The value.
    string value = "";
}

/// Marker annotation that can be used to define a default value used when trying to deserialize unknown Enum values.
struct JsonEnumDefaultValue
{
}
