// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/util
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.util.AssertTests` (v7.1.0): one `unittest` per Java test method, each
starting with a `// <JavaTestName>` comment.

Skipped Java tests (6), with reasons:
- isInstanceOfWithNullType, isInstanceOfWithNullTypeAndMessageSupplier: the type is a template parameter (R4);
  a null `Class` cannot be expressed.
- isAssignableWithNullSupertype, isAssignableWithNullSupertypeAndMessageSupplier, isAssignableWithNullSubtype,
  isAssignableWithNullSubtypeAndMessageSupplier: both types are template parameters (R4); a null `Class` cannot be
  expressed.
+/
module flint.util.assert_test;

import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.java.util : Arrays, Collection, Collections, List, Map;
import flint.java.util.function_ : Supplier;
import flint.util : Assert;
import flint.util.test_support : contains, expectThrows;

@safe:

private class Number
{
}

private class Integer : Number
{
}

private string delegate() @safe nullSupplier()
{
    return null;
}

// stateWithMessage
unittest
{
    Assert.state(true, "enigma");
}

// stateWithFalseExpressionAndMessage
unittest
{
    auto e = expectThrows!IllegalStateException(() { Assert.state(false, "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// stateWithMessageSupplier
unittest
{
    Assert.state(true, () => "enigma");
}

// stateWithFalseExpressionAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalStateException(() { Assert.state(false, () => "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// stateWithFalseExpressionAndNullMessageSupplier
unittest
{
    auto e = expectThrows!IllegalStateException(() { Assert.state(false, nullSupplier()); });
    assert(e.getMessage() is null);
}

// isTrueWithMessage
unittest
{
    Assert.isTrue(true, "enigma");
}

// isTrueWithFalse
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.isTrue(false, "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// isTrueWithMessageSupplier
unittest
{
    Assert.isTrue(true, () => "enigma");
}

// isTrueWithFalseAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.isTrue(false, () => "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// isTrueWithFalseAndNullMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.isTrue(false, nullSupplier()); });
    assert(e.getMessage() is null);
}

// isNullWithMessage
unittest
{
    Assert.isNull(null, "Bla");
}

// isNullWithMessageSupplier
unittest
{
    Assert.isNull(null, () => "enigma");
}

// isNullWithNonNullObjectAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.isNull("foo", () => "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// isNullWithNonNullObjectAndNullMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.isNull("foo", nullSupplier()); });
    assert(e.getMessage() is null);
}

// notNullWithMessage
unittest
{
    Assert.notNull("foo", "enigma");
}

// notNullWithMessageSupplier
unittest
{
    Assert.notNull("foo", () => "enigma");
}

// notNullWithNullAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.notNull(null, () => "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// notNullWithNullAndNullMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.notNull(null, nullSupplier()); });
    assert(e.getMessage() is null);
}

// hasLength
unittest
{
    Assert.hasLength("I Heart ...", "enigma");
}

// hasLengthWithWhitespaceOnly
unittest
{
    Assert.hasLength("\t  ", "enigma");
}

// hasLengthWithEmptyString
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.hasLength("", "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// hasLengthWithNull
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.hasLength(null, "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// hasLengthWithMessageSupplier
unittest
{
    Assert.hasLength("foo", () => "enigma");
}

// hasLengthWithWhitespaceOnlyAndMessageSupplier
unittest
{
    Assert.hasLength("\t", () => "enigma");
}

// hasLengthWithEmptyStringAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.hasLength("", () => "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// hasLengthWithNullAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.hasLength(null, () => "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// hasLengthWithNullAndNullMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.hasLength(null, nullSupplier()); });
    assert(e.getMessage() is null);
}

// hasText
unittest
{
    Assert.hasText("foo", "enigma");
}

// hasTextWithWhitespaceOnly
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.hasText("\t ", "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// hasTextWithEmptyString
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.hasText("", "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// hasTextWithNull
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.hasText(null, "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// hasTextWithMessageSupplier
unittest
{
    Assert.hasText("foo", () => "enigma");
}

// hasTextWithWhitespaceOnlyAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.hasText("\t ", () => "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// hasTextWithEmptyStringAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.hasText("", () => "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// hasTextWithNullAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.hasText(null, () => "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// hasTextWithNullAndNullMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.hasText(null, nullSupplier()); });
    assert(e.getMessage() is null);
}

// doesNotContainWithNullSearchString
unittest
{
    Assert.doesNotContain(null, "rod", "enigma");
}

// doesNotContainWithNullSubstring
unittest
{
    Assert.doesNotContain("A cool chick's name is Brod.", null, "enigma");
}

// doesNotContainWithEmptySubstring
unittest
{
    Assert.doesNotContain("A cool chick's name is Brod.", "", "enigma");
}

// doesNotContainWithNullSearchStringAndNullSubstring
unittest
{
    Assert.doesNotContain(null, null, "enigma");
}

// doesNotContainWithMessageSupplier
unittest
{
    Assert.doesNotContain("foo", "bar", () => "enigma");
}

// doesNotContainWithNullSearchStringAndMessageSupplier
unittest
{
    Assert.doesNotContain(null, "bar", () => "enigma");
}

// doesNotContainWithNullSubstringAndMessageSupplier
unittest
{
    Assert.doesNotContain("foo", null, () => "enigma");
}

// doesNotContainWithNullSearchStringAndNullSubstringAndMessageSupplier
unittest
{
    Assert.doesNotContain(null, null, () => "enigma");
}

// doesNotContainWithSubstringPresentInSearchStringAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.doesNotContain("1234", "23", () => "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// doesNotContainWithNullMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.doesNotContain("1234", "23", nullSupplier());
    });
    assert(e.getMessage() is null);
}

// notEmptyArray
unittest
{
    Assert.notEmpty(["1234"], "enigma");
}

// notEmptyArrayWithEmptyArray
unittest
{
    string[] empty = [];
    auto e = expectThrows!IllegalArgumentException(() { Assert.notEmpty(empty, "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// notEmptyArrayWithNullArray
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.notEmpty(cast(Object[]) null, "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// notEmptyArrayWithMessageSupplier
unittest
{
    Assert.notEmpty(["1234"], () => "enigma");
}

// notEmptyArrayWithEmptyArrayAndMessageSupplier
unittest
{
    string[] empty = [];
    auto e = expectThrows!IllegalArgumentException(() { Assert.notEmpty(empty, () => "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// notEmptyArrayWithNullArrayAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.notEmpty(cast(Object[]) null, () => "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// notEmptyArrayWithEmptyArrayAndNullMessageSupplier
unittest
{
    string[] empty = [];
    auto e = expectThrows!IllegalArgumentException(() { Assert.notEmpty(empty, nullSupplier()); });
    assert(e.getMessage() is null);
}

// noNullElements
unittest
{
    Assert.noNullElements(["1234"], "enigma");
}

// noNullElementsWithEmptyArray
unittest
{
    string[] empty = [];
    Assert.noNullElements(empty, "enigma");
}

// noNullElementsWithMessageSupplier
unittest
{
    Assert.noNullElements(["1234"], () => "enigma");
}

// noNullElementsWithEmptyArrayAndMessageSupplier
unittest
{
    string[] empty = [];
    Assert.noNullElements(empty, () => "enigma");
}

// noNullElementsWithNullArrayAndMessageSupplier
unittest
{
    Assert.noNullElements(cast(Object[]) null, () => "enigma");
}

// noNullElementsWithNullElementsAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.noNullElements(["foo", null, "bar"], () => "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// noNullElementsWithNullElementsAndNullMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.noNullElements(["foo", null, "bar"], nullSupplier());
    });
    assert(e.getMessage() is null);
}

// noNullElementsWithCollection
unittest
{
    Assert.noNullElements(Arrays.asList("foo", "bar"), "enigma");
}

// noNullElementsWithEmptyCollection
unittest
{
    Assert.noNullElements(Collections.emptyList!string(), "enigma");
}

// noNullElementsWithNullCollection
unittest
{
    Assert.noNullElements(cast(Collection!Object) null, "enigma");
}

// noNullElementsWithCollectionAndNullElement
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.noNullElements(Arrays.asList("foo", null, "bar"), "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// noNullElementsWithCollectionAndMessageSupplier
unittest
{
    Assert.noNullElements(Arrays.asList("foo", "bar"), () => "enigma");
}

// noNullElementsWithEmptyCollectionAndMessageSupplier
unittest
{
    Assert.noNullElements(Collections.emptyList!string(), () => "enigma");
}

// noNullElementsWithNullCollectionAndMessageSupplier
unittest
{
    Assert.noNullElements(cast(Collection!Object) null, () => "enigma");
}

// noNullElementsWithCollectionAndNullElementAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.noNullElements(Arrays.asList("foo", null, "bar"), () => "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// noNullElementsWithCollectionAndNullElementAndNullMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.noNullElements(Arrays.asList("foo", null, "bar"), nullSupplier());
    });
    assert(e.getMessage() is null);
}

// notEmptyCollection
unittest
{
    Assert.notEmpty(Collections.singletonList("foo"), "enigma");
}

// notEmptyCollectionWithEmptyCollection
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.notEmpty(Collections.emptyList!string(), "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// notEmptyCollectionWithNullCollection
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.notEmpty(cast(Collection!Object) null, "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// notEmptyCollectionWithMessageSupplier
unittest
{
    Assert.notEmpty(Collections.singletonList("foo"), () => "enigma");
}

// notEmptyCollectionWithEmptyCollectionAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.notEmpty(Collections.emptyList!string(), () => "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// notEmptyCollectionWithNullCollectionAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.notEmpty(cast(Collection!Object) null, () => "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// notEmptyCollectionWithEmptyCollectionAndNullMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.notEmpty(Collections.emptyList!string(), nullSupplier());
    });
    assert(e.getMessage() is null);
}

// notEmptyMap
unittest
{
    Assert.notEmpty(Map!(string, string).of("foo", "bar"), "enigma");
}

// notEmptyMapWithNullMap
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.notEmpty(cast(Map!(string, string)) null, "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// notEmptyMapWithEmptyMap
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.notEmpty(Collections.emptyMap!(string, string)(), "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// notEmptyMapWithMessageSupplier
unittest
{
    Assert.notEmpty(Map!(string, string).of("foo", "bar"), () => "enigma");
}

// notEmptyMapWithEmptyMapAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.notEmpty(Collections.emptyMap!(string, string)(), () => "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// notEmptyMapWithNullMapAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.notEmpty(cast(Map!(string, string)) null, () => "enigma");
    });
    assert(e.getMessage().contains("enigma"));
}

// notEmptyMapWithEmptyMapAndNullMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.notEmpty(Collections.emptyMap!(string, string)(), nullSupplier());
    });
    assert(e.getMessage() is null);
}

// isInstanceOf
unittest
{
    Assert.isInstanceOf!string("foo", "enigma");
}

// isInstanceOfWithNullInstance
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { Assert.isInstanceOf!string(null, "enigma"); });
    assert(e.getMessage().contains("enigma: null"));
}

// isInstanceOfWithTypeMismatchAndNullMessage
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isInstanceOf!string(42L, cast(string) null);
    });
    assert(e.getMessage().contains("Object of class [java.lang.Long] must be an instance of class java.lang.String"));
}

// isInstanceOfWithTypeMismatchAndCustomMessage
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isInstanceOf!string(42L, "Custom message");
    });
    assert(e.getMessage().contains("Custom message: java.lang.Long"));
}

// isInstanceOfWithTypeMismatchAndCustomMessageWithSeparator
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isInstanceOf!string(42L, "Custom message:");
    });
    assert(e.getMessage()
            .contains(
                "Custom message: Object of class [java.lang.Long] must be an instance of class " ~ "java.lang.String"));
}

// isInstanceOfWithTypeMismatchAndCustomMessageWithSpace
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isInstanceOf!string(42L, "Custom message for ");
    });
    assert(e.getMessage().contains("Custom message for java.lang.Long"));
}

// isInstanceOfWithMessageSupplier
unittest
{
    Assert.isInstanceOf!string("foo", () => "enigma");
}

// isInstanceOfWithNullInstanceAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isInstanceOf!string(null, () => "enigma");
    });
    assert(e.getMessage().contains("enigma: null"));
}

// isInstanceOfWithTypeMismatchAndNullMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isInstanceOf!string(42L, nullSupplier());
    });
    assert(e.getMessage().contains("Object of class [java.lang.Long] must be an instance of class java.lang.String"));
}

// isInstanceOfWithTypeMismatchAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isInstanceOf!string(42L, () => "enigma");
    });
    assert(e.getMessage().contains("enigma: java.lang.Long"));
}

// isAssignable
unittest
{
    Assert.isAssignable!(Number, Integer)("enigma");
}

// isAssignableWithTypeMismatchAndNullMessage
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isAssignable!(string, int)(cast(string) null);
    });
    assert(e.getMessage().contains("class java.lang.Integer is not assignable to class java.lang.String"));
}

// isAssignableWithTypeMismatchAndCustomMessage
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isAssignable!(string, int)("Custom message");
    });
    assert(e.getMessage().contains("Custom message: class java.lang.Integer"));
}

// isAssignableWithTypeMismatchAndCustomMessageWithSeparator
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isAssignable!(string, int)("Custom message:");
    });
    assert(e.getMessage()
            .contains("Custom message: class java.lang.Integer is not assignable to class java.lang.String"));
}

// isAssignableWithTypeMismatchAndCustomMessageWithSpace
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isAssignable!(string, int)("Custom message for ");
    });
    assert(e.getMessage().contains("Custom message for class java.lang.Integer"));
}

// isAssignableWithMessageSupplier
unittest
{
    Assert.isAssignable!(Number, Integer)(() => "enigma");
}

// isAssignableWithTypeMismatchAndNullMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isAssignable!(string, int)(nullSupplier());
    });
    assert(e.getMessage().contains("class java.lang.Integer is not assignable to class java.lang.String"));
}

// isAssignableWithTypeMismatchAndMessageSupplier
unittest
{
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isAssignable!(string, int)(() => "enigma");
    });
    assert(e.getMessage().contains("enigma: class java.lang.Integer"));
}

// state
unittest
{
    Assert.state(true, "enigma");
}

// stateWithFalseExpression
unittest
{
    auto e = expectThrows!IllegalStateException(() { Assert.state(false, "enigma"); });
    assert(e.getMessage().contains("enigma"));
}

// Flint: the Supplier overloads (R9) and a class instance check.
unittest
{
    Assert.state(true, Supplier!string.of(() => "enigma"));
    auto e = expectThrows!IllegalArgumentException(() {
        Assert.isTrue(false, Supplier!string.of(() => "enigma"));
    });
    assert(e.getMessage() == "enigma");
    Assert.hasText("x", cast(Supplier!string) null);
    Object animal = new Integer;
    Assert.isInstanceOf!Number(animal);
    e = expectThrows!IllegalArgumentException(() { Assert.isInstanceOf!Integer(new Number); });
    assert(e.getMessage().contains("must be an instance of class flint.util.assert_test.Integer"));
}

// Flint (R14): whitespace and text checks on non-ASCII input.
unittest
{
    Assert.hasText("日本", "enigma");
    expectThrows!IllegalArgumentException(() { Assert.hasText("　 ", "enigma"); });
    Assert.hasText(" ", "a no-break space is not whitespace in Java");
    expectThrows!IllegalArgumentException(() {
        Assert.doesNotContain("café 😀", "😀", "enigma");
    });
}
