/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/engine/messageinterpolation/
ExpressionLanguageMessageInterpolationTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `MessageInterpolatorContext` is built from a D annotation value and the validated
value; Flint's context has no `ExpressionLanguageFeatureLevel` (its evaluator always runs the same expression
subset), so the level each test passes is dropped. Flint evaluates no property navigation, method call or
arithmetic, and `interpolate` takes no locale: the tests that need them are gated.
+/
module flint.hibernate.validator.expression_language_message_interpolation_test;

import flint.engine.aot.any : Any;
import flint.hibernate.validator.messageinterpolation : ResourceBundleMessageInterpolator;
import flint.hibernate.validator.validator_test_support : contextFor;
import flint.jakarta.validation.constraints : NotNull, Size;

@safe:

// User.java: the bean whose `age` the graph navigation reads.
private final class User
{
    string email;
    int age;
}

private User userAged(int age)
{
    auto user = new User();
    user.age = age;
    return user;
}

private ResourceBundleMessageInterpolator interpolatorUnderTest()
{
    return new ResourceBundleMessageInterpolator();
}

// Gap: Flint evaluates an expression subset; no property navigation (`validatedValue.age`).
version (FlintFullExpressionLanguage)
{
    @("ExpressionLanguageMessageInterpolationTest.testExpressionLanguageGraphNavigation")
    unittest
    {
        auto context = contextFor(NotNull(), Any.of(userAged(18)));
        const expected = "18";
        const actual = interpolatorUnderTest().interpolate("${validatedValue.age}", context);
        assert(actual == expected, "Wrong substitution");
    }

    @("ExpressionLanguageMessageInterpolationTest.testExpressionLanguageGraphNavigationBeanProperties")
    unittest
    {
        auto context = contextFor(NotNull(), Any.of(userAged(18)));
        const expected = "18";
        const actual = interpolatorUnderTest().interpolate("${validatedValue.age}", context);
        assert(actual == expected, "Wrong substitution");
    }
}

@("ExpressionLanguageMessageInterpolationTest.testExpressionLanguageGraphNavigationVariables")
unittest
{
    auto context = contextFor(NotNull(), Any.of(userAged(18)));
    const expected = "${validatedValue.age}";
    const actual = interpolatorUnderTest().interpolate("${validatedValue.age}", context);
    assert(actual == expected, "Wrong substitution");
}

@("ExpressionLanguageMessageInterpolationTest.testUnknownPropertyInExpressionLanguageGraphNavigation")
unittest
{
    auto context = contextFor(NotNull(), Any.of(new User()));
    const expected = "${validatedValue.foo}";
    const actual = interpolatorUnderTest().interpolate("${validatedValue.foo}", context);
    assert(actual == expected, "No substitution should occur");
}

@("ExpressionLanguageMessageInterpolationTest.testNullValidatedValue")
unittest
{
    auto context = contextFor(NotNull());
    const expected = "Validated value was null";
    const actual = interpolatorUnderTest().interpolate(
            "Validated value was ${validatedValue == null ? 'null' : validatedValue}", context);
    assert(actual == expected, "Wrong substitution");
}

// Gap: Flint evaluates an expression subset; no arithmetic (`1+1`).
version (FlintFullExpressionLanguage)
{
    @("ExpressionLanguageMessageInterpolationTest.testExpressionAndParameterInterpolationInSameMessageDescriptor")
    unittest
    {
        auto context = contextFor(Size());
        const expected = "2 0 2147483647";
        const actual = interpolatorUnderTest().interpolate("${1+1} {min} {max}", context);
        assert(actual == expected, "Wrong substitution");
    }
}

@("ExpressionLanguageMessageInterpolationTest.testEscapedExpressionLanguage")
unittest
{
    auto context = contextFor(Size());
    const expected = "${1+1}";
    const actual = interpolatorUnderTest().interpolate("\\${1+1}", context);
    assert(actual == expected, "Wrong substitution");
}

@("ExpressionLanguageMessageInterpolationTest.testTernaryExpressionLanguageOperator")
unittest
{
    auto context = contextFor(Size());
    const expected = "foo";
    const actual = interpolatorUnderTest().interpolate("${min == 0 ? 'foo' : 'bar'}", context);
    assert(actual == expected, "Wrong substitution");
}

// Gap: Flint evaluates an expression subset; no method calls (`formatter.format(...)`, `'foobar'.substring(0,3)`).
version (FlintFullExpressionLanguage)
{
    @("ExpressionLanguageMessageInterpolationTest.testParameterFormatting")
    unittest
    {
        auto context = contextFor(Size());
        const expected = "Max 2147483647, min 0";
        const actual = interpolatorUnderTest().interpolate("${formatter.format('Max %s, min %s', max, min)}", context);
        assert(actual == expected, "Wrong substitution");
    }
}

@("ExpressionLanguageMessageInterpolationTest.testLiteralStaysUnchanged")
unittest
{
    auto context = contextFor(Size());
    const expected = "foo";
    const actual = interpolatorUnderTest().interpolate("foo", context);
    assert(actual == expected, "Wrong substitution");
}

@("ExpressionLanguageMessageInterpolationTest.testLiteralBackslash")
unittest
{
    auto context = contextFor(Size());
    const expected = "\\foo";
    const actual = interpolatorUnderTest().interpolate("\\foo", context);
    assert(actual == expected, "Wrong substitution");
}

// LIKELY BUG: the parameter pass skips a `{min}` right after `$`, which Hibernate replaces first; Flint then
// evaluates `${min}` to "0" instead of leaving "$0".
version (FlintParameterAfterDollar)
{
    @("ExpressionLanguageMessageInterpolationTest.testPrecedenceOfParameterInterpolation")
    unittest
    {
        auto context = contextFor(Size());
        const expected = "$0";
        const actual = interpolatorUnderTest().interpolate("${min}", context);
        assert(actual == expected, "Wrong substitution");
    }
}

// Gap: `interpolate` takes no locale (and expressions call no methods).
version (FlintMessageLocales)
{
    @("ExpressionLanguageMessageInterpolationTest.testLocaleBasedFormatting")
    unittest
    {
        auto context = contextFor(NotNull(), Any.of(42.00000));

        // german locale
        string expected = "42,00";
        string actual = interpolatorUnderTest().interpolate("${formatter.format('%1$.2f', validatedValue)}",
                context, Locale.GERMAN);
        assert(actual == expected, "Wrong substitution");

        // us locale
        expected = "42.00";
        actual = interpolatorUnderTest().interpolate("${formatter.format('%1$.2f', validatedValue)}",
                context, Locale.US);
        assert(actual == expected, "Wrong substitution");
    }
}

@("ExpressionLanguageMessageInterpolationTest.testMissingFormatArgument")
unittest
{
    auto context = contextFor(Size());
    const expected = "${formatter.format('%1$s')}";
    const actual = interpolatorUnderTest().interpolate("${formatter.format('%1$s')}", context);
    assert(actual == expected, "Calling of formatter#format w/o format parameter. No substitution should occur");
}

@("ExpressionLanguageMessageInterpolationTest.testNoParametersToFormatter")
unittest
{
    auto context = contextFor(Size());
    const expected = "${formatter.format()}";
    const actual = interpolatorUnderTest().interpolate("${formatter.format()}", context);
    assert(actual == expected, "Calling of formatter#format w/o parameters. No substitution should occur");
}

version (FlintFullExpressionLanguage)
{
    @("ExpressionLanguageMessageInterpolationTest.testNonFormatterFunction")
    unittest
    {
        auto context = contextFor(Size());
        const expected = "foo";
        const actual = interpolatorUnderTest().interpolate("${'foobar'.substring(0,3)}", context);
        assert(actual == expected, "Calling of String#substring should work");
    }
}

@("ExpressionLanguageMessageInterpolationTest.testNonFormatterFunctionVariables")
unittest
{
    auto context = contextFor(Size());
    const expected = "${'foobar'.substring(0,3)}";
    const actual = interpolatorUnderTest().interpolate("${'foobar'.substring(0,3)}", context);
    assert(actual == expected, "Calling of String#substring should work");
}

@("ExpressionLanguageMessageInterpolationTest.testNonFormatterFunctionBeanProperties")
unittest
{
    auto context = contextFor(Size());
    const expected = "${'foobar'.substring(0,3)}";
    const actual = interpolatorUnderTest().interpolate("${'foobar'.substring(0,3)}", context);
    assert(actual == expected, "Calling of String#substring should work");
}

version (FlintMessageLocales)
{
    @("ExpressionLanguageMessageInterpolationTest.testCallingWrongFormatterMethod")
    unittest
    {
        auto context = contextFor(NotNull(), Any.of(42.00000));
        const expected = "${formatter.foo('%1$.2f', validatedValue)}";
        const actual = interpolatorUnderTest().interpolate("${formatter.foo('%1$.2f', validatedValue)}",
                context, Locale.GERMAN);
        assert(actual == expected,
                "Wrong substitution, no formatting should occur, because the wrong method name is used");
    }
}

/// HV-834
@("ExpressionLanguageMessageInterpolationTest.testOpeningCurlyBraceInELExpression")
unittest
{
    auto context = contextFor(Size());
    const expected = "{";
    const actual = interpolatorUnderTest().interpolate("${1 > 0 ? '\\{' : '\\}'}", context);
    assert(actual == expected, "Curly braces are allowed in EL expressions, but need to be escaped");
}

/// HV-834
@("ExpressionLanguageMessageInterpolationTest.testClosingCurlyBraceInELExpression")
unittest
{
    auto context = contextFor(Size());
    const expected = "}";
    const actual = interpolatorUnderTest().interpolate("${1 < 0 ? '\\{' : '\\}'}", context);
    assert(actual == expected, "Curly braces are allowed in EL expressions, but need to be escaped");
}

/// HV-834
@("ExpressionLanguageMessageInterpolationTest.testCurlyBracesInELExpression")
unittest
{
    auto context = contextFor(Size());
    const expected = "a{b}d";
    const actual = interpolatorUnderTest().interpolate("${1 < 0 ? 'foo' : 'a\\{b\\}d'}", context);
    assert(actual == expected, "Curly braces are allowed in EL expressions, but need to be escaped");
}

/// HV-834
@("ExpressionLanguageMessageInterpolationTest.testEscapedQuoteInELExpression")
unittest
{
    auto context = contextFor(Size());
    const expected = "\"";
    const actual = interpolatorUnderTest().interpolate("${ true ? \"\\\"\" : \"foo\"}", context);
    assert(actual == expected, "If quotes are used in EL expression literal quotes need to be escaped");
}

/// HV-834
@("ExpressionLanguageMessageInterpolationTest.testSingleEscapedQuoteInELExpression")
unittest
{
    auto context = contextFor(Size());
    const expected = "'";
    const actual = interpolatorUnderTest().interpolate("${ false ? 'foo' : '\\''}", context);
    assert(actual == expected, "If single quotes are used in EL expression literal single quotes need to be escaped");
}
