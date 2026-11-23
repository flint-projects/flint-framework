/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/engine/ValidatorTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: the beans are registered as Flint AOT descriptors, a constrained getter is an
annotated field, and `validateValue(X.class, ...)` names the type. Flint validates the Default group only, walks no
nested property path in validateProperty/validateValue, has no `getConstraintsForClass`, no `Validator.unwrap`, and
does not collect constraints from interface getters: those tests are gated. HV-376 names a property `€price`, which
is not a D identifier: testValidatePropertyWithCurrencySymbol and testValidateValueWithCurrencySymbol are not
ported.
+/
module flint.hibernate.validator.validator_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.validator_test_support : assertNoViolations, assertOnlyViolations, configurationFor;
import flint.jakarta.validation : Constraint, ConstraintValidator, ConstraintValidatorContext,
    ConstraintViolation, Valid, Validator;
import flint.jakarta.validation.constraints : Min, NotNull;
import flint.java.lang : classOf;
import flint.java.util : ArrayList, Collection, List;
import std.typecons : Nullable;

@safe:

private final class A
{
    @NotNull
    string b;
}

private final class Foo
{
    @Valid
    Collection!Bar bar;

    this()
    {
        bar = new ArrayList!Bar();
        bar.add(new Bar());
    }
}

private final class Bar
{
    @NotNull
    string alwaysNull;
}

private final class NotFollowingJavaBeanNotation
{
    @NotNull
    string m_foo;

    string getFoo()
    {
        return m_foo;
    }
}

@Constraint(validatedBy: [classOf!ClassLevelConstraintValidator])
private struct ClassLevelConstraint
{
    string message = "Invalid order shipment date must be after order date";
}

private final class ClassLevelConstraintValidator : ConstraintValidator!(ClassLevelConstraint,
        WithClassLevelConstraint)
{
    void initialize(ClassLevelConstraint constraintAnnotation)
    {
    }

    bool isValid(WithClassLevelConstraint value, ConstraintValidatorContext context)
    {
        return false;
    }
}

@ClassLevelConstraint
private final class WithClassLevelConstraint
{
    @Min(1)
    Nullable!int someProperty;
}

private Validator getValidator()
{
    auto config = configurationFor!(A, Foo, Bar, NotFollowingJavaBeanNotation,
            WithClassLevelConstraint, Nullable!int, M, N)();
    auto mapping = config.createConstraintMapping();
    mapping.constraintDefinition!ClassLevelConstraint().validatedBy!ClassLevelConstraintValidator();
    return config.addMapping(mapping).buildValidatorFactory().getValidator();
}

// containsOnlyViolations(violationOf(type).withProperty(property))
private void assertOnlyViolationAt(ConstraintViolation[] violations, string type, string property)
{
    assertOnlyViolations(violations, type);
    assert(violations[0].getPropertyPath().toString() == property, violations[0].getPropertyPath().toString());
}

// Gap: Flint validates the Default group only (no `groups`, no @GroupSequence), and Hibernate's @Length is not
// ported; these tests also walk nested property paths.
version (FlintValidationGroups)
{
    private final class GroupA
    {
        @NotNull
        string b;
        @Valid
        C c;
        @Valid
        D d;
    }

    private interface TestGroup
    {
    }

    @GroupSequence([classOf!TestGroup, classOf!C])
    private final class C
    {
        @Pattern(regexp: "[0-9]+", groups: [classOf!TestGroup])
        @Length(min: 2)
        string id;

        this(string id)
        {
            this.id = id;
        }
    }

    @GroupSequence([classOf!TestGroup, classOf!E])
    private class E
    {
        @Pattern(regexp: "[0-9]+", groups: [classOf!TestGroup])
        string e;

        this(string e)
        {
            this.e = e;
        }
    }

    private final class D : E
    {
        this(string e)
        {
            super(e);
        }
    }

    /// HV-429
    @("ValidatorTest.testValidatePropertyWithRedefinedDefaultGroupOnMainEntity")
    unittest
    {
        auto testInstance = new GroupA();
        testInstance.c = new C("aaa");
        auto constraintViolations = getValidator().validateProperty(testInstance, "c.id");
        assertOnlyViolationAt(constraintViolations, typeNameOf!Pattern, "c.id");
    }

    /// HV-429
    @("ValidatorTest.testValidatePropertyWithRedefinedDefaultGroupOnSuperClass")
    unittest
    {
        auto testInstance = new GroupA();
        testInstance.d = new D("aa");
        auto constraintViolations = getValidator().validateProperty(testInstance, "d.e");
        assertOnlyViolationAt(constraintViolations, typeNameOf!Pattern, "d.e");
    }

    /// HV-429
    @("ValidatorTest.testValidateValueWithRedefinedDefaultGroupOnMainEntity")
    unittest
    {
        auto constraintViolations = getValidator().validateValue(typeNameOf!GroupA, "c.id", Any.of("aaa"));
        assertOnlyViolationAt(constraintViolations, typeNameOf!Pattern, "c.id");
    }

    /// HV-429
    @("ValidatorTest.testValidateValueWithRedefinedDefaultGroupOnSuperClass")
    unittest
    {
        auto constraintViolations = getValidator().validateValue(typeNameOf!GroupA, "d.e", Any.of("aa"));
        assertOnlyViolationAt(constraintViolations, typeNameOf!Pattern, "d.e");
    }
}

/// HV-208
@("ValidatorTest.testPropertyPathDoesNotStartWithLeadingDot")
unittest
{
    auto testInstance = new A();
    auto constraintViolations = getValidator().validate(testInstance);
    assertOnlyViolationAt(constraintViolations, typeNameOf!NotNull, "b");
}

// Gap: Flint has no getConstraintsForClass / BeanDescriptor.
version (FlintBeanMetadata)
{
    private final class B
    {
        private bool b;

        @AssertTrue
        bool hasB()
        {
            return b;
        }
    }

    @("ValidatorTest.testIsBeanConstrained")
    unittest
    {
        auto beanDescriptor = getValidator().getConstraintsForClass(typeNameOf!B);
        assert(beanDescriptor.isBeanConstrained());
    }
}

// Gap: constraints declared on an interface's getters are not collected for the implementing classes.
version (FlintInterfaceConstraints)
{
    private interface F
    {
        @CountValidationCalls
        string getFoo();
        @CountValidationCalls
        string getBar();
    }

    private class G : F
    {
        string getFoo()
        {
            return null;
        }

        string getBar()
        {
            return null;
        }
    }

    private final class H : G, F
    {
    }

    private interface MyConstraints
    {
        @NotNull
        string getProperty();
    }

    /// HV-466
    @("ValidatorTest.testValidateInterfaceConstraintsAreValidatedOneTime")
    unittest
    {
        CountValidationCallsValidator.init();
        assertNoViolations(getValidator().validate(new H()));
        assert(CountValidationCallsValidator.getNumberOfValidationCall() == 2);
    }

    /// HV-466
    @("ValidatorTest.testValidatePropertyInterfaceConstraintsAreValidatedOneTime")
    unittest
    {
        CountValidationCallsValidator.init();
        assertNoViolations(getValidator().validateProperty(new H(), "foo"));
        assert(CountValidationCallsValidator.getNumberOfValidationCall() == 1);
    }

    /// HV-466
    @("ValidatorTest.testValidateValueInterfaceConstraintsAreValidatedOneTime")
    unittest
    {
        CountValidationCallsValidator.init();
        assertNoViolations(getValidator().validateValue(typeNameOf!H, "foo", Any.init));
        assert(CountValidationCallsValidator.getNumberOfValidationCall() == 1);
    }
}

/// HV-468
@("ValidatorTest.testPropertyPath")
unittest
{
    auto foo = new Foo();
    auto constraintViolations = getValidator().validate(foo);
    assertOnlyViolations(constraintViolations, typeNameOf!NotNull);
    auto nodes = constraintViolations[0].getPropertyPath().nodes();
    assert(nodes.length == 2);
    assert(nodes[0].getName() == "bar" && !nodes[0].isInIterable());
    assert(nodes[1].getName() == "alwaysNull" && nodes[1].isInIterable());
    assert(nodes[1].getKey().isNull() && nodes[1].getIndex() == 0);
}

@("ValidatorTest.testConstraintDefinedOnEntityNotFollowingBeanNotation")
unittest
{
    // validating the whole entity
    auto constraintViolations = getValidator().validate(new NotFollowingJavaBeanNotation());
    assertOnlyViolations(constraintViolations, typeNameOf!NotNull);

    // using validateProperty (which is used by JSF) to validate explicitly
    constraintViolations = getValidator().validateProperty(new NotFollowingJavaBeanNotation(), "m_foo");
    assertOnlyViolationAt(constraintViolations, typeNameOf!NotNull, "m_foo");

    // using validateProperty (which is used by JSF) to validate explicitly (no violation, because there is no
    // property foo Validator knows about
    constraintViolations = getValidator().validateProperty(new NotFollowingJavaBeanNotation(), "foo");
    assertNoViolations(constraintViolations);
}

// Gap: Flint's Validator has no unwrap.
version (FlintValidatorUnwrap)
{
    @("ValidatorTest.testUnwrapToImplementationCausesValidationException")
    unittest
    {
        import flint.hibernate.validator.internal.engine : ValidatorImpl;
        import flint.jakarta.validation : ValidationException;
        import std.exception : assertThrown;

        assertThrown!ValidationException(getValidator().unwrap!ValidatorImpl());
    }

    @("ValidatorTest.testUnwrapToExecutableValidatorCausesValidationException")
    unittest
    {
        import flint.jakarta.validation : ValidationException;
        import flint.jakarta.validation.executable : ExecutableValidator;
        import std.exception : assertThrown;

        assertThrown!ValidationException(getValidator().unwrap!ExecutableValidator());
    }

    @("ValidatorTest.testUnwrapToPublicTypesSucceeds")
    unittest
    {
        auto validator = getValidator();
        auto asValidator = validator.unwrap!Validator();
        assert(asValidator is validator);
        auto asObject = validator.unwrap!Object();
        assert(asObject is cast(Object) validator);
    }
}

// Gap: validateProperty and validateValue take a property name, not a nested path (`list[0].foo`, `map[bar].foo`).
version (FlintNestedPropertyPaths)
{
    import flint.java.util : HashMap;

    private final class X
    {
        @Valid
        List!Z list;

        this()
        {
            list = new ArrayList!Z();
        }

        void addZ(Z z)
        {
            list.add(z);
        }
    }

    private final class Z
    {
        @NotNull
        string foo;
    }

    private final class I
    {
        @Valid
        HashMap!(string, J) map;

        this()
        {
            map = new HashMap!(string, J)();
        }

        void putJ(string key, J j)
        {
            map.put(key, j);
        }
    }

    private final class J
    {
        @NotNull
        string foo;
    }

    private final class K
    {
        @Valid
        L!string foo;
    }

    private final class L(T)
    {
        @NotNull
        string bar;
        @NotNull
        T genericProperty;
    }

    private Validator nestedValidator()
    {
        return configurationFor!(X, Z, I, J, K, L!string)().buildValidatorFactory().getValidator();
    }

    /// HV-596
    @("ValidatorTest.testValidateValueWithNestedPath")
    unittest
    {
        auto validator = nestedValidator();
        auto constraintViolations = validator.validateValue(typeNameOf!X, "list[0].foo", Any.init);
        assertOnlyViolationAt(constraintViolations, typeNameOf!NotNull, "list[0].foo");

        auto constraintViolationsK = validator.validateValue(typeNameOf!K, "foo.bar", Any.init);
        assertOnlyViolationAt(constraintViolationsK, typeNameOf!NotNull, "foo.bar");
    }

    /// HV-1002
    @("ValidatorTest.testValidatePropertyWithNestedPath")
    unittest
    {
        auto validator = nestedValidator();
        auto someX = new X();
        someX.addZ(new Z());
        assertOnlyViolationAt(validator.validateProperty(someX, "list[0].foo"), typeNameOf!NotNull, "list[0].foo");

        auto someI = new I();
        someI.putJ("bar", new J());
        assertOnlyViolationAt(validator.validateProperty(someI, "map[bar].foo"), typeNameOf!NotNull, "map[bar].foo");

        auto someK = new K();
        someK.foo = new L!string();
        assertOnlyViolationAt(validator.validateProperty(someK, "foo.bar"), typeNameOf!NotNull, "foo.bar");
        assertOnlyViolationAt(validator.validateProperty(someK, "foo.genericProperty"),
                typeNameOf!NotNull, "foo.genericProperty");
    }

    /// HV-1002
    @("ValidatorTest.testValidatePropertyWithNestedPathAndNullPropertyInTheWay")
    unittest
    {
        import flint.jakarta.validation : ValidationException;

        auto someX = new X();
        try
        {
            nestedValidator().validateProperty(someX, "list[0].foo");
            assert(false);
        }
        catch (ValidationException e)
            assert(e.msg.length >= 8 && e.msg[0 .. 8] == "HV000195", e.msg);
    }
}

private final class M
{
    N foo;
    @NotNull
    string bar;
}

private final class N
{
    @NotNull
    string baz;
}

/// HV-1002
@("ValidatorTest.testValidatePropertyWithNestedPathAndMissingValid")
unittest
{
    import flint.jakarta.validation : ValidationException;

    auto someM = new M();
    try
    {
        getValidator().validateProperty(someM, "foo.baz");
        assert(false);
    }
    catch (ValidationException e)
        assert(e.msg.length >= 8 && e.msg[0 .. 8] == "HV000039", e.msg);
}

/// HV-1341
@("ValidatorTest.testValidatePropertyInPresenceOfClassLevelConstraint")
unittest
{
    auto violations = getValidator().validateValue(typeNameOf!WithClassLevelConstraint, "someProperty", Any.of(-1));
    assertOnlyViolationAt(violations, typeNameOf!Min, "someProperty");
}

version (FlintInterfaceConstraints)
{
    @("ValidatorTest.testValidateValueConstraintOnInterface")
    unittest
    {
        auto violations = getValidator().validateValue(typeNameOf!MyConstraints, "property", Any.init);
        assertOnlyViolationAt(violations, typeNameOf!NotNull, "property");
    }
}
