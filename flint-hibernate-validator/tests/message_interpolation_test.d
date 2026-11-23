/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/engine/messageinterpolation/MessageInterpolationTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: the `PropertyResourceBundle` read from `.properties` lines is the user bundle as a D
associative array holding the values those lines denote. Flint validates the Default group only, so Foo's getters,
each constrained in its own group (`Bar`, `Baz`, `Buz`, `Qux`, `Zap`) and validated with `validate(foo, Group)`,
are one D bean per group with the constraint on a field. `AllowedValuesValidator` is bound with a `ConstraintMapping`
and its `values` is a `string[]`.
+/
module flint.hibernate.validator.message_interpolation_test;

import flint.hibernate.validator.messageinterpolation : ResourceBundleMessageInterpolator;
import flint.hibernate.validator.validator_test_support : configurationFor;
import flint.jakarta.validation : Constraint, ConstraintValidator, ConstraintValidatorContext, Validator;
import flint.jakarta.validation.constraints : Min, NotNull;
import flint.java.lang : classOf;

@safe:

@Constraint(validatedBy : [classOf!AllowedValuesValidator])
private struct AllowedValues
{
    string[] values;
    string message = "{buz}";
}

private final class AllowedValuesValidator : ConstraintValidator!(AllowedValues, string)
{
    private string[] values;

    void initialize(AllowedValues values)
    {
        this.values = values.values;
    }

    bool isValid(string value, ConstraintValidatorContext context)
    {
        if (value is null)
            return true;
        foreach (allowed; values)
            if (allowed == value)
                return true;
        return false;
    }
}

// Foo's getBar() in group Bar.
private final class FooBar
{
    @NotNull(message : "{bar}")
    string bar = null;
}

// Foo's getBaz() in group Baz.
private final class FooBaz
{
    @Min(value : 5, message:
            "{baz}")
    int baz = 0;
}

// Foo's getBuz() in group Buz.
private final class FooBuz
{
    @AllowedValues(values : ["bar", "baz", "qux"])
    string buz = "buz";
}

// Foo's getQux() in group Qux.
private final class FooQux
{
    @NotNull(message : "{qux}")
    string qux = null;
}

// Foo's getZap() in group Zap.
private final class FooZap
{
    @Min(value : 10, message:
            "{zap}")
    int zap = 0;
}

private Validator createValidator()
{
    // The values of: bar=Message is \\{escaped\\}, baz=Message is US\$ {value}, buz=Message is {values},
    // qux=Message is {missing}, zap=Message is \\${value} and escaped=wrong.
    const string[string] bundle = [
        "bar": `Message is \{escaped\}`, "baz": "Message is US$ {value}", "buz": "Message is {values}",
        "qux": "Message is {missing}", "zap": `Message is \${value}`, "escaped": "wrong",
    ];
    auto config = configurationFor!(FooBar, FooBaz, FooBuz, FooQux, FooZap)();
    auto mapping = config.createConstraintMapping();
    mapping.constraintDefinition!AllowedValues().validatedBy!AllowedValuesValidator();
    config.addMapping(mapping);
    config.messageInterpolator(new ResourceBundleMessageInterpolator(bundle.dup));
    return config.buildValidatorFactory().getValidator();
}

@("MessageInterpolationTest.testCurlyBracesEscapingShouldBeRespected")
unittest
{
    auto violation = createValidator().validate(new FooBar())[0];
    assert(violation.getMessage() == "Message is {escaped}", violation.getMessage());
}

@("MessageInterpolationTest.testAppendReplacementNeedsToEscapeBackslashAndDollarSign")
unittest
{
    auto violation = createValidator().validate(new FooBaz())[0];
    assert(violation.getMessage() == "Message is US$ 5", violation.getMessage());
}

@("MessageInterpolationTest.testUnknownParametersShouldBePreserved")
unittest
{
    auto violation = createValidator().validate(new FooQux())[0];
    assert(violation.getMessage() == "Message is {missing}", violation.getMessage());
}

@("MessageInterpolationTest.testInterpolationOfArrayParameter")
unittest
{
    auto violation = createValidator().validate(new FooBuz())[0];
    assert(violation.getMessage() == "Message is [bar, baz, qux]", violation.getMessage());
}

@("MessageInterpolationTest.testDollarSignEscapingShouldBeRespected")
unittest
{
    auto violation = createValidator().validate(new FooZap())[0];
    assert(violation.getMessage() == "Message is $10", violation.getMessage());
}
