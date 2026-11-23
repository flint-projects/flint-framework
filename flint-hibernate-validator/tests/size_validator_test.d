/++
Ported from hibernate/hibernate-validator 9.1.6.Final,
engine/src/test/java/org/hibernate/validator/test/internal/constraintvalidators/bv/size/SizeValidatorTest.java.

SPDX-License-Identifier: Apache-2.0
Copyright Red Hat Inc. and Hibernate Authors. Licensed under the Apache License, Version 2.0.

Modified by the Flint authors: each `SizeValidatorFor<Type>` is Flint's one dispatcher run on the D value
(`isValidFor`), an array reporting its length through its Flint AOT descriptor. Java's `null` array is `Any.init`:
a D `[]` is null and counts as an empty array. `Object[]` is an array of a bean class: Flint's `Any` cannot box an
`Object[]` in @safe code. `ArrayList` and `HashMap` are flint.java.util's; the HV-502 custom
`CharSequence` (`MyCustomStringImpl`) is a D `string`.
+/
module flint.hibernate.validator.size_validator_test;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.hibernate.validator.validator_test_support : isValidFor, validatorFor;
import flint.jakarta.validation.constraints : Size;
import flint.java.util : ArrayList, HashMap, List;

@safe:

private final class Foo
{
    @Size(min: 1, max: 1, message: "there can only be one")
    List!Foo listOfSubClasses;

    this()
    {
        listOfSubClasses = new ArrayList!Foo();
    }
}

@("SizeValidatorTest.testIsValidObjectArray")
unittest
{
    assertSizes!Foo();
}

@("SizeValidatorTest.testIsValidBooleanArray")
unittest
{
    assertSizes!bool();
}

@("SizeValidatorTest.testIsValidByteArray")
unittest
{
    assertSizes!byte();
}

@("SizeValidatorTest.testIsValidCharArray")
unittest
{
    assertSizes!wchar();
}

@("SizeValidatorTest.testIsValidDoubleArray")
unittest
{
    assertSizes!double();
}

@("SizeValidatorTest.testIsValidFloatArray")
unittest
{
    assertSizes!float();
}

@("SizeValidatorTest.testIsValidIntArray")
unittest
{
    assertSizes!int();
}

@("SizeValidatorTest.testIsValidLongArray")
unittest
{
    assertSizes!long();
}

@("SizeValidatorTest.testIsValidShortArray")
unittest
{
    assertSizes!short();
}

@("SizeValidatorTest.testIsValidCollection")
unittest
{
    const validator = getValidatorMin1Max2();
    assert(isValidFor(validator, Any.init));

    auto collection = new ArrayList!string();
    assert(!isValidFor(validator, collection));

    collection.add("firstItem");
    assert(isValidFor(validator, collection));

    collection.add("secondItem");
    assert(isValidFor(validator, collection));

    collection.add("thirdItem");
    assert(!isValidFor(validator, collection));
}

@("SizeValidatorTest.testIsValidMap")
unittest
{
    const validator = getValidatorMin1Max2();
    assert(isValidFor(validator, Any.init));

    auto map = new HashMap!(string, string)();
    assert(!isValidFor(validator, map));

    map.put("key1", "firstItem");
    assert(isValidFor(validator, map));

    map.put("key3", "secondItem");
    assert(isValidFor(validator, map));

    map.put("key2", "thirdItem");
    assert(!isValidFor(validator, map));
}

@("SizeValidatorTest.testIsValidString")
unittest
{
    const validator = getValidatorMin1Max2();
    assert(isValidFor(validator, Any.init));
    assert(!isValidFor(validator, ""));
    assert(isValidFor(validator, "a"));
    assert(isValidFor(validator, "ab"));
    assert(!isValidFor(validator, "abc"));
}

@("SizeValidatorTest.testIsValidCharSequence")
unittest
{
    const validator = getValidatorMin1Max2();
    assert(isValidFor(validator, "ab"));
    assert(!isValidFor(validator, "abc"));
}

@("SizeValidatorTest.testGenericsExtendsFoo")
unittest
{
    auto validator = validatorFor!Foo();
    auto violations = validator.validate(new Foo());
    assert(violations.length == 1);
    assert(violations[0].getConstraintDescriptor().getAnnotationType() == typeNameOf!Size);
    assert(violations[0].getMessage() == "there can only be one");
}

private Size getValidatorMin1Max2() pure nothrow @nogc
{
    return Size(min: 1, max: 2, message: "{validator.max}");
}

private void assertSizes(E)()
{
    const validator = getValidatorMin1Max2();
    const described = descriptorOf!(E[])();
    assert(isValidFor(validator, Any.init, described));
    assert(!isValidFor(validator, Any.of(new E[0]), described));
    assert(isValidFor(validator, Any.of(new E[1]), described));
    assert(isValidFor(validator, Any.of(new E[2]), described));
    assert(!isValidFor(validator, Any.of(new E[3]), described));
}
