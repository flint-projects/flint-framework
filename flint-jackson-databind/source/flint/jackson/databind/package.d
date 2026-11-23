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

// The strategy a @JsonNaming class names, for the standard strategies (Jackson instantiates the class).
private NameTranslator standardNaming(string strategyClass) @safe
{
    alias S = PropertyNamingStrategies;
    static foreach (T; imported!"std.meta".AliasSeq!(S.LowerCamelCaseStrategy, S.UpperCamelCaseStrategy,
            S.SnakeCaseStrategy, S.UpperSnakeCaseStrategy, S.LowerCaseStrategy,
            S.KebabCaseStrategy, S.LowerDotCaseStrategy))
    {
        if (strategyClass == typeNameOf!T)
        {
            PropertyNamingStrategy strategy = new T();
            return (string name) => strategy.nameForProperty(name);
        }
    }
    return null;
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
            import flint.engine.aot.text : decodeUtf8, utf8;
            import flint.jackson.databind.casing : toUpper = toUpperCase;

            if (input.length == 0)
                return input;
            size_t next;
            const first = decodeUtf8(input, next);
            const upper = toUpper(first);
            return upper == first ? input : utf8(upper) ~ input[next .. $];
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
            auto snake = snakeCase(input).dup;
            foreach (ref c; snake)
                if (c >= 'a' && c <= 'z')
                    c -= 32; // Java's toUpperCase on the ASCII letters snake case produces
            return snake.idup;
        }
    }

    /// Naming convention in which all words of the logical name are in lower case, and no separator is used between words.
    static class LowerCaseStrategy : NamingBase
    {
        override string translate(string input)
        {
            return lowerCase(input);
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
    import flint.engine.aot.text : decodeUtf8, utf8;
    import flint.jackson.databind.casing : isUpper = isUpperCase, toLower = toLowerCase;

    string result;
    bool wasPrevTranslated;
    size_t i;
    bool first = true;
    while (i < beanName.length)
    {
        dchar c = decodeUtf8(beanName, i);
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
            result ~= utf8(c);
        }
        first = false;
    }
    return result.length ? result : beanName;
}

// NamingStrategyImpls.translateLowerCaseWithSeparator.
private string lowerCaseWithSeparator(string beanName, char separator) pure
{
    import flint.engine.aot.text : decodeUtf8, utf8;
    import flint.jackson.databind.casing : toLower = toLowerCase;

    if (beanName.length == 0)
        return beanName;
    string result;
    size_t[] starts;
    int upperCount;
    size_t i;
    while (i < beanName.length)
    {
        const ch = decodeUtf8(beanName, i);
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
        result ~= utf8(lc);
    }
    return result;
}

/// `String.toLowerCase` by code point (`Character.toLowerCase`), without std.uni's string templates.
package(flint.jackson.databind) string lowerCase(string text) pure
{
    import flint.engine.aot.text : decodeUtf8, utf8;
    import flint.jackson.databind.casing : toLower = toLowerCase;

    string result;
    size_t i;
    while (i < text.length)
    {
        const start = i;
        const c = decodeUtf8(text, i);
        const lower = toLower(c);
        result ~= lower == c ? text[start .. i] : utf8(lower);
    }
    return result;
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

/++
Flint: whether a value of `T` can hold a `java.util.Date`: `T` is a `Date`, or an array, associative array, template
instance (`List!Date`, `Optional!Date`, `HashMap!(string, Date)`) or aggregate whose fields hold one, at any depth.
The templated `ObjectMapper` methods register `JavaUtilDateModule` for such types.
+/
template holdsDate(T, Seen...)
{
    import flint.java.util.date : Date;

    static if (seenIn!(T, Seen))
        enum holdsDate = false;
    else static if (is(T : const(Date)))
        enum holdsDate = true;
    else static if (is(T == E[], E))
        enum holdsDate = holdsDate!(E, T, Seen);
    else static if (is(T == V[K], V, K))
        enum holdsDate = holdsDate!(V, T, Seen) || holdsDate!(K, T, Seen);
    else static if (is(T == struct) || is(T == class) || is(T == union) || is(T == interface))
        enum holdsDate = anyHoldsDate!(T, Seen);
    else
        enum holdsDate = false;
}

private template seenIn(T, Seen...)
{
    enum seenIn = () {
        bool found;
        static foreach (S; Seen)
            static if (is(S == T))
                found = true;
        return found;
    }();
}

// A template instance's type arguments, an aggregate's fields and a class's base classes.
private template anyHoldsDate(T, Seen...)
{
    enum anyHoldsDate = () {
        bool found;
        static if (is(T == X!Args, alias X, Args...))
            static foreach (A; Args)
                static if (is(A))
                    found = found || holdsDate!(A, T, Seen);
        static if (!is(T == interface))
            static foreach (F; typeof(T.tupleof))
                found = found || holdsDate!(F, T, Seen);
        static if (is(T == class) && is(T Bases == super))
            static foreach (B; Bases)
                found = found || holdsDate!(B, T, Seen);
        return found;
    }();
}

/++
Jackson's `JacksonModule`: an extension a mapper builder registers (`addModule`), which configures the mapper
through its `SetupContext`.

Deviations: `version()` and `Versioned` are not ported (no `Version` type yet), and `getRegistrationId` returns a
string, the name by default, where Java returns an `Object`.
+/
abstract class JacksonModule
{
    /// The module's name, for diagnostics.
    abstract string getModuleName();

    /// What identifies the module among registrations: a module whose id is already registered is skipped.
    string getRegistrationId()
    {
        return getModuleName();
    }

    /// Configure the mapper being built; called once, when the module is registered.
    abstract void setupModule(SetupContext context);

    /// Modules registered before this one.
    JacksonModule[] getDependencies()
    {
        return null;
    }

    /// What a module configures the mapper through.
    interface SetupContext
    {
        /// The data format: "JSON".
        string getFormatName();

        /// The builder registering the module.
        Object getOwner();

        /// Whether `f` is enabled.
        bool isEnabled(MapperFeature f);

        /// ditto
        bool isEnabled(DeserializationFeature f);

        /// ditto
        bool isEnabled(SerializationFeature f);
    }
}

// The context a JsonMapper.Builder registers modules with; Flint's own modules reach the configuration through it.
package(flint.jackson.databind) final class ModuleContext : JacksonModule.SetupContext
{
    private Object owner;
    package(flint.jackson.databind) MapperConfig config;

    this(Object owner, MapperConfig config)
    {
        this.owner = owner;
        this.config = config;
    }

    string getFormatName()
    {
        return "JSON";
    }

    Object getOwner()
    {
        return owner;
    }

    bool isEnabled(MapperFeature f)
    {
        return config.isEnabled(f);
    }

    bool isEnabled(DeserializationFeature f)
    {
        return config.isEnabled(f);
    }

    bool isEnabled(SerializationFeature f)
    {
        return config.isEnabled(f);
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
        _compactContext = new MapperWriteContext(false);
        _indentedContext = new MapperWriteContext(true);
    }

    private ObjectWriteContext _compactContext;
    private ObjectWriteContext _indentedContext;

    /// The defaults: Jackson 3.1.8's features, the default JSON factory and node factory.
    static MapperConfig defaultConfig()
    {
        auto config = new MapperConfig();
        config.descriptors = DescriptorTable.withBuiltins();
        config.factory = new JsonFactory();
        config.nodeFactory = JsonNodeFactory.instance();
        config.classNaming = &standardNaming;
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

    /// The modules registered with this mapper's builder, in registration order.
    final JacksonModule[] registeredModules()
    {
        JacksonModule[] result;
        foreach (m; _config.modules)
            result ~= cast(JacksonModule) m;
        return result;
    }

    // The templated methods of a type that holds a java.util.Date register JavaUtilDateModule's reader and pattern
    // formatter, so only applications that read or format Dates link them (D-JACKSON-10). Idempotent; private, so
    // final and linked only where a template instance calls it.
    private void registerDates()
    {
        import flint.jackson.databind.stddateformat : installJavaUtilDate;

        if (_config.dateHooks.read is null)
            installJavaUtilDate(_config);
    }

    // ---- writing

    /// Method that can be used to serialize any Java value as a String.
    string writeValueAsString(T)(T value) if (!is(T == Any))
    {
        static if (holdsDate!T)
            registerDates();
        return writeValueAsString(Any.of(value));
    }

    /// ditto, erased.
    string writeValueAsString(Any value)
    {
        return (cast(const(char)[]) writeValueAsBytes(value)).idup;
    }

    /// Method that can be used to serialize any Java value as a byte array, UTF-8 encoded.
    ubyte[] writeValueAsBytes(T)(T value) if (!is(T == Any))
    {
        static if (holdsDate!T)
            registerDates();
        return writeValueAsBytes(Any.of(value));
    }

    /// ditto, erased. The generator keeps the document in one buffer, which it hands over.
    ubyte[] writeValueAsBytes(Any value)
    {
        return writeCollected(writeContext(_config.isEnabled(SerializationFeature.INDENT_OUTPUT)), value);
    }

    // Serialize into a buffered generator and take its buffer: no builder, no sink closure, no copy.
    private ubyte[] writeCollected(ObjectWriteContext context, Any value)
    {
        auto g = _config.factory.createBufferedGenerator(context);
        writeValue(g, value);
        g.close();
        return g.collected();
    }

    // The write contexts carry only the INDENT_OUTPUT choice, so one of each serves every call.
    private ObjectWriteContext writeContext(bool indent)
    {
        return indent ? _indentedContext : _compactContext;
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
                writeContext(_config.isEnabled(SerializationFeature.INDENT_OUTPUT)), sink);
        writeValue(g, value);
        g.close();
    }

    /// Method that can be used to serialize any Java value as JSON output, using provided `JsonGenerator`.
    void writeValue(T)(JsonGenerator g, T value) if (!is(T == Any))
    {
        static if (holdsDate!T)
            registerDates();
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
        static if (holdsDate!T)
            registerDates();
        return readValue(content, typeNameOf!T).get!T();
    }

    /// ditto, from UTF-8 bytes.
    T readValue(T)(const(ubyte)[] content)
    {
        static if (holdsDate!T)
            registerDates();
        return readValue(content, typeNameOf!T).get!T();
    }

    /// ditto, from a parser positioned before or at the value.
    T readValue(T)(JsonParser p)
    {
        static if (holdsDate!T)
            registerDates();
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
        static if (holdsDate!T || holdsDate!F)
            registerDates();
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
        static if (holdsDate!T)
            mapper.registerDates();
        return writeValueAsString(Any.of(value));
    }

    /// ditto, erased.
    string writeValueAsString(Any value)
    {
        return (cast(const(char)[]) mapper.writeCollected(mapper.writeContext(indent), value)).idup;
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

        /// Discover modules on the classpath: a no-op, since Flint's datatype support is built in and its modules
        /// are added by the generated configuration.
        Builder findAndAddModules()
        {
            return this;
        }

        /// Register `module_` (after its dependencies), unless a module with its registration id already is.
        final Builder addModule(JacksonModule module_)
        {
            foreach (dependency; module_.getDependencies())
                addModule(dependency);
            foreach (registered; config.modules)
                if ((cast(JacksonModule) registered).getRegistrationId() == module_.getRegistrationId())
                    return this;
            config.modules ~= module_;
            module_.setupModule(new ModuleContext(this, config));
            return this;
        }

        /// Register each of `modules` in order.
        final Builder addModules(JacksonModule[] modules...)
        {
            foreach (m; modules)
                addModule(m);
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
