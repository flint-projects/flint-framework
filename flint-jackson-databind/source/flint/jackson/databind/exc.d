/*
 * Ported from Jackson (jackson-databind) 3.1.8, https://github.com/FasterXML/jackson-databind,
 * tag jackson-databind-3.1.8: src/main/java/tools/jackson/databind/{DatabindException.java,
 * exc/MismatchedInputException.java, exc/InvalidFormatException.java,
 * exc/UnrecognizedPropertyException.java, exc/InvalidDefinitionException.java,
 * exc/ValueInstantiationException.java}
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D (rulebook v2). Java types are
 * named by their Flint type names; a path is a list of references.
 */

/// The exceptions of the data-binding layer.
module flint.jackson.databind.exc;

import flint.jackson.core : JacksonException, TokenStreamLocation;

@safe:

/// One step of a reference path: a property name or an index.
struct Reference
{
    /// The property name, or null for an array index.
    string propertyName;
    /// The index, or -1 for a property.
    int index = -1;
    /// The Flint type name of the value holding the property.
    string from;

    /// `Type["name"]` or `Type[3]`, as Jackson prints a reference.
    string description() const pure
    {
        import flint.engine.aot.text : decimal;

        return (from.length ? from : "UNKNOWN") ~ (propertyName !is null
                ? "[\"" ~ propertyName ~ "\"]" : "[" ~ decimal(cast(long) index) ~ "]");
    }
}

/// Intermediate base class for all databind level processing problems, as distinct from stream-level problems or I/O issues below.
class DatabindException : JacksonException
{
    /// The path from the root value to the problem, outermost first.
    protected Reference[] _path;

    ///
    this(string msg, TokenStreamLocation loc = null, Throwable cause = null, string file = __FILE__,
            size_t line = __LINE__) pure nothrow
    {
        super(msg, loc, cause, file, line);
    }

    /// The path of references from the root to the problem.
    const(Reference)[] getPath() const pure nothrow @nogc
    {
        return _path;
    }

    /// Prepend a reference as the exception travels outwards; returns this exception.
    DatabindException prependPath(Reference reference) pure nothrow
    {
        _path = reference ~ _path;
        return this;
    }

    /// The path as Jackson prints it: `(through reference chain: A["b"]->B[0])`.
    string pathDescription() const pure
    {
        string text;
        foreach (i, r; _path)
            text ~= (i ? "->" : "") ~ r.description();
        return text;
    }

    override string toString() const
    {
        return _path.length ? msg ~ " (through reference chain: " ~ pathDescription() ~ ")" : msg;
    }
}

/// General exception type used as the base class for all `JsonMappingException`s that are due to input not mapping to target definition.
class MismatchedInputException : DatabindException
{
    /// The Flint type name of the target.
    protected string _targetType;

    ///
    this(string msg, string targetType = null, TokenStreamLocation loc = null,
            string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, loc, null, file, line);
        _targetType = targetType;
    }

    /// The Flint type name of the target.
    string getTargetType() const pure nothrow @nogc
    {
        return _targetType;
    }
}

/// Specialized sub-class of `MismatchedInputException` that is used when the underlying problem appears to be that of bad formatting of a value to deserialize.
class InvalidFormatException : MismatchedInputException
{
    /// The value that failed, as text.
    protected string _value;

    ///
    this(string msg, string value, string targetType, TokenStreamLocation loc = null,
            string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, targetType, loc, file, line);
        _value = value;
    }

    /// The value that failed, as text.
    string getValue() const pure nothrow @nogc
    {
        return _value;
    }
}

/// Specialized `MismatchedInputException` sub-class used to indicate case of a property that could not be mapped (unknown property).
class UnrecognizedPropertyException : MismatchedInputException
{
    /// The unknown property's name.
    protected string _propertyName;
    /// The properties the type does accept.
    protected string[] _propertyIds;

    ///
    this(string msg, string propertyName, string targetType, string[] known,
            TokenStreamLocation loc = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, targetType, loc, file, line);
        _propertyName = propertyName;
        _propertyIds = known;
    }

    /// The unknown property's name.
    string getPropertyName() const pure nothrow @nogc
    {
        return _propertyName;
    }

    /// The properties the type accepts.
    const(string)[] getKnownPropertyIds() const pure nothrow @nogc
    {
        return _propertyIds;
    }
}

/// Intermediate exception type used as the base class for all exceptions that are due to problems with target type definition.
class InvalidDefinitionException : DatabindException
{
    /// The Flint type name with the problem.
    protected string _type;

    ///
    this(string msg, string type, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, null, null, file, line);
        _type = type;
    }

    /// The Flint type name with the problem.
    string getType() const pure nothrow @nogc
    {
        return _type;
    }
}

/// Exception type used for generic failures during processing by value instantiators (creator methods, constructors).
class ValueInstantiationException : DatabindException
{
    /// The Flint type name that failed to instantiate.
    protected string _type;

    ///
    this(string msg, string type, Throwable cause, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, null, cause, file, line);
        _type = type;
    }

    /// The Flint type name that failed to instantiate.
    string getType() const pure nothrow @nogc
    {
        return _type;
    }
}
