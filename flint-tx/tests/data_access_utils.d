// Ported from spring-framework v7.1.0: spring-tx/src/test/java/org/springframework/dao/support/DataAccessUtilsTests.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
module flint.dao.data_access_utils_test;

import flint.dao : DataAccessException, EmptyResultDataAccessException, IncorrectResultSizeDataAccessException,
    InvalidDataAccessApiUsageException, TypeMismatchDataAccessException;
import flint.dao.support : DataAccessUtils, PersistenceExceptionTranslator;
import flint.java.lang : RuntimeException;
import flint.java.util : ArrayList, Collection, HashSet, Optional;

@safe:

private void throwsSize(E : IncorrectResultSizeDataAccessException = IncorrectResultSizeDataAccessException)(
        scope void delegate() @safe action, int expectedSize, int actualSize = int.min)
{
    try
    {
        action();
        assert(false, "expected " ~ E.stringof);
    }
    catch (E ex)
    {
        assert(ex.getExpectedSize() == expectedSize, "expected size");
        if (actualSize != int.min)
            assert(ex.getActualSize() == actualSize, "actual size");
    }
}

private void throwsMismatch(scope void delegate() @safe action)
{
    try
    {
        action();
        assert(false, "expected TypeMismatchDataAccessException");
    }
    catch (TypeMismatchDataAccessException)
    {
    }
}

@("DataAccessUtilsTests.withEmptyCollection")
unittest
{
    Collection!string col = new HashSet!string;
    assert(DataAccessUtils.uniqueResult(col) is null);
    assert(DataAccessUtils.singleResult(col) is null);
    assert(DataAccessUtils.singleResult(col.stream()) is null);
    assert(DataAccessUtils.singleResult(col.iterator()) is null);
    assert(DataAccessUtils.optionalResult(col).isEmpty());
    assert(DataAccessUtils.optionalResult(col.stream()).isEmpty());
    assert(DataAccessUtils.optionalResult(col.iterator()).isEmpty());
    throwsSize!EmptyResultDataAccessException(() { DataAccessUtils.requiredSingleResult(col); }, 1, 0);
    throwsSize!EmptyResultDataAccessException(() { DataAccessUtils.requiredUniqueResult(col); }, 1, 0);
    throwsSize(() { DataAccessUtils.objectResult!string(col); }, 1, 0);
    throwsSize(() { DataAccessUtils.intResult(col); }, 1, 0);
    throwsSize(() { DataAccessUtils.longResult(col); }, 1, 0);
}

@("DataAccessUtilsTests.withTooLargeCollection")
unittest
{
    Collection!string col = new HashSet!string;
    col.add("test1");
    col.add("test2");
    throwsSize(() { DataAccessUtils.uniqueResult(col); }, 1, 2);
    throwsSize(() { DataAccessUtils.requiredUniqueResult(col); }, 1, 2);
    throwsSize(() { DataAccessUtils.objectResult!string(col); }, 1, 2);
    throwsSize(() { DataAccessUtils.intResult(col); }, 1, 2);
    throwsSize(() { DataAccessUtils.longResult(col); }, 1, 2);
    throwsSize(() { DataAccessUtils.requiredSingleResult(col); }, 1, 2);
    throwsSize(() { DataAccessUtils.singleResult(col); }, 1, 2);
    throwsSize(() { DataAccessUtils.singleResult(col.stream()); }, 1);
    throwsSize(() { DataAccessUtils.singleResult(col.iterator()); }, 1);
    throwsSize(() { DataAccessUtils.optionalResult(col); }, 1, 2);
    throwsSize(() { DataAccessUtils.optionalResult(col.stream()); }, 1);
    throwsSize(() { DataAccessUtils.optionalResult(col.iterator()); }, 1);
}

@("DataAccessUtilsTests.withNullValueInCollection")
unittest
{
    Collection!string col = new HashSet!string;
    col.add(null);
    assert(DataAccessUtils.uniqueResult(col) is null);
    assert(DataAccessUtils.singleResult(col) is null);
    assert(DataAccessUtils.singleResult(col.stream()) is null);
    assert(DataAccessUtils.singleResult(col.iterator()) is null);
    assert(DataAccessUtils.optionalResult(col).isEmpty());
    assert(DataAccessUtils.optionalResult(col.stream()).isEmpty());
    assert(DataAccessUtils.optionalResult(col.iterator()).isEmpty());
    throwsMismatch(() { DataAccessUtils.requiredSingleResult(col); });
    throwsMismatch(() { DataAccessUtils.requiredUniqueResult(col); });
    throwsMismatch(() { DataAccessUtils.objectResult!string(col); });
    throwsMismatch(() { DataAccessUtils.intResult(col); });
    throwsMismatch(() { DataAccessUtils.longResult(col); });
}

private class Shape
{
}

private final class Circle : Shape
{
}

@("DataAccessUtilsTests.optionalResultWithSupertypeTargetType")
unittest
{
    // D has no CharSequence; a class and its subclass stand for String and CharSequence.
    auto circle = new Circle;
    Collection!Circle col = new ArrayList!Circle;
    col.add(circle);
    Optional!Shape fromCollection = DataAccessUtils.optionalResult!Shape(col);
    assert(fromCollection.isPresent() && fromCollection.get() is circle);
}

@("DataAccessUtilsTests.withInteger")
unittest
{
    Collection!int col = new HashSet!int;
    col.add(5);
    assert(DataAccessUtils.uniqueResult(col) == 5);
    assert(DataAccessUtils.requiredUniqueResult(col) == 5);
    assert(DataAccessUtils.objectResult!int(col) == 5);
    assert(DataAccessUtils.objectResult!string(col) == "5");
    assert(DataAccessUtils.intResult(col) == 5);
    assert(DataAccessUtils.longResult(col) == 5);
    assert(DataAccessUtils.requiredSingleResult(col) == 5);
    assert(DataAccessUtils.singleResult(col) == 5);
    assert(DataAccessUtils.singleResult(col.stream()) == 5);
    assert(DataAccessUtils.singleResult(col.iterator()) == 5);
    assert(DataAccessUtils.optionalResult(col) == Optional!int.of(5));
    assert(DataAccessUtils.optionalResult(col.stream()) == Optional!int.of(5));
    assert(DataAccessUtils.optionalResult(col.iterator()) == Optional!int.of(5));
}

@("DataAccessUtilsTests.withSameIntegerInstanceTwice")
unittest
{
    Collection!int col = new ArrayList!int;
    col.add(5);
    col.add(5);
    assert(DataAccessUtils.uniqueResult(col) == 5);
    assert(DataAccessUtils.requiredUniqueResult(col) == 5);
    assert(DataAccessUtils.objectResult!int(col) == 5);
    assert(DataAccessUtils.objectResult!string(col) == "5");
    assert(DataAccessUtils.intResult(col) == 5);
    assert(DataAccessUtils.longResult(col) == 5);
}

private final class Boxed
{
    int value;

    this(int value)
    {
        this.value = value;
    }
}

@("DataAccessUtilsTests.withEquivalentIntegerInstanceTwice")
unittest
{
    // Java compares the elements by identity, and two boxed 555s are distinct objects. D's int has no identity,
    // so two distinct objects holding equal values show the same rule.
    Collection!Boxed col = new ArrayList!Boxed;
    col.add(new Boxed(555));
    col.add(new Boxed(555));
    throwsSize(() { DataAccessUtils.uniqueResult(col); }, 1, 2);
}

@("DataAccessUtilsTests.withLong")
unittest
{
    Collection!long col = new HashSet!long;
    col.add(5L);
    assert(DataAccessUtils.uniqueResult(col) == 5L);
    assert(DataAccessUtils.requiredUniqueResult(col) == 5L);
    assert(DataAccessUtils.objectResult!long(col) == 5L);
    assert(DataAccessUtils.objectResult!string(col) == "5");
    assert(DataAccessUtils.intResult(col) == 5);
    assert(DataAccessUtils.longResult(col) == 5);
    assert(DataAccessUtils.requiredSingleResult(col) == 5L);
    assert(DataAccessUtils.singleResult(col) == 5L);
    assert(DataAccessUtils.singleResult(col.stream()) == 5L);
    assert(DataAccessUtils.singleResult(col.iterator()) == 5L);
    assert(DataAccessUtils.optionalResult(col) == Optional!long.of(5L));
    assert(DataAccessUtils.optionalResult(col.stream()) == Optional!long.of(5L));
    assert(DataAccessUtils.optionalResult(col.iterator()) == Optional!long.of(5L));
}

@("DataAccessUtilsTests.withString")
unittest
{
    Collection!string col = new HashSet!string;
    col.add("test1");
    assert(DataAccessUtils.uniqueResult(col) == "test1");
    assert(DataAccessUtils.requiredUniqueResult(col) == "test1");
    assert(DataAccessUtils.objectResult!string(col) == "test1");
    assert(DataAccessUtils.requiredSingleResult(col) == "test1");
    assert(DataAccessUtils.singleResult(col) == "test1");
    assert(DataAccessUtils.singleResult(col.stream()) == "test1");
    assert(DataAccessUtils.singleResult(col.iterator()) == "test1");
    assert(DataAccessUtils.optionalResult(col) == Optional!string.of("test1"));
    assert(DataAccessUtils.optionalResult(col.stream()) == Optional!string.of("test1"));
    assert(DataAccessUtils.optionalResult(col.iterator()) == Optional!string.of("test1"));
    throwsMismatch(() { DataAccessUtils.intResult(col); });
    throwsMismatch(() { DataAccessUtils.longResult(col); });
}

// DataAccessUtilsTests.withDate waits for java.util.Date in flint:java.

/// The upstream test fixture `MapPersistenceExceptionTranslator`.
private final class MapPersistenceExceptionTranslator : PersistenceExceptionTranslator
{
    private DataAccessException[RuntimeException] translations;

    void addTranslation(RuntimeException in_, DataAccessException out_)
    {
        translations[in_] = out_;
    }

    override DataAccessException translateExceptionIfPossible(RuntimeException ex)
    {
        auto found = ex in translations;
        return found is null ? null : *found;
    }
}

@("DataAccessUtilsTests.exceptionTranslationWithNoTranslation")
unittest
{
    auto mpet = new MapPersistenceExceptionTranslator;
    auto in_ = new RuntimeException();
    assert(DataAccessUtils.translateIfNecessary(in_, mpet) is in_);
}

@("DataAccessUtilsTests.exceptionTranslationWithTranslation")
unittest
{
    auto mpet = new MapPersistenceExceptionTranslator;
    auto in_ = new RuntimeException("in");
    auto out_ = new InvalidDataAccessApiUsageException("out");
    mpet.addTranslation(in_, out_);
    assert(DataAccessUtils.translateIfNecessary(in_, mpet) is out_);
}
