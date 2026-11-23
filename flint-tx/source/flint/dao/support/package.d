// Ported from spring-framework v7.1.0: spring-tx/src/main/java/org/springframework/dao/support/DataAccessUtils.java
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.

/++
`org.springframework.dao.support`: `DataAccessUtils`, the single-result helpers `JdbcTemplate.queryForObject` and
`JdbcClient` rest on, and the `PersistenceExceptionTranslator` contract with its chaining implementation.

Java's generic methods are D templates over the element type. A Java `null` result is `null` for references and
`T.init` for D value types, which have no null; the `Optional` forms tell an empty result apart from a zero.
`DaoSupport` and `PersistenceExceptionTranslationInterceptor` need beans and AOP and arrive with them.
+/
module flint.dao.support;

import flint.dao : DataAccessException, EmptyResultDataAccessException,
    IncorrectResultSizeDataAccessException, TypeMismatchDataAccessException;
import flint.engine.aot.any : Any;
import flint.java.lang : IllegalArgumentException, RuntimeException;
import flint.java.util : Collection, Iterator, Objects, Optional;
import flint.java.util.stream : Stream;
import std.meta : AliasSeq;

@safe:

/// Interface implemented by Spring integrations with data access technologies that throw runtime exceptions.
interface PersistenceExceptionTranslator
{
    /// Translate the given runtime exception thrown by a persistence framework to a corresponding exception from
    /// Spring's generic `DataAccessException` hierarchy, if possible; `null` when it is not, so that other
    /// translators may have a chance.
    DataAccessException translateExceptionIfPossible(RuntimeException ex);
}

/// A `PersistenceExceptionTranslator` that tries a list of delegates in order.
class ChainedPersistenceExceptionTranslator : PersistenceExceptionTranslator
{
    private PersistenceExceptionTranslator[] delegates;

    /// Add a `PersistenceExceptionTranslator` to the chained delegate list.
    final void addDelegate(PersistenceExceptionTranslator pet)
    {
        if (pet is null)
            throw new IllegalArgumentException("PersistenceExceptionTranslator must not be null");
        delegates ~= pet;
    }

    /// Return all registered `PersistenceExceptionTranslator` delegates, as a copy.
    final PersistenceExceptionTranslator[] getDelegates()
    {
        return delegates.dup;
    }

    /// The first delegate's translation, or `null` when no delegate translates `ex`.
    override DataAccessException translateExceptionIfPossible(RuntimeException ex)
    {
        foreach (pet; delegates)
        {
            auto translatedDex = pet.translateExceptionIfPossible(ex);
            if (translatedDex !is null)
                return translatedDex;
        }
        return null;
    }
}

/// Miscellaneous utility methods for DAO implementations. Useful with any data access technology.
abstract class DataAccessUtils
{
    /// Return a single result object from the given collection, or `null`/`T.init` if the collection is empty or
    /// `null`. Throws `IncorrectResultSizeDataAccessException` if more than one element has been found.
    static T singleResult(T)(Collection!T results)
    {
        if (results is null || results.isEmpty())
            return T.init;
        if (results.size() > 1)
            throw new IncorrectResultSizeDataAccessException(1, sizeOf(results));
        return results.iterator().next();
    }

    /// ditto, for a D array.
    static T singleResult(T)(T[] results)
    {
        if (results.length == 0)
            return T.init;
        if (results.length > 1)
            throw new IncorrectResultSizeDataAccessException(1, sizeOf(results.length));
        return results[0];
    }

    /// Return a single result object from the given stream, or `null`/`T.init` if it is empty or `null`. Reads at
    /// most two elements. Throws `IncorrectResultSizeDataAccessException` if more than one element has been found.
    static T singleResult(T)(Stream!T results)
    {
        if (results is null)
            return T.init;
        auto resultList = results.limit(2).toList();
        if (resultList.size() > 1)
            throw new IncorrectResultSizeDataAccessException(1);
        return resultList.isEmpty() ? T.init : resultList.get(0);
    }

    /// Return a single result object from the given iterator, or `null`/`T.init` if it is empty or `null`.
    /// Throws `IncorrectResultSizeDataAccessException` if more than one element has been found.
    static T singleResult(T)(Iterator!T results)
    {
        if (results is null)
            return T.init;
        T result = results.hasNext() ? results.next() : T.init;
        if (results.hasNext())
            throw new IncorrectResultSizeDataAccessException(1);
        return result;
    }

    /// Return a single result object from the given collection or `Optional.empty()` if the collection is empty
    /// or `null`, or holds only `null`. Throws `IncorrectResultSizeDataAccessException` for more than one element.
    static Optional!T optionalResult(T)(Collection!T results)
    {
        if (results is null || results.isEmpty())
            return Optional!T.empty();
        return Optional!T.ofNullable(singleResult(results));
    }

    /// ditto, typed as a supertype `R` of the elements (Java's `Collection<? extends T>`).
    static Optional!R optionalResult(R, T)(Collection!T results) if (is(T : R) && !is(T == R))
    {
        if (results is null || results.isEmpty())
            return Optional!R.empty();
        return Optional!R.ofNullable(singleResult(results));
    }

    /// ditto, for a D array.
    static Optional!T optionalResult(T)(T[] results)
    {
        if (results.length == 0)
            return Optional!T.empty();
        return Optional!T.ofNullable(singleResult(results));
    }

    /// ditto, for a stream.
    static Optional!T optionalResult(T)(Stream!T results)
    {
        if (results is null)
            return Optional!T.empty();
        auto resultList = results.limit(2).toList();
        if (resultList.size() > 1)
            throw new IncorrectResultSizeDataAccessException(1);
        return resultList.isEmpty() ? Optional!T.empty() : Optional!T.ofNullable(resultList.get(0));
    }

    /// ditto, for an iterator.
    static Optional!T optionalResult(T)(Iterator!T results)
    {
        if (results is null || !results.hasNext())
            return Optional!T.empty();
        T result = results.next();
        if (results.hasNext())
            throw new IncorrectResultSizeDataAccessException(1);
        return Optional!T.ofNullable(result);
    }

    /// Return a single result object from the given collection. Throws `EmptyResultDataAccessException` if no
    /// element has been found, `IncorrectResultSizeDataAccessException` if more than one, and
    /// `TypeMismatchDataAccessException` if the single element is `null`.
    static T requiredSingleResult(T)(Collection!T results)
    {
        if (results is null || results.isEmpty())
            throw new EmptyResultDataAccessException(1);
        if (results.size() > 1)
            throw new IncorrectResultSizeDataAccessException(1, sizeOf(results));
        return required(results.iterator().next());
    }

    /// ditto, for a D array.
    static T requiredSingleResult(T)(T[] results)
    {
        if (results.length == 0)
            throw new EmptyResultDataAccessException(1);
        if (results.length > 1)
            throw new IncorrectResultSizeDataAccessException(1, sizeOf(results.length));
        return required(results[0]);
    }

    /// Return a single result object from the given collection, which may be `null`. Throws
    /// `EmptyResultDataAccessException` if no element has been found and `IncorrectResultSizeDataAccessException`
    /// if more than one.
    static T nullableSingleResult(T)(Collection!T results)
    {
        if (results is null || results.isEmpty())
            throw new EmptyResultDataAccessException(1);
        if (results.size() > 1)
            throw new IncorrectResultSizeDataAccessException(1, sizeOf(results));
        return results.iterator().next();
    }

    /// ditto, for a D array.
    static T nullableSingleResult(T)(T[] results)
    {
        if (results.length == 0)
            throw new EmptyResultDataAccessException(1);
        if (results.length > 1)
            throw new IncorrectResultSizeDataAccessException(1, sizeOf(results.length));
        return results[0];
    }

    /// Return a unique result object from the given collection, or `null`/`T.init` if it is empty or `null`. The
    /// collection may hold the same instance several times. Throws `IncorrectResultSizeDataAccessException` if
    /// it holds more than one distinct instance.
    static T uniqueResult(T)(Collection!T results)
    {
        if (results is null || results.isEmpty())
            return T.init;
        if (!hasUniqueObject(results.toArray()))
            throw new IncorrectResultSizeDataAccessException(1, sizeOf(results));
        return results.iterator().next();
    }

    /// ditto, for a D array.
    static T uniqueResult(T)(T[] results)
    {
        if (results.length == 0)
            return T.init;
        if (!hasUniqueObject(results))
            throw new IncorrectResultSizeDataAccessException(1, sizeOf(results.length));
        return results[0];
    }

    /// Return a unique result object from the given collection. Throws `EmptyResultDataAccessException` if no
    /// element has been found, `IncorrectResultSizeDataAccessException` if it holds more than one distinct
    /// instance, and `TypeMismatchDataAccessException` if the unique element is `null`.
    static T requiredUniqueResult(T)(Collection!T results)
    {
        if (results is null || results.isEmpty())
            throw new EmptyResultDataAccessException(1);
        if (!hasUniqueObject(results.toArray()))
            throw new IncorrectResultSizeDataAccessException(1, sizeOf(results));
        return required(results.iterator().next());
    }

    /// ditto, for a D array.
    static T requiredUniqueResult(T)(T[] results)
    {
        if (results.length == 0)
            throw new EmptyResultDataAccessException(1);
        if (!hasUniqueObject(results))
            throw new IncorrectResultSizeDataAccessException(1, sizeOf(results.length));
        return required(results[0]);
    }

    /++
    Return a unique result object from the given collection, converted to `T` (R4: Java's
    `objectResult(Collection<?>, Class<T>)`). A value of type `T` is returned as it is; `string` takes any scalar
    or string value as text; a numeric `T` takes any numeric value that fits. Throws the `requiredUniqueResult`
    exceptions, and `TypeMismatchDataAccessException` when the value does not convert.
    +/
    static T objectResult(T, E)(Collection!E results)
    {
        return convertValue!T(requiredUniqueResult(results));
    }

    /// ditto, for a D array.
    static T objectResult(T, E)(E[] results)
    {
        return convertValue!T(requiredUniqueResult(results));
    }

    /// Return a unique `int` result from the given collection. Throws the `objectResult` exceptions.
    static int intResult(E)(Collection!E results)
    {
        return objectResult!int(results);
    }

    /// ditto, for a D array.
    static int intResult(E)(E[] results)
    {
        return objectResult!int(results);
    }

    /// Return a unique `long` result from the given collection. Throws the `objectResult` exceptions.
    static long longResult(E)(Collection!E results)
    {
        return objectResult!long(results);
    }

    /// ditto, for a D array.
    static long longResult(E)(E[] results)
    {
        return objectResult!long(results);
    }

    /// Return a translated exception if this is appropriate, otherwise return the given exception as-is.
    static RuntimeException translateIfNecessary(RuntimeException rawException, PersistenceExceptionTranslator pet)
    {
        if (pet is null)
            throw new IllegalArgumentException("PersistenceExceptionTranslator must not be null");
        auto dae = pet.translateExceptionIfPossible(rawException);
        return dae !is null ? dae : rawException;
    }
}

private int sizeOf(T)(Collection!T results)
{
    return sizeOf(results.size());
}

private int sizeOf(size_t length) pure nothrow @nogc
{
    return length > int.max ? int.max : cast(int) length;
}

private T required(T)(T result)
{
    static if (__traits(compiles, Objects.isNull(result)))
    {
        if (Objects.isNull(result) || isNullAny(result))
            throw new TypeMismatchDataAccessException("Result value is null but no null value expected");
    }
    return result;
}

private bool isNullAny(T)(T value)
{
    static if (is(T == Any))
        return value.isNull;
    else
        return false;
}

/// `CollectionUtils.hasUniqueObject`: every element is the first one, by identity for references.
private bool hasUniqueObject(T)(T[] elements)
{
    foreach (element; elements[1 .. $])
    {
        static if (is(T == class) || is(T == interface))
        {
            if (element !is elements[0])
                return false;
        }
        else static if (is(T == Any))
        {
            if (element.typeName != elements[0].typeName || !sameAny(element, elements[0]))
                return false;
        }
        else
        {
            if (element != elements[0])
                return false;
        }
    }
    return true;
}

private bool sameAny(Any left, Any right)
{
    if (left.isNull || right.isNull)
        return left.isNull && right.isNull;
    if (auto object = left.asObject())
        return object is right.asObject();
    static foreach (S; ScalarTypes)
    {
        if (left.typeName == Any.of(S.init).typeName)
            return left.get!S == right.get!S;
    }
    return false;
}

private alias ScalarTypes = AliasSeq!(bool, byte, short, int, long, ubyte, ushort, uint, ulong, float, double, string);

/// Convert a result value to `T`, as `DataAccessUtils.objectResult` does.
private T convertValue(T, E)(E value)
{
    static if (is(E == Any))
        return convertAny!T(value);
    else static if (is(E : T))
        return value;
    else
        return convertAny!T(Any.of(value));
}

/// Convert a boxed result value to `T`.
private T convertAny(T)(Any value)
{
    if (value.typeName == Any.of(T.init).typeName)
        return value.get!T;
    static if (is(T == string))
    {
        static foreach (S; ScalarTypes)
        {
            if (value.typeName == Any.of(S.init).typeName)
                return toText(value.get!S);
        }
    }
    else static if (__traits(isArithmetic, T))
    {
        static foreach (S; ScalarTypes)
        {
            static if (__traits(isArithmetic, S))
            {
                if (value.typeName == Any.of(S.init).typeName)
                    return convertNumber!T(value.get!S);
            }
        }
    }
    throw new TypeMismatchDataAccessException(
            "Result object is of type [" ~ value.typeName
            ~ "] and could not be converted to required type [" ~ T.stringof ~ "]");
}

/// `NumberUtils.convertNumberToTargetClass`: integral targets reject values that do not fit.
private T convertNumber(T, S)(S number)
{
    static if (__traits(isIntegral, T) && __traits(isFloating, S))
    {
        if (number != number || number < T.min || number > T.max || number != cast(long) number)
            throw new TypeMismatchDataAccessException("Could not convert number [" ~ toText(
                    number) ~ "] of type [" ~ S.stringof ~ "] to target class [" ~ T.stringof ~ "]: overflow");
        return cast(T) number;
    }
    else static if (__traits(isIntegral, T) && __traits(isIntegral, S))
    {
        static if (S.min < 0 && T.min == 0)
            const negative = number < 0;
        else
            enum negative = false;
        if (negative || (S.sizeof >= T.sizeof && number > T.max) || (S.min < 0 && T.min < 0 && number < T.min))
            throw new TypeMismatchDataAccessException("Could not convert number [" ~ toText(
                    number) ~ "] of type [" ~ S.stringof ~ "] to target class [" ~ T.stringof ~ "]: overflow");
        return cast(T) number;
    }
    else
        return cast(T) number;
}

private string toText(S)(S value)
{
    import flint.engine.aot.text : decimal, doubleText;

    static if (is(S == string))
        return value;
    else static if (is(S == bool))
        return value ? "true" : "false";
    else static if (__traits(isFloating, S))
        return doubleText(value);
    else static if (__traits(isUnsigned, S))
        return decimal(cast(ulong) value);
    else
        return decimal(cast(long) value);
}
