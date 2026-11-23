// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.core.MethodParameterTests` (v7.1.0): one `unittest` per Java test
method, each starting with a `// <JavaTestName>` comment.

Skipped Java tests (4), with reasons:
- annotatedConstructorParameterInInnerClass, genericConstructorParameterInInnerClass (SPR-16652, SPR-16734): they
  test the synthetic enclosing-instance parameter javac adds to an inner class's constructor; a D nested class's
  constructor has no such parameter.
- multipleResolveParameterTypeCalls, withContainingClassReturnsNewInstance: they resolve the erased return type of
  `ArrayList.get` (`Object`) against a subclass (`String`, `Integer`); D generics are templates, so
  `ArrayList!Object.get` returns `Object` whatever the containing class.

Adapted: Flint has no `java.lang.reflect.Method`. `new MethodParameter(method, index)` (and `forExecutable` for a
constructor) is `methodParameter!fn(index)`, the `ArgumentSpec` Flint AOT writes for parameter `index` of the D
function `fn` (its name, declared type and merged annotations; -1 for the return type). The test class's own
methods are module functions. Flint has neither JSpecify's nor Spring's `@Nullable`; Spring's nullness check
matches any annotation whose simple name is `Nullable`, so both stand-ins are Jakarta's `@Nullable`. Java's
`hashCode` is `toHash`. Cases that need unported features, or where the port behaves differently, wait behind
version gates.
+/
module flint.core.method_parameter_test;

import flint.core : MethodParameter;
import flint.engine.aot.descriptor : mergedAnnotations;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec;
import flint.engine.aot.name : typeNameOf;
import flint.jakarta.annotation : Nullable;

@safe:

private struct Param
{
}

private int method(string str, long lng)
{
    return 42;
}

@Nullable private string jspecifyNullableMethod(@Nullable string nullableParameter, string nonNullParameter)
{
    return nullableParameter;
}

@Nullable private string springNullableMethod(@Nullable string nullableParameter, string nonNullParameter)
{
    return nullableParameter;
}

private final class NestedClass
{
    this(@Param string s)
    {
    }
}

/// `new MethodParameter(method, index)`: the `ArgumentSpec` Flint AOT writes for parameter `index` of `fn` (-1
/// for its return type).
private MethodParameter methodParameter(alias fn)(int index)
{
    import std.traits : ParameterIdentifierTuple, ReturnType;

    ArgumentSpec spec;
    spec.kind = ArgumentKind.byType;
    spec.required = true;
    if (index < 0)
        spec.type = typeNameOf!(ReturnType!fn);
    static if (is(typeof(fn) Params == __parameters))
    {
        static foreach (i; 0 .. Params.length)
        {
            if (i == index)
            {
                spec.type = typeNameOf!(Params[i]);
                spec.name = ParameterIdentifierTuple!fn[i];
                spec.annotations = mergedAnnotations!(__traits(getAttributes, Params[i .. i + 1]))();
            }
        }
    }
    return new MethodParameter(spec, index, __traits(identifier, fn));
}

/// The `@BeforeEach` fields.
private struct Fixture
{
    MethodParameter stringParameter;
    MethodParameter longParameter;
    MethodParameter intReturnType;
    MethodParameter jspecifyNullableParameter;
    MethodParameter jspecifyNonNullParameter;
    MethodParameter springNullableParameter;
    MethodParameter springNonNullParameter;
}

private Fixture setup()
{
    Fixture f;
    f.stringParameter = methodParameter!method(0);
    f.longParameter = methodParameter!method(1);
    f.intReturnType = methodParameter!method(-1);
    f.jspecifyNullableParameter = methodParameter!jspecifyNullableMethod(0);
    f.jspecifyNonNullParameter = methodParameter!jspecifyNullableMethod(1);
    f.springNullableParameter = methodParameter!springNullableMethod(0);
    f.springNonNullParameter = methodParameter!springNullableMethod(1);
    return f;
}

// MethodParameter keeps Object's identity opEquals and toHash: two parameters for the same method and index are
// not equal and hash differently, where Spring compares executable, index, containing class and nesting.
version (FlintMethodParameterEquality)
{
    @system unittest  // class `==` (Object.opEquals) is @system
    {
        // equals
        auto f = setup();
        assert(f.stringParameter == f.stringParameter);
        assert(f.longParameter == f.longParameter);
        assert(f.intReturnType == f.intReturnType);

        assert(f.stringParameter != f.longParameter);
        assert(f.stringParameter != f.intReturnType);
        assert(f.longParameter != f.stringParameter);
        assert(f.longParameter != f.intReturnType);
        assert(f.intReturnType != f.stringParameter);
        assert(f.intReturnType != f.longParameter);

        auto methodParameter = methodParameter!method(0);
        assert(methodParameter == f.stringParameter);
        assert(f.stringParameter == methodParameter);
        assert(methodParameter != f.longParameter);
        assert(f.longParameter != methodParameter);
    }

    unittest
    {
        // hashCodeBehavior
        auto f = setup();
        assert(f.stringParameter.toHash() == f.stringParameter.toHash());
        assert(f.longParameter.toHash() == f.longParameter.toHash());
        assert(f.intReturnType.toHash() == f.intReturnType.toHash());

        auto methodParameter = methodParameter!method(0);
        assert(methodParameter.toHash() == f.stringParameter.toHash());
        assert(methodParameter.toHash() != f.longParameter.toHash());
    }
}

// MethodParameter is built from an AOT ArgumentSpec: it has no factories over a method or constructor
// (forExecutable, forParameter, forMethodOrConstructor) and no index validation against one.
version (FlintMethodParameterExecutable)
{
    @system unittest  // class `==` (Object.opEquals) is @system
    {
        // factoryMethods
        import flint.engine.aot.descriptor : methodDescriptorOf;

        auto f = setup();
        const method = methodDescriptorOf!method;
        assert(MethodParameter.forMethodOrConstructor(method, 0) == f.stringParameter);
        assert(MethodParameter.forMethodOrConstructor(method, 1) == f.longParameter);

        assert(MethodParameter.forExecutable(method, 0) == f.stringParameter);
        assert(MethodParameter.forExecutable(method, 1) == f.longParameter);

        assert(MethodParameter.forParameter(method.parameters[0]) == f.stringParameter);
        assert(MethodParameter.forParameter(method.parameters[1]) == f.longParameter);
    }

    unittest
    {
        // indexValidation
        import flint.engine.aot.descriptor : methodDescriptorOf;
        import flint.java.lang : IllegalArgumentException;
        import flint.util.test_support : expectThrows;

        expectThrows!IllegalArgumentException(() {
            new MethodParameter(methodDescriptorOf!method, 2);
        });
    }
}

unittest
{
    // annotatedConstructorParameterInStaticNestedClass
    auto methodParameter = methodParameter!(NestedClass.__ctor)(0);
    assert(methodParameter.getParameterType() == typeNameOf!string);
    assert(methodParameter.hasParameterAnnotation!Param, "Failed to find @Param annotation");
}

// MethodParameter has no nesting levels, type indexes or containing class (nested, withTypeIndex,
// withContainingClass, getTypeIndexForCurrentLevel, decreaseNestingLevel).
version (FlintMethodParameterNesting)
{
    import flint.java.util : ArrayList;

    private class StringList : ArrayList!string
    {
    }

    private class IntegerList : ArrayList!int
    {
    }

    @system unittest  // class `==` (Object.opEquals) is @system
    {
        // equalsAndHashCodeConsidersContainingClass
        auto m1 = methodParameter!(ArrayList!Object.get)(-1);
        auto m2 = methodParameter!(ArrayList!Object.get)(-1);
        auto m3 = methodParameter!(ArrayList!Object.get)(-1).nested();
        assert(m1 == m2 && m1 != m3);
        assert(m1.toHash() == m2.toHash());
    }

    @system unittest  // class `==` (Object.opEquals) is @system
    {
        // equalsAndHashCodeConsidersNesting
        auto m1 = methodParameter!(ArrayList!Object.get)(-1).withContainingClass!StringList();
        auto m2 = methodParameter!(ArrayList!Object.get)(-1).withContainingClass!StringList();
        auto m3 = methodParameter!(ArrayList!Object.get)(-1).withContainingClass!IntegerList();
        auto m4 = methodParameter!(ArrayList!Object.get)(-1);
        assert(m1 == m2 && m1 != m3 && m1 != m4);
        assert(m1.toHash() == m2.toHash());
    }

    unittest
    {
        // withTypeIndexReturnsNewInstance
        auto m1 = methodParameter!(ArrayList!Object.get)(-1);
        auto m2 = m1.withTypeIndex(2);
        auto m3 = m1.withTypeIndex(3);
        assert(m1 !is m2 && m1 !is m3);
        assert(!m1.getTypeIndexForCurrentLevel().isPresent());
        assert(m2.getTypeIndexForCurrentLevel().get() == 2);
        assert(m3.getTypeIndexForCurrentLevel().get() == 3);
    }

    unittest
    {
        // mutatingNestingLevelShouldNotChangeNewInstance
        auto m1 = methodParameter!(ArrayList!Object.get)(-1);
        auto m2 = m1.withTypeIndex(2);
        assert(m2.getTypeIndexForCurrentLevel().get() == 2);
        m1.setTypeIndexForCurrentLevel(1);
        m2.decreaseNestingLevel();
        assert(!m2.getTypeIndexForCurrentLevel().isPresent());
    }

    unittest
    {
        // nestedWithTypeIndexReturnsNewInstance
        auto m1 = methodParameter!(ArrayList!Object.get)(-1);
        auto m2 = m1.nested(2);
        auto m3 = m1.nested(3);
        assert(m1 !is m2 && m1 !is m3);
        assert(!m1.getTypeIndexForCurrentLevel().isPresent());
        assert(m2.getTypeIndexForCurrentLevel().get() == 2);
        assert(m3.getTypeIndexForCurrentLevel().get() == 3);
    }
}

unittest
{
    // parameterNames
    auto f = setup();
    assert(f.stringParameter.getParameterName() == "str");
    assert(f.longParameter.getParameterName() == "lng");
}

// MethodParameter.isOptional only recognizes Optional!T: a parameter annotated @Nullable is not optional.
version (FlintMethodParameterNullable)
{
    unittest
    {
        // jspecifyNullableParameter
        assert(setup().jspecifyNullableParameter.isOptional());
    }
}

unittest
{
    // jspecifyNonNullParameter
    assert(!setup().jspecifyNonNullParameter.isOptional());
}

version (FlintMethodParameterNullable)
{
    unittest
    {
        // springNullableParameter
        assert(setup().springNullableParameter.isOptional());
    }
}

unittest
{
    // springNonNullParameter
    assert(!setup().springNonNullParameter.isOptional());
}
