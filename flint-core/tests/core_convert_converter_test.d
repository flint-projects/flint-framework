// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.core.convert.converter.ConverterTests` (v7.1.0): one `unittest` per
Java test method, each starting with a `// <JavaTestName>` comment.

Every test exercises the default method `Converter.andThen`, which `flint.core.convert.converter.Converter` does
not declare: all four are gated behind `FlintConverterAndThen`.

Adapted: Java's lambdas and method references (`String::length`, `Object::toString`) become delegates wrapped in a
`Converter` (R9); D's `int` stands for `Integer`.
+/
module flint.core.convert_converter_test;

import flint.core.convert.converter : Converter;

@safe:

/// A `Converter` around a delegate (Java's lambda implementing the functional interface).
private final class DelegateConverter(S, T) : Converter!(S, T)
{
    private T delegate(S) @safe fn;

    this(T delegate(S) @safe fn)
    {
        this.fn = fn;
    }

    T convert(S source)
    {
        return fn(source);
    }
}

/// `source -> fn(source)` as a `Converter!(S, T)`.
private Converter!(S, T) converter(S, T)(T delegate(S) @safe fn)
{
    return new DelegateConverter!(S, T)(fn);
}

/// `number -> number % 2`.
private Converter!(int, int) moduloTwo()
{
    return converter!(int, int)((int number) => number % 2);
}

/// `number -> number + 1`.
private Converter!(int, int) addOne()
{
    return converter!(int, int)((int number) => number + 1);
}

/// `String::length`.
private Converter!(string, int) length()
{
    return converter!(string, int)((string s) => cast(int) s.length);
}

/// `Object::toString` on an `Integer`.
private Converter!(int, string) toString()
{
    import flint.java.lang : valueOf;

    return converter!(int, string)((int i) => valueOf(i));
}

version (FlintConverterAndThen) // Converter has no default method andThen
{
    // andThenWhenGivenANullConverterThenThrowsException
    unittest
    {
        import flint.java.lang : IllegalArgumentException;
        import flint.util.test_support : expectThrows;

        expectThrows!IllegalArgumentException(() { moduloTwo.andThen!int(null); });
    }

    // andThenWhenGivenConverterThenComposesInOrder
    unittest
    {
        assert(moduloTwo.andThen(addOne).convert(13) == 2);
        assert(addOne.andThen(moduloTwo).convert(13) == 0);
    }

    // andThenCanConvertFromDifferentSourceType
    unittest
    {
        assert(length.andThen(moduloTwo).convert("example") == 1);
        assert(length.andThen(addOne).convert("example") == 8);
    }

    // andThenCanConvertToDifferentTargetType
    unittest
    {
        assert(length.andThen(toString).convert("example") == "7");
        assert(toString.andThen(length).convert(1_000) == 4);
    }
}
