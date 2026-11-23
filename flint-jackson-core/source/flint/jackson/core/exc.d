/*
 * Ported from Jackson (jackson-core) 3.1.8, https://github.com/FasterXML/jackson-core,
 * tag jackson-core-3.1.8: src/main/java/tools/jackson/core/exc/{StreamReadException,
 * StreamWriteException,InputCoercionException,UnexpectedEndOfInputException,
 * StreamConstraintsException}.java
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D (rulebook v2).
 */

/// Exceptions of the streaming layer.
module flint.jackson.core.exc;

import flint.jackson.core : JacksonException, JsonGenerator, JsonParser, JsonToken, TokenStreamLocation;

@safe:

/// Intermediate base class for all read-side streaming processing problems, including parsing and input value coercion problems.
class StreamReadException : JacksonException
{
    /// The parser that hit the problem, or null.
    protected JsonParser _processor;

    ///
    this(JsonParser p, string msg, TokenStreamLocation loc = null, Throwable rootCause = null,
            string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, loc, rootCause, file, line);
        _processor = p;
    }

    /// The parser that hit the problem.
    JsonParser processor() pure nothrow @nogc
    {
        return _processor;
    }
}

/// Intermediate base class for all write-side streaming processing problems, mostly content generation issues.
class StreamWriteException : JacksonException
{
    /// The generator that hit the problem, or null.
    protected JsonGenerator _processor;

    ///
    this(JsonGenerator g, string msg, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) nothrow
    {
        super(msg, null, cause, file, line);
        _processor = g;
    }

    /// The generator that hit the problem.
    JsonGenerator processor() pure nothrow @nogc
    {
        return _processor;
    }
}

/// Exception type for read-side problems that are not direct decoding ("parsing") problems, but rather result from failed attempts to convert specific Java value out of valid but incompatible input value.
class InputCoercionException : StreamReadException
{
    /// Input token that represents input value that failed to coerce.
    protected JsonToken _inputType;

    ///
    this(JsonParser p, string msg, JsonToken inputType, TokenStreamLocation loc = null,
            string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(p, msg, loc, null, file, line);
        _inputType = inputType;
    }

    /// Accessor for getting information about input type (in form of token, giving "shape" of input) for which coercion failed.
    JsonToken getInputType() const pure nothrow @nogc
    {
        return _inputType;
    }
}

/// Specialized `StreamReadException` that is thrown when end-of-input is reached unexpectedly, usually within token being decoded, but possibly within intervening non-token content.
class UnexpectedEndOfInputException : StreamReadException
{
    /// Type of token that was being decoded, if parser had enough information to recognize type.
    protected JsonToken _token;

    ///
    this(JsonParser p, JsonToken token, string msg, TokenStreamLocation loc = null,
            string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(p, msg, loc, null, file, line);
        _token = token;
    }

    /// Accessor for possibly available information about token that was being decoded while encountering end of input.
    JsonToken getTokenBeingDecoded() const pure nothrow @nogc
    {
        return _token;
    }
}

/// Exception type used to indicate violations of stream constraints (for example `StreamReadConstraints`) when reading or writing content.
class StreamConstraintsException : JacksonException
{
    ///
    this(string msg, TokenStreamLocation loc = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, loc, null, file, line);
    }
}
