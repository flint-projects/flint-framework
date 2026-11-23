/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/engine/messageinterpolation/
ResourceBundleMessageInterpolatorTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: `TestResourceBundleLocator` over `TestResourceBundle` is the user bundle Flint's
`ResourceBundleMessageInterpolator` takes as a D associative array; `ConstraintDescriptorImpl` and
`MessageInterpolatorContext` are built from D annotation values. testRecursiveMessageInterpolation needs Hibernate's
test-only proxy of the default bundle (`org.hibernate.validator.ValidationMessages` on the test classpath), which
Flint's fixed default table cannot take, and the two locale tests need bundles other than English: both gated. The
two HV-330 caching tests count `ResourceBundle` reads through a `ResourceBundleLocator`, neither of which Flint has;
they are not ported.
+/
module flint.hibernate.validator.resource_bundle_message_interpolator_test;

import flint.hibernate.validator.messageinterpolation : ResourceBundleMessageInterpolator;
import flint.hibernate.validator.validator_test_support : contextFor;
import flint.jakarta.validation.constraints : Max, NotNull, Size;

@safe:

// TestResourceBundle's messages.
private string[string] testResourceBundle() pure nothrow
{
    return [
        "simple.key": "message interpolation successful",
        "key-with-dashes": "message interpolation successful",
        "key with spaces": "message interpolation successful",
        "replace.in.user.bundle1": "{replace.in.user.bundle2}",
        "replace.in.user.bundle2": "{replace.in.default.bundle1}",
    ];
}

private ResourceBundleMessageInterpolator newInterpolator()
{
    return new ResourceBundleMessageInterpolator(testResourceBundle());
}

@("ResourceBundleMessageInterpolatorTest.testSuccessfulInterpolation")
unittest
{
    auto interpolator = newInterpolator();
    auto context = contextFor(NotNull());
    string expected = "message interpolation successful";
    string actual = interpolator.interpolate("{simple.key}", context);
    assert(actual == expected, "Wrong substitution");

    expected = "message interpolation successful message interpolation successful";
    actual = interpolator.interpolate("{simple.key} {simple.key}", context);
    assert(actual == expected, "Wrong substitution");

    expected = "The message interpolation successful completed";
    actual = interpolator.interpolate("The {simple.key} completed", context);
    assert(actual == expected, "Wrong substitution");

    expected = "{{simple.key}}";
    actual = interpolator.interpolate("{{simple.key}}", context);
    assert(actual == expected, "Wrong substitution");
}

@("ResourceBundleMessageInterpolatorTest.testMessageLiterals")
unittest
{
    auto interpolator = newInterpolator();
    auto messageInterpolatorContext = contextFor(NotNull());

    string expected = "{";
    string actual = interpolator.interpolate("\\{", messageInterpolatorContext);
    assert(actual == expected, "Wrong substitution");

    expected = "}";
    actual = interpolator.interpolate("\\}", messageInterpolatorContext);
    assert(actual == expected, "Wrong substitution");

    expected = "\\";
    actual = interpolator.interpolate("\\", messageInterpolatorContext);
    assert(actual == expected, "Wrong substitution");
}

@("ResourceBundleMessageInterpolatorTest.testUnSuccessfulInterpolation")
unittest
{
    auto interpolator = newInterpolator();
    auto messageInterpolatorContext = contextFor(NotNull());

    string expected = "foo"; // missing {}
    string actual = interpolator.interpolate("foo", messageInterpolatorContext);
    assert(actual == expected, "Wrong substitution");

    expected = "#{foo  {}";
    actual = interpolator.interpolate("#{foo  {}", messageInterpolatorContext);
    assert(actual == expected, "Wrong substitution");
}

@("ResourceBundleMessageInterpolatorTest.testUnknownTokenInterpolation")
unittest
{
    auto interpolator = newInterpolator();
    auto messageInterpolatorContext = contextFor(NotNull());

    const expected = "{bar}"; // unknown token {}
    const actual = interpolator.interpolate("{bar}", messageInterpolatorContext);
    assert(actual == expected, "Wrong substitution");
}

@("ResourceBundleMessageInterpolatorTest.testKeyWithDashes")
unittest
{
    auto interpolator = newInterpolator();
    auto messageInterpolatorContext = contextFor(NotNull());

    const expected = "message interpolation successful"; // unknown token {}
    const actual = interpolator.interpolate("{key-with-dashes}", messageInterpolatorContext);
    assert(actual == expected, "Wrong substitution");
}

@("ResourceBundleMessageInterpolatorTest.testKeyWithSpaces")
unittest
{
    auto interpolator = newInterpolator();
    auto messageInterpolatorContext = contextFor(NotNull());

    const expected = "message interpolation successful"; // unknown token {}
    const actual = interpolator.interpolate("{key with spaces}", messageInterpolatorContext);
    assert(actual == expected, "Wrong substitution");
}

@("ResourceBundleMessageInterpolatorTest.testDefaultInterpolation")
unittest
{
    auto interpolator = newInterpolator();
    auto messageInterpolatorContext = contextFor(NotNull());

    string expected = "must not be null";
    string actual = interpolator.interpolate(NotNull().message, messageInterpolatorContext);
    assert(actual == expected, "Wrong substitution");

    expected = "size must be between 0 and 2147483647"; // unknown token {}

    messageInterpolatorContext = contextFor(Size());
    actual = interpolator.interpolate(Size().message, messageInterpolatorContext);
    assert(actual == expected, "Wrong substitution");
}

// Gap: only Hibernate's English bundle is ported, and `interpolate` takes no locale.
version (FlintMessageLocales)
{
    @("ResourceBundleMessageInterpolatorTest.testMessageInterpolationWithLocale")
    unittest
    {
        auto interpolator = new ResourceBundleMessageInterpolator();
        auto messageInterpolatorContext = contextFor(NotNull());

        const expected = "darf nicht null sein";
        const actual = interpolator.interpolate(NotNull().message, messageInterpolatorContext, Locale.GERMAN);
        assert(actual == expected, "Wrong substitution");
    }

    @("ResourceBundleMessageInterpolatorTest.testUserResourceBundle")
    unittest
    {
        auto interpolator = new ResourceBundleMessageInterpolator();
        auto messageInterpolatorContext = contextFor(NotNull());

        const expected = "no puede ser null";
        const actual = interpolator.interpolate(NotNull().message, messageInterpolatorContext,
                Locale.forLanguageTag("es-ES"));
        assert(actual == expected, "Wrong substitution");
    }
}

// Gap: the default bundle is a fixed table; Hibernate's test proxies it to add replace.in.default.bundle1 and 2.
version (FlintDefaultBundleOverride)
{
    @("ResourceBundleMessageInterpolatorTest.testRecursiveMessageInterpolation")
    unittest
    {
        const descriptor = Max(10L, "{replace.in.user.bundle1}");
        auto interpolator = newInterpolator();
        auto messageInterpolatorContext = contextFor(descriptor);

        const expected = "{replace.in.default.bundle2}";
        const actual = interpolator.interpolate(descriptor.message, messageInterpolatorContext);
        assert(actual == expected, "Within default bundle replacement parameter evaluation should not be recursive!");
    }
}

@("ResourceBundleMessageInterpolatorTest.testCorrectMessageInterpolationIfParameterCannotBeReplaced")
unittest
{
    const message = "Message should stay unchanged since {fubar} is not replaceable";
    const maxDescriptor = Max(10L, message);
    auto interpolator = newInterpolator();
    auto messageInterpolatorContext = contextFor(maxDescriptor);

    const actual = interpolator.interpolate(maxDescriptor.message, messageInterpolatorContext);
    assert(actual == message, "The message should not have changed.");
}
