/*
 * Ported from Jackson (jackson-core) 3.1.8, https://github.com/FasterXML/jackson-core,
 * tag jackson-core-3.1.8: src/main/java/tools/jackson/core/util/{DefaultPrettyPrinter,
 * DefaultIndenter,Separators,MinimalPrettyPrinter,ByteArrayBuilder}.java
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D (rulebook v2). The shared
 * singleton indenters become fresh instances, since they hold no state and
 * framework modules keep no mutable module-level state (ADR-030 section 4).
 */

/// Pretty printers, separators and byte buffers of the streaming layer.
module flint.jackson.core.util;

import flint.jackson.core : JsonGenerator, PrettyPrinter;

@safe:

version (Windows)
    private enum string systemLinefeed = "\r\n";
else
    private enum string systemLinefeed = "\n";

/// Value class used with some `PrettyPrinter` implementations.
final class Separators
{
    /// Constant that specifies default "root-level" separator to use between root values: a single space character.
    enum string DEFAULT_ROOT_VALUE_SEPARATOR = " ";
    /// String to use in empty Object to separate start and end markers: `{ }`.
    enum string DEFAULT_OBJECT_EMPTY_SEPARATOR = " ";
    /// String to use in empty Array to separate start and end markers: `[ ]`.
    enum string DEFAULT_ARRAY_EMPTY_SEPARATOR = " ";

    /// Define the spacing around elements like commas and colons.
    enum Spacing
    {
        /// No spaces around the element.
        NONE,
        /// A space before the element.
        BEFORE,
        /// A space after the element.
        AFTER,
        /// Spaces before and after the element.
        BOTH,
    }

    /// Apply the spacing to a one-character separator.
    static string apply(Spacing spacing, char separator) pure nothrow
    {
        final switch (spacing)
        {
        case Spacing.NONE:
            return [separator];
        case Spacing.BEFORE:
            return " " ~ separator;
        case Spacing.AFTER:
            return separator ~ " ";
        case Spacing.BOTH:
            return " " ~ separator ~ " ";
        }
    }

    private string rootSeparator;
    private char objectNameValueSeparator;
    private Spacing objectNameValueSpacing;
    private char objectEntrySeparator;
    private Spacing objectEntrySpacing;
    private string objectEmptySeparator;
    private char arrayElementSeparator;
    private Spacing arrayElementSpacing;
    private string arrayEmptySeparator;

    /// Constructor for creating an instance with default settings for all separators.
    this() pure nothrow
    {
        this(':', ',', ',');
    }

    /// Constructor for creating an instance with the given separator characters and default spacing.
    this(char objectNameValueSeparator, char objectEntrySeparator, char arrayElementSeparator) pure nothrow
    {
        this(DEFAULT_ROOT_VALUE_SEPARATOR, objectNameValueSeparator, Spacing.BOTH, objectEntrySeparator, Spacing.NONE,
                DEFAULT_OBJECT_EMPTY_SEPARATOR, arrayElementSeparator, Spacing.NONE, DEFAULT_ARRAY_EMPTY_SEPARATOR);
    }

    /// Full constructor.
    this(string rootSeparator, char objectNameValueSeparator, Spacing objectNameValueSpacing,
            char objectEntrySeparator, Spacing objectEntrySpacing,
            string objectEmptySeparator, char arrayElementSeparator, Spacing arrayElementSpacing,
            string arrayEmptySeparator) pure nothrow
    {
        this.rootSeparator = rootSeparator;
        this.objectNameValueSeparator = objectNameValueSeparator;
        this.objectNameValueSpacing = objectNameValueSpacing;
        this.objectEntrySeparator = objectEntrySeparator;
        this.objectEntrySpacing = objectEntrySpacing;
        this.objectEmptySeparator = objectEmptySeparator;
        this.arrayElementSeparator = arrayElementSeparator;
        this.arrayElementSpacing = arrayElementSpacing;
        this.arrayEmptySeparator = arrayEmptySeparator;
    }

    /// Factory method for creating an instance with default settings for all separators.
    static Separators createDefaultInstance() pure nothrow
    {
        return new Separators();
    }

    /// A copy with another root separator (null for none).
    Separators withRootSeparator(string sep) const pure nothrow
    {
        return new Separators(sep, objectNameValueSeparator, objectNameValueSpacing, objectEntrySeparator,
                objectEntrySpacing, objectEmptySeparator, arrayElementSeparator,
                arrayElementSpacing, arrayEmptySeparator);
    }

    /// A copy with another spacing around the name-value separator.
    Separators withObjectNameValueSpacing(Spacing spacing) const pure nothrow
    {
        return new Separators(rootSeparator, objectNameValueSeparator, spacing, objectEntrySeparator,
                objectEntrySpacing, objectEmptySeparator, arrayElementSeparator,
                arrayElementSpacing, arrayEmptySeparator);
    }

    /// A copy with another spacing around the object entry separator.
    Separators withObjectEntrySpacing(Spacing spacing) const pure nothrow
    {
        return new Separators(rootSeparator, objectNameValueSeparator, objectNameValueSpacing, objectEntrySeparator,
                spacing, objectEmptySeparator, arrayElementSeparator, arrayElementSpacing, arrayEmptySeparator);
    }

    /// A copy with another spacing around the array element separator.
    Separators withArrayElementSpacing(Spacing spacing) const pure nothrow
    {
        return new Separators(rootSeparator, objectNameValueSeparator, objectNameValueSpacing, objectEntrySeparator,
                objectEntrySpacing, objectEmptySeparator, arrayElementSeparator, spacing, arrayEmptySeparator);
    }

    ///
    string getRootSeparator() const pure nothrow @nogc
    {
        return rootSeparator;
    }

    ///
    char getObjectNameValueSeparator() const pure nothrow @nogc
    {
        return objectNameValueSeparator;
    }

    ///
    Spacing getObjectNameValueSpacing() const pure nothrow @nogc
    {
        return objectNameValueSpacing;
    }

    ///
    char getObjectEntrySeparator() const pure nothrow @nogc
    {
        return objectEntrySeparator;
    }

    ///
    Spacing getObjectEntrySpacing() const pure nothrow @nogc
    {
        return objectEntrySpacing;
    }

    ///
    string getObjectEmptySeparator() const pure nothrow @nogc
    {
        return objectEmptySeparator;
    }

    ///
    char getArrayElementSeparator() const pure nothrow @nogc
    {
        return arrayElementSeparator;
    }

    ///
    Spacing getArrayElementSpacing() const pure nothrow @nogc
    {
        return arrayElementSpacing;
    }

    ///
    string getArrayEmptySeparator() const pure nothrow @nogc
    {
        return arrayEmptySeparator;
    }
}

/**
 * Default `PrettyPrinter` implementation that uses 2-space indentation with
 * platform-default linefeeds. Usually this class is not instantiated directly,
 * but instead method `ObjectMapper.writerWithDefaultPrettyPrinter` or
 * `SerializationFeature.INDENT_OUTPUT` is used, which will use an instance of
 * this class for operation.
 */
class DefaultPrettyPrinter : PrettyPrinter
{
    /// Interface that defines objects that can produce indentation used to separate object entries and array values.
    interface Indenter
    {
        /// Write the indentation for nesting `level`.
        void writeIndentation(JsonGenerator g, int level);
        /// Whether indenter is known to be inline (no linefeeds).
        bool isInline();
    }

    /// Dummy implementation that adds no indentation whatsoever.
    static class NopIndenter : Indenter
    {
        ///
        static NopIndenter instance() pure nothrow
        {
            return new NopIndenter();
        }

        /// Write the indentation for nesting `level`.
        void writeIndentation(JsonGenerator, int)
        {
        }

        /// Whether indenter is known to be inline (no linefeeds).
        bool isInline()
        {
            return true;
        }
    }

    /// This is a very simple indenter that only adds a single space for indentation. It is used as the default indenter for array values.
    static class FixedSpaceIndenter : NopIndenter
    {
        ///
        static FixedSpaceIndenter instance() pure nothrow
        {
            return new FixedSpaceIndenter();
        }

        override void writeIndentation(JsonGenerator g, int level)
        {
            g.writeRaw(' ');
        }

        override bool isInline()
        {
            return true;
        }
    }

    /// Default linefeed-based indenter, used by `DefaultPrettyPrinter` (unless overridden). Uses system-specific linefeeds and 2 spaces for indentation per level.
    static class DefaultIndenter : Indenter
    {
        /// The system linefeed: "\n" on POSIX, "\r\n" on Windows, as `System.lineSeparator()`.
        enum string SYS_LF = systemLinefeed;

        ///
        static DefaultIndenter SYSTEM_LINEFEED_INSTANCE() pure nothrow
        {
            return new DefaultIndenter("  ", SYS_LF);
        }

        private string indent;
        private string eol;

        /// Create an indenter that uses `indent` per level and `eol` before each indentation.
        this(string indent, string eol) pure nothrow @nogc
        {
            this.indent = indent;
            this.eol = eol;
        }

        /// Write the indentation for nesting `level`.
        void writeIndentation(JsonGenerator g, int level)
        {
            g.writeRaw(eol);
            foreach (_; 0 .. level)
                g.writeRaw(indent);
        }

        /// Whether indenter is known to be inline (no linefeeds).
        bool isInline()
        {
            return false;
        }

        ///
        string getIndent() const pure nothrow @nogc
        {
            return indent;
        }

        ///
        string getEol() const pure nothrow @nogc
        {
            return eol;
        }
    }

    /// The indenter for array values; by default a single space.
    protected Indenter _arrayIndenter;
    /// The indenter for object entries; by default a linefeed and two spaces per level.
    protected Indenter _objectIndenter;
    /// String printed between root-level values, if any.
    protected string _rootValueSeparator;
    /// Number of open levels of nesting. Used to determine amount of indentation to use.
    protected int _nesting;
    /// The separators in use.
    protected Separators _separators;
    /// Separator between property name and value, with its spacing.
    protected string _objectNameValueSeparator;
    /// Separator between object entries, with its spacing.
    protected string _objectEntrySeparator;
    /// Separator in an empty object.
    protected string _objectEmptySeparator;
    /// Separator between array elements, with its spacing.
    protected string _arrayElementSeparator;
    /// Separator in an empty array.
    protected string _arrayEmptySeparator;

    /// Default constructor for "default" pretty printer.
    this()
    {
        this(Separators.createDefaultInstance());
    }

    /// Create a pretty printer with the given separators.
    this(Separators separators)
    {
        _arrayIndenter = FixedSpaceIndenter.instance();
        _objectIndenter = DefaultIndenter.SYSTEM_LINEFEED_INSTANCE();
        setSeparators(separators);
    }

    /// Copy constructor.
    this(DefaultPrettyPrinter base)
    {
        this(base, base._separators);
    }

    /// Copy constructor with other separators.
    this(DefaultPrettyPrinter base, Separators separators)
    {
        _arrayIndenter = base._arrayIndenter;
        _objectIndenter = base._objectIndenter;
        _nesting = base._nesting;
        setSeparators(separators);
    }

    private void setSeparators(Separators separators)
    {
        _separators = separators;
        _rootValueSeparator = separators.getRootSeparator();
        _objectNameValueSeparator = Separators.apply(separators.getObjectNameValueSpacing(),
                separators.getObjectNameValueSeparator());
        _objectEntrySeparator = Separators.apply(separators.getObjectEntrySpacing(),
                separators.getObjectEntrySeparator());
        _objectEmptySeparator = separators.getObjectEmptySeparator();
        _arrayElementSeparator = Separators.apply(separators.getArrayElementSpacing(),
                separators.getArrayElementSeparator());
        _arrayEmptySeparator = separators.getArrayEmptySeparator();
    }

    /// Replace the array indenter; null selects no indentation.
    void indentArraysWith(Indenter i)
    {
        _arrayIndenter = i is null ? NopIndenter.instance() : i;
    }

    /// Replace the object indenter; null selects no indentation.
    void indentObjectsWith(Indenter i)
    {
        _objectIndenter = i is null ? NopIndenter.instance() : i;
    }

    /// A copy with another array indenter.
    DefaultPrettyPrinter withArrayIndenter(Indenter i)
    {
        auto pp = new DefaultPrettyPrinter(this);
        pp.indentArraysWith(i);
        return pp;
    }

    /// A copy with another object indenter.
    DefaultPrettyPrinter withObjectIndenter(Indenter i)
    {
        auto pp = new DefaultPrettyPrinter(this);
        pp.indentObjectsWith(i);
        return pp;
    }

    /// A copy with other separators.
    DefaultPrettyPrinter withSeparators(Separators separators)
    {
        return new DefaultPrettyPrinter(this, separators);
    }

    /// A fresh instance with the same configuration and no nesting, for one generator.
    DefaultPrettyPrinter createInstance()
    {
        return new DefaultPrettyPrinter(this);
    }

    /// Called after a root-level value has been completely output, and before another value is to be output.
    void writeRootValueSeparator(JsonGenerator g)
    {
        if (_rootValueSeparator !is null)
            g.writeRaw(_rootValueSeparator);
    }

    /// Called when an Object value is to be output, before any properties are output.
    void writeStartObject(JsonGenerator g)
    {
        g.writeRaw('{');
        if (!_objectIndenter.isInline())
            ++_nesting;
    }

    /// Called after object start marker has been output, and right before the Property Name of the first property.
    void beforeObjectEntries(JsonGenerator g)
    {
        _objectIndenter.writeIndentation(g, _nesting);
    }

    /// Called after an Object property name has been output, but before the value is output.
    void writeObjectNameValueSeparator(JsonGenerator g)
    {
        g.writeRaw(_objectNameValueSeparator);
    }

    /// Called after an Object entry (property name + value) has been completely output, and before another entry.
    void writeObjectEntrySeparator(JsonGenerator g)
    {
        g.writeRaw(_objectEntrySeparator);
        _objectIndenter.writeIndentation(g, _nesting);
    }

    /// Called after an Object value has been completely output (minus closing curly bracket).
    void writeEndObject(JsonGenerator g, int nrOfEntries)
    {
        if (!_objectIndenter.isInline())
            --_nesting;
        if (nrOfEntries > 0)
            _objectIndenter.writeIndentation(g, _nesting);
        else
            g.writeRaw(_objectEmptySeparator);
        g.writeRaw('}');
    }

    /// Called when an Array value is to be output, before any member/child values are output.
    void writeStartArray(JsonGenerator g)
    {
        if (!_arrayIndenter.isInline())
            ++_nesting;
        g.writeRaw('[');
    }

    /// Called after array start marker has been output, and right before the first value is to be output.
    void beforeArrayValues(JsonGenerator g)
    {
        _arrayIndenter.writeIndentation(g, _nesting);
    }

    /// Called after an array value has been completely output, and before another value is to be output.
    void writeArrayValueSeparator(JsonGenerator g)
    {
        g.writeRaw(_arrayElementSeparator);
        _arrayIndenter.writeIndentation(g, _nesting);
    }

    /// Called after an Array value has been completely output (minus closing bracket).
    void writeEndArray(JsonGenerator g, int nrOfValues)
    {
        if (!_arrayIndenter.isInline())
            --_nesting;
        if (nrOfValues > 0)
            _arrayIndenter.writeIndentation(g, _nesting);
        else
            g.writeRaw(_arrayEmptySeparator);
        g.writeRaw(']');
    }
}

/**
 * `PrettyPrinter` implementation that adds no indentation, just implements
 * everything necessary for value output to work as expected, and provide
 * simpler extension points to allow for creating simple custom
 * implementations that add specific decoration or overrides.
 */
class MinimalPrettyPrinter : PrettyPrinter
{
    private string _rootValueSeparator;

    /// Root values are separated by a single space, as Jackson's default.
    this() pure nothrow @nogc
    {
        this(Separators.DEFAULT_ROOT_VALUE_SEPARATOR);
    }

    /// Root values are separated by `rootValueSeparator` (null for none).
    this(string rootValueSeparator) pure nothrow @nogc
    {
        _rootValueSeparator = rootValueSeparator;
    }

    /// Called after a root-level value has been completely output, and before another value is to be output.
    void writeRootValueSeparator(JsonGenerator g)
    {
        if (_rootValueSeparator !is null)
            g.writeRaw(_rootValueSeparator);
    }

    /// Called when an Object value is to be output, before any properties are output.
    void writeStartObject(JsonGenerator g)
    {
        g.writeRaw('{');
    }

    /// Called after object start marker has been output, and right before the Property Name of the first property.
    void beforeObjectEntries(JsonGenerator)
    {
    }

    /// Called after an Object property name has been output, but before the value is output.
    void writeObjectNameValueSeparator(JsonGenerator g)
    {
        g.writeRaw(':');
    }

    /// Called after an Object entry (property name + value) has been completely output, and before another entry.
    void writeObjectEntrySeparator(JsonGenerator g)
    {
        g.writeRaw(',');
    }

    /// Called after an Object value has been completely output (minus closing curly bracket).
    void writeEndObject(JsonGenerator g, int)
    {
        g.writeRaw('}');
    }

    /// Called when an Array value is to be output, before any member/child values are output.
    void writeStartArray(JsonGenerator g)
    {
        g.writeRaw('[');
    }

    /// Called after array start marker has been output, and right before the first value is to be output.
    void beforeArrayValues(JsonGenerator)
    {
    }

    /// Called after an array value has been completely output, and before another value is to be output.
    void writeArrayValueSeparator(JsonGenerator g)
    {
        g.writeRaw(',');
    }

    /// Called after an Array value has been completely output (minus closing bracket).
    void writeEndArray(JsonGenerator g, int)
    {
        g.writeRaw(']');
    }
}

/**
 * Helper class that is similar to `java.io.ByteArrayOutputStream` in usage, but
 * more geared to Jackson use cases internally. Generators write their output
 * here for `writeValueAsBytes` and `writeValueAsString`.
 */
final class ByteArrayBuilder
{
    private ubyte[] _buffer;
    private size_t _length;

    ///
    this(size_t firstBlockSize = 500) pure nothrow
    {
        _buffer = new ubyte[firstBlockSize < 16 ? 16 : firstBlockSize];
    }

    /// Append bytes, growing the buffer geometrically.
    void write(scope const(ubyte)[] bytes) pure nothrow
    {
        if (_length + bytes.length > _buffer.length)
        {
            size_t capacity = _buffer.length * 2;
            while (capacity < _length + bytes.length)
                capacity *= 2;
            auto grown = new ubyte[capacity];
            grown[0 .. _length] = _buffer[0 .. _length];
            _buffer = grown;
        }
        _buffer[_length .. _length + bytes.length] = bytes;
        _length += bytes.length;
    }

    /// Append one byte.
    void append(int i) pure nothrow
    {
        ubyte[1] one = [cast(ubyte) i];
        write(one[]);
    }

    /// Number of bytes written.
    int size() const pure nothrow @nogc
    {
        return cast(int) _length;
    }

    /// Forget the contents but keep the buffer.
    void reset() pure nothrow @nogc
    {
        _length = 0;
    }

    /// A copy of the bytes written.
    ubyte[] toByteArray() const pure nothrow
    {
        return _buffer[0 .. _length].dup;
    }

    /// The bytes written as a UTF-8 String (a copy).
    string toUtf8String() const pure nothrow
    {
        return (cast(const(char)[]) _buffer[0 .. _length]).idup;
    }
}
