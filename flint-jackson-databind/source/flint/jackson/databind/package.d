/*
 * Ported from Jackson (jackson-databind) 3.1.8, https://github.com/FasterXML/jackson-databind,
 * tag jackson-databind-3.1.8: src/main/java/tools/jackson/databind/{ObjectMapper,ObjectWriter,
 * PropertyNamingStrategy,PropertyNamingStrategies}.java, json/JsonMapper.java,
 * cfg/MapperBuilder.java and introspect/NamingStrategyImpls.java
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D (rulebook v2). Generic methods
 * (readValue!T, writeValueAsString, convertValue!T) are one-line façades over
 * erased methods that take Any and Flint AOT descriptors (ADR-030 section 5);
 * `Class<T>` arguments are template parameters (R4). JsonMapper.Builder takes the
 * descriptor table the application's Flint AOT registry filled.
 */

/// Jackson databind: `ObjectMapper`/`JsonMapper`, features, naming strategies and the tree model entry points.
module flint.jackson.databind;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, DescriptorTable;
import flint.engine.aot.name : typeNameOf;
import flint.jackson.annotation : JsonInclude;
import flint.jackson.core : JsonGenerator, JsonParser, JsonToken, ObjectReadContext,
    ObjectWriteContext, PrettyPrinter, StreamReadFeature, StreamWriteFeature;
import flint.jackson.core.json : JsonFactory, JsonFactoryBuilder, JsonReadFeature, JsonWriteFeature, OutputSink;
import flint.jackson.core.util : ByteArrayBuilder, DefaultPrettyPrinter;
import flint.jackson.databind.introspect : NameTranslator;
import flint.jackson.databind.node : ArrayNode, JsonNode, JsonNodeFactory, ObjectNode;

public import flint.jackson.databind.cfg : ConstructorDetector, DateTimeFeature,
    DeserializationFeature, EnumFeature, MapperConfig, MapperFeature, SerializationFeature;
public import flint.jackson.databind.exc : DatabindException;

@safe:

/**
 * Class that defines how names of JSON properties ("external names") are
 * derived from names of POJO methods and fields ("internal names"), in cases
 * where no explicit annotations exist for naming.
 */
abstract class PropertyNamingStrategy
{
    /// The external name for a property whose implicit (Java Beans) name is `defaultName`.
    abstract string nameForProperty(string defaultName);
}

/// Container for standard `PropertyNamingStrategy` implementations and singleton instances.
final class PropertyNamingStrategies
{
    private this()
    {
    }

    /// Intermediate base class for simple implementations.
    abstract static class NamingBase : PropertyNamingStrategy
    {
        /// Translate the implicit name.
        abstract string translate(string input);

        override string nameForProperty(string defaultName)
        {
            return translate(defaultName);
        }
    }

    /// Naming convention used in Java, where words other than first are capitalized and no separator is used between words.
    static class LowerCamelCaseStrategy : NamingBase
    {
        override string translate(string input)
        {
            return input;
        }
    }

    /// Naming convention used in languages like Pascal, where all words are capitalized and no separator is used between words.
    static class UpperCamelCaseStrategy : NamingBase
    {
        override string translate(string input)
        {
            import std.uni : toUpper;
            import std.utf : decode, encode;

            if (input.length == 0)
                return input;
            size_t next;
            const first = decode(input, next);
            const upper = toUpper(first);
            if (upper == first)
                return input;
            char[] head;
            encode(head, upper);
            return head.idup ~ input[next .. $];
        }
    }

    /// Naming convention used in languages like C, where words are in lower-case letters, separated by underscores.
    static class SnakeCaseStrategy : NamingBase
    {
        override string translate(string input)
        {
            return snakeCase(input);
        }
    }

    /// Naming convention in which the words are in upper-case letters, separated by underscores.
    static class UpperSnakeCaseStrategy : SnakeCaseStrategy
    {
        override string translate(string input)
        {
            import std.ascii : toUpper;

            auto snake = snakeCase(input).dup;
            foreach (ref c; snake)
                c = toUpper(c);
            return snake.idup;
        }
    }

    /// Naming convention in which all words of the logical name are in lower case, and no separator is used between words.
    static class LowerCaseStrategy : NamingBase
    {
        override string translate(string input)
        {
            import std.uni : toLower;

            return toLower(input);
        }
    }

    /// Naming convention used in languages like Lisp, where words are in lower-case letters, separated by hyphens.
    static class KebabCaseStrategy : NamingBase
    {
        override string translate(string input)
        {
            return lowerCaseWithSeparator(input, '-');
        }
    }

    /// Naming convention widely used as configuration properties name, where words are in lower-case letters, separated by dots.
    static class LowerDotCaseStrategy : NamingBase
    {
        override string translate(string input)
        {
            return lowerCaseWithSeparator(input, '.');
        }
    }

    /// `LowerCamelCaseStrategy`: Java's own naming (the default).
    static PropertyNamingStrategy LOWER_CAMEL_CASE() pure nothrow
    {
        return new LowerCamelCaseStrategy();
    }

    /// `UpperCamelCaseStrategy`.
    static PropertyNamingStrategy UPPER_CAMEL_CASE() pure nothrow
    {
        return new UpperCamelCaseStrategy();
    }

    /// `SnakeCaseStrategy`.
    static PropertyNamingStrategy SNAKE_CASE() pure nothrow
    {
        return new SnakeCaseStrategy();
    }

    /// `UpperSnakeCaseStrategy`.
    static PropertyNamingStrategy UPPER_SNAKE_CASE() pure nothrow
    {
        return new UpperSnakeCaseStrategy();
    }

    /// `LowerCaseStrategy`.
    static PropertyNamingStrategy LOWER_CASE() pure nothrow
    {
        return new LowerCaseStrategy();
    }

    /// `KebabCaseStrategy`.
    static PropertyNamingStrategy KEBAB_CASE() pure nothrow
    {
        return new KebabCaseStrategy();
    }

    /// `LowerDotCaseStrategy`.
    static PropertyNamingStrategy LOWER_DOT_CASE() pure nothrow
    {
        return new LowerDotCaseStrategy();
    }
}

// NamingStrategyImpls.SNAKE_CASE (ASCII case rules, as Character.isUpperCase is for property names in practice).
private string snakeCase(string beanName) pure
{
    import std.uni : isUpper, toLower;
    import std.utf : decode, encode;

    char[] result;
    bool wasPrevTranslated;
    size_t i;
    bool first = true;
    while (i < beanName.length)
    {
        dchar c;
        try
            c = decode(beanName, i);
        catch (Exception)
        {
            c = beanName[i++];
        }
        if (!first || c != '_')
        {
            if (isUpper(c))
            {
                if (!wasPrevTranslated && result.length > 0 && result[$ - 1] != '_')
                    result ~= '_';
                c = toLower(c);
                wasPrevTranslated = true;
            }
            else
                wasPrevTranslated = false;
            encode(result, c);
        }
        first = false;
    }
    return result.length ? result.idup : beanName;
}

// NamingStrategyImpls.translateLowerCaseWithSeparator.
private string lowerCaseWithSeparator(string beanName, char separator) pure
{
    import std.uni : toLower;
    import std.utf : decode, encode;

    if (beanName.length == 0)
        return beanName;
    char[] result;
    size_t[] starts;
    int upperCount;
    size_t i;
    while (i < beanName.length)
    {
        dchar ch;
        try
            ch = decode(beanName, i);
        catch (Exception)
        {
            ch = beanName[i++];
        }
        const lc = toLower(ch);
        if (lc == ch)
        {
            if (upperCount > 1)
                result = result[0 .. starts[$ - 1]] ~ separator ~ result[starts[$ - 1] .. $];
            upperCount = 0;
        }
        else
        {
            if (upperCount == 0 && starts.length > 0)
                result ~= separator;
            ++upperCount;
        }
        starts ~= result.length;
        encode(result, lc);
    }
    return result.idup;
}

private final class MapperWriteContext : ObjectWriteContext.Base
{
    private bool indent;

    this(bool indent) pure nothrow @nogc
    {
        this.indent = indent;
    }

    override PrettyPrinter getPrettyPrinter()
    {
        return indent ? new DefaultPrettyPrinter() : null;
    }
}

/**
 * ObjectMapper provides functionality for reading and writing JSON, either to
 * and from basic POJOs (Plain Old Java Objects), or to and from a
 * general-purpose JSON Tree Model (`JsonNode`), as well as related
 * functionality for performing conversions.
 *
 * Type information comes from Flint AOT descriptors, never from runtime
 * reflection: a mapper finds `T`'s descriptor by its Flint type name in the
 * table its builder was given.
 */
class ObjectMapper
{
    /// The configuration serializers and deserializers read.
    protected MapperConfig _config;

    /// A mapper with Jackson 3.1.8's defaults and only the built-in scalar descriptors.
    this()
    {
        this(defaultConfig());
    }

    /// A mapper over `config`.
    protected this(MapperConfig config)
    {
        _config = config;
    }

    /// The defaults: Jackson 3.1.8's features, the default JSON factory and node factory.
    static MapperConfig defaultConfig()
    {
        auto config = new MapperConfig();
        config.descriptors = DescriptorTable.withBuiltins();
        config.factory = new JsonFactory();
        config.nodeFactory = JsonNodeFactory.instance();
        return config;
    }

    /// Whether `f` is enabled.
    bool isEnabled(SerializationFeature f) const pure nothrow @nogc
    {
        return _config.isEnabled(f);
    }

    /// ditto
    bool isEnabled(DeserializationFeature f) const pure nothrow @nogc
    {
        return _config.isEnabled(f);
    }

    /// ditto
    bool isEnabled(MapperFeature f) const pure nothrow @nogc
    {
        return _config.isEnabled(f);
    }

    /// ditto
    bool isEnabled(DateTimeFeature f) const pure nothrow @nogc
    {
        return _config.isEnabled(f);
    }

    /// ditto
    bool isEnabled(EnumFeature f) const pure nothrow @nogc
    {
        return _config.isEnabled(f);
    }

    /// The streaming factory.
    JsonFactory tokenStreamFactory()
    {
        return _config.factory;
    }

    /// The tree node factory.
    JsonNodeFactory getNodeFactory()
    {
        return _config.nodeFactory;
    }

    /// The descriptor table (Flint): what this mapper knows about application types.
    DescriptorTable descriptors()
    {
        return _config.descriptors;
    }

    /// The configuration (Flint): what Spring's message converter and Boot's auto-configuration read.
    MapperConfig serializationConfig()
    {
        return _config;
    }

    // ---- writing

    /// Method that can be used to serialize any Java value as a String.
    string writeValueAsString(T)(T value) if (!is(T == Any))
    {
        return writeValueAsString(Any.of(value));
    }

    /// ditto, erased.
    string writeValueAsString(Any value)
    {
        auto output = new ByteArrayBuilder();
        writeValue(output, value);
        return output.toUtf8String();
    }

    /// Method that can be used to serialize any Java value as a byte array, UTF-8 encoded.
    ubyte[] writeValueAsBytes(T)(T value) if (!is(T == Any))
    {
        return writeValueAsBytes(Any.of(value));
    }

    /// ditto, erased.
    ubyte[] writeValueAsBytes(Any value)
    {
        auto output = new ByteArrayBuilder();
        writeValue(output, value);
        return output.toByteArray();
    }

    /// Serialize `value` as UTF-8 JSON into `target`.
    void writeValue(ByteArrayBuilder target, Any value)
    {
        writeValue((scope const(ubyte)[] bytes) { target.write(bytes); }, value);
    }

    /// Serialize `value` as UTF-8 JSON to `sink` (Java's `writeValue(OutputStream, Object)`, R9).
    void writeValue(OutputSink sink, Any value)
    {
        auto g = _config.factory.createGenerator(
                new MapperWriteContext(_config.isEnabled(SerializationFeature.INDENT_OUTPUT)), sink);
        writeValue(g, value);
        g.close();
    }

    /// Method that can be used to serialize any Java value as JSON output, using provided `JsonGenerator`.
    void writeValue(T)(JsonGenerator g, T value) if (!is(T == Any))
    {
        writeValue(g, Any.of(value));
    }

    /// ditto, erased.
    void writeValue(JsonGenerator g, Any value)
    {
        import flint.jackson.databind.ser : serializeValue;

        serializeValue(_config, value, value.typeName(), g);
        if (_config.isEnabled(SerializationFeature.FLUSH_AFTER_WRITE_VALUE))
            g.flush();
    }

    /// Method to serialize given JSON Tree, using generator provided.
    void writeTree(JsonGenerator g, JsonNode rootNode)
    {
        rootNode.serialize(g);
    }

    /// A writer with this mapper's configuration.
    ObjectWriter writer()
    {
        return new ObjectWriter(this, _config.isEnabled(SerializationFeature.INDENT_OUTPUT));
    }

    /// Factory method for constructing an `ObjectWriter` that will serialize objects using the default pretty printer for indentation.
    ObjectWriter writerWithDefaultPrettyPrinter()
    {
        return new ObjectWriter(this, true);
    }

    // ---- reading

    /// Method to deserialize JSON content from given JSON content String (R4: the target type is a template parameter).
    T readValue(T)(string content)
    {
        return readValue(content, typeNameOf!T).get!T();
    }

    /// ditto, from UTF-8 bytes.
    T readValue(T)(const(ubyte)[] content)
    {
        return readValue(content, typeNameOf!T).get!T();
    }

    /// ditto, from a parser positioned before or at the value.
    T readValue(T)(JsonParser p)
    {
        return readValue(p, typeNameOf!T).get!T();
    }

    /// Erased: deserialize `content` into the type named `type`.
    Any readValue(string content, string type)
    {
        return readValue(cast(const(ubyte)[]) content, type);
    }

    /// ditto, from UTF-8 bytes.
    Any readValue(const(ubyte)[] content, string type)
    {
        import flint.jackson.databind.deser : verifyNoTrailingTokens;
        import flint.jackson.databind.exc : MismatchedInputException;

        auto p = _config.factory.createParser(ObjectReadContext.empty(), content);
        if (p.nextToken() == JsonToken.NOT_AVAILABLE)
            throw new MismatchedInputException("No content to map due to end-of-input", type, p.currentLocation());
        auto value = readValue(p, type);
        verifyNoTrailingTokens(_config, p, type);
        return value;
    }

    /// ditto, from a parser; reads one value and leaves the parser on its last token.
    Any readValue(JsonParser p, string type)
    {
        import flint.jackson.databind.deser : deserializeValue;

        if (p.currentToken() == JsonToken.NOT_AVAILABLE)
            p.nextToken();
        return deserializeValue(_config, p, type);
    }

    /// Method to deserialize JSON content as a tree `JsonNode`. Returns the missing node for empty content.
    JsonNode readTree(string content)
    {
        import flint.jackson.databind.node : MissingNode, readTreeFrom = readTree;
        import flint.jackson.databind.deser : verifyNoTrailingTokens;

        auto p = _config.factory.createParser(content);
        auto node = readTreeFrom(p, _config.nodeFactory);
        if (node is null)
            return MissingNode.getInstance();
        verifyNoTrailingTokens(_config, p, "flint.jackson.databind.node.JsonNode");
        return node;
    }

    /// ditto, from a parser.
    JsonNode readTree(JsonParser p)
    {
        import flint.jackson.databind.node : readTreeFrom = readTree;

        return readTreeFrom(p, _config.nodeFactory);
    }

    /// Convenience conversion method that will bind data given JSON tree contains into specific value (usually bean) type.
    T treeToValue(T)(JsonNode n)
    {
        return readValue!T(n.toString());
    }

    /// Method that is reverse of `treeToValue`: it will convert given Java value (usually bean) into its equivalent Tree model `JsonNode` representation.
    JsonNode valueToTree(T)(T fromValue)
    {
        return readTree(writeValueAsString(fromValue));
    }

    /// Convenience method for doing two-step conversion from given value, into instance of given value type, by writing value into temporary buffer and reading from the buffer into specified target type.
    T convertValue(T, F)(F fromValue)
    {
        return convertValue(Any.of(fromValue), typeNameOf!T).get!T();
    }

    /// ditto, erased.
    Any convertValue(Any fromValue, string toType)
    {
        if (fromValue.isNull())
            return Any.init;
        return readValue(writeValueAsString(fromValue), toType);
    }

    /// Note: return type is co-variant, as basic ObjectCodec abstraction cannot refer to concrete node types.
    ObjectNode createObjectNode()
    {
        return _config.nodeFactory.objectNode();
    }

    /// Note: return type is co-variant, as basic ObjectCodec abstraction cannot refer to concrete node types.
    ArrayNode createArrayNode()
    {
        return _config.nodeFactory.arrayNode();
    }
}

/// Builder object that can be used for per-serialization configuration of serialization parameters, such as JSON View and root type to use.
class ObjectWriter
{
    private ObjectMapper mapper;
    private bool indent;

    private this(ObjectMapper mapper, bool indent)
    {
        this.mapper = mapper;
        this.indent = indent;
    }

    /// A writer that pretty-prints with Jackson's default pretty printer.
    ObjectWriter withDefaultPrettyPrinter()
    {
        return new ObjectWriter(mapper, true);
    }

    /// Method that can be used to serialize any Java value as a String.
    string writeValueAsString(T)(T value) if (!is(T == Any))
    {
        return writeValueAsString(Any.of(value));
    }

    /// ditto, erased.
    string writeValueAsString(Any value)
    {
        auto output = new ByteArrayBuilder();
        auto g = mapper._config.factory.createGenerator(new MapperWriteContext(indent), output);
        mapper.writeValue(g, value);
        g.close();
        return output.toUtf8String();
    }
}

/**
 * JSON-format specific `ObjectMapper` implementation. Instances are immutable;
 * configure one with `JsonMapper.builder()` or `rebuild()`.
 */
class JsonMapper : ObjectMapper
{
    /// A mapper with Jackson 3.1.8's defaults.
    this()
    {
        super();
    }

    /// A mapper built by `b`.
    protected this(Builder b)
    {
        super(b.config);
    }

    /// Main factory method to use for constructing `JsonMapper` instances with different configuration.
    static Builder builder()
    {
        return new Builder(defaultConfig());
    }

    /// Main factory method with a pre-configured `JsonFactory`.
    static Builder builder(JsonFactory streamFactory)
    {
        auto config = defaultConfig();
        config.factory = streamFactory;
        return new Builder(config);
    }

    /// A builder that starts from this mapper's configuration.
    Builder rebuild()
    {
        return new Builder(_config.copy());
    }

    /// Jackson's `MapperBuilder`, specialized for JSON: features, naming, inclusion and descriptors.
    static class Builder
    {
        private MapperConfig config;
        private JsonFactoryBuilder streams;

        private this(MapperConfig config)
        {
            this.config = config;
            streams = config.factory.rebuild();
        }

        /// Enable each feature.
        Builder enable(F...)(F features)
        {
            foreach (f; features)
                configure(f, true);
            return this;
        }

        /// Disable each feature.
        Builder disable(F...)(F features)
        {
            foreach (f; features)
                configure(f, false);
            return this;
        }

        private static void set(ref ulong mask, int bit, bool state) pure nothrow @nogc
        {
            if (state)
                mask |= 1UL << bit;
            else
                mask &= ~(1UL << bit);
        }

        /// Turn `f` on or off.
        Builder configure(SerializationFeature f, bool state)
        {
            set(config.serialization, f, state);
            return this;
        }

        /// ditto
        Builder configure(DeserializationFeature f, bool state)
        {
            set(config.deserialization, f, state);
            return this;
        }

        /// ditto
        Builder configure(MapperFeature f, bool state)
        {
            set(config.mapper, f, state);
            return this;
        }

        /// ditto
        Builder configure(DateTimeFeature f, bool state)
        {
            set(config.dateTime, f, state);
            return this;
        }

        /// ditto
        Builder configure(EnumFeature f, bool state)
        {
            set(config.enums, f, state);
            return this;
        }

        /// ditto, for the streaming factory's features.
        Builder configure(StreamReadFeature f, bool state)
        {
            streams.configure(f, state);
            return this;
        }

        /// ditto
        Builder configure(StreamWriteFeature f, bool state)
        {
            streams.configure(f, state);
            return this;
        }

        /// ditto
        Builder configure(JsonReadFeature f, bool state)
        {
            streams.configure(f, state);
            return this;
        }

        /// ditto
        Builder configure(JsonWriteFeature f, bool state)
        {
            streams.configure(f, state);
            return this;
        }

        /// Set the naming strategy applied to implicit property names (null for none).
        Builder propertyNamingStrategy(PropertyNamingStrategy s)
        {
            config.naming = s is null ? null : (string name) => s.nameForProperty(name);
            return this;
        }

        /**
         * Change the default inclusion of property values and of map and collection contents.
         * Jackson takes an operator over `JsonInclude.Value`; Flint takes the two settings that
         * value holds (deviation D-JACKSON-3), which is what Boot's
         * `flint.jackson.default-property-inclusion` sets.
         */
        Builder changeDefaultPropertyInclusion(JsonInclude.Include valueInclusion,
                JsonInclude.Include contentInclusion = JsonInclude.Include.USE_DEFAULTS)
        {
            config.defaultInclusion = valueInclusion;
            if (contentInclusion != JsonInclude.Include.USE_DEFAULTS)
                config.defaultContentInclusion = contentInclusion;
            return this;
        }

        /// Set the creator detection.
        Builder constructorDetector(ConstructorDetector detector)
        {
            config.constructorDetector = detector;
            return this;
        }

        /// Use `table` for application types (Flint): the table the AOT registry filled.
        Builder descriptors(DescriptorTable table)
        {
            config.descriptors = table;
            return this;
        }

        /// Add one descriptor to the table (Flint).
        Builder descriptor(Descriptor d)
        {
            config.descriptors.add(d);
            return this;
        }

        /// Discover modules on the classpath: a no-op, since Flint's datatype support is built in.
        Builder findAndAddModules()
        {
            return this;
        }

        /// Create the mapper.
        JsonMapper build()
        {
            config.factory = streams.build();
            return new JsonMapper(this);
        }
    }
}
