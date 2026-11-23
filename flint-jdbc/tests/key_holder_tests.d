/++
Ported from spring-projects/spring-framework v7.1.0,
spring-jdbc/src/test/java/org/springframework/jdbc/support/KeyHolderTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: AssertJ assertions become D asserts; Java's `Map.of`/`singletonMap` rows become
`LinkedHashMap!(string, Any)` rows; `getKeyAs(Integer.class)` is `getKeyAs!int`, so the expected messages name D
types (`[string]`, `[int]`) where Spring names Java classes. `getKey` does not reject a non-numeric key, and a null
key names `Number` rather than the requested type: those assertions wait behind version gates.
+/
module flint.jdbc.key_holder_tests;

import flint.dao : DataRetrievalFailureException, InvalidDataAccessApiUsageException;
import flint.engine.aot.any : Any;
import flint.java.util : LinkedHashMap, Map;
import flint.jdbc.support : GeneratedKeyHolder, KeyHolder;

@safe:

private KeyHolder setUp()
{
    return new GeneratedKeyHolder();
}

/// A key row: Java's `singletonMap`, `emptyMap` and `Map.of`.
private Map!(string, Any) keyRow(Any[string] entries, string[] order)
{
    auto row = new LinkedHashMap!(string, Any);
    foreach (name; order)
        row.put(name, entries[name]);
    return row;
}

private E expectThrows(E : Exception)(scope void delegate() @safe action)
{
    try
        action();
    catch (E ex)
        return ex;
    assert(false, "expected " ~ E.stringof);
}

private bool startsWith(string text, string prefix)
{
    return text.length >= prefix.length && text[0 .. prefix.length] == prefix;
}

@("KeyHolderTests.getKeyForSingleNumericKey")
unittest
{
    auto kh = setUp();
    kh.getKeyList().add(keyRow(["key": Any.of(1)], ["key"]));

    assert(kh.getKey().get!int == 1, "single key should be returned");
}

version (FlintKeyHolderNonNumericKey)
{
    // Behaviour: GeneratedKeyHolder.getKey returns a non-numeric key instead of throwing DataRetrievalFailureException.
    @("KeyHolderTests.getKeyForSingleNonNumericKey")
    unittest
    {
        auto kh = setUp();
        kh.getKeyList().add(keyRow(["key": Any.of("ABC")], ["key"]));

        const ex = expectThrows!DataRetrievalFailureException({ kh.getKey(); });
        assert(ex.msg == "The generated key type is not supported. Unable to cast [string] to [Number].", ex.msg);
    }
}

@("KeyHolderTests.getKeyWithNoKeysInMap")
unittest
{
    auto kh = setUp();
    kh.getKeyList().add(new LinkedHashMap!(string, Any));

    const ex = expectThrows!DataRetrievalFailureException({ kh.getKey(); });
    assert(ex.msg.startsWith("Unable to retrieve the generated key."), ex.msg);
}

@("KeyHolderTests.getKeyWithMultipleKeysInMap")
unittest
{
    auto kh = setUp();
    kh.getKeyList().add(keyRow(["key": Any.of(1), "seq": Any.of(2)], ["key", "seq"]));

    assert(kh.getKeys().size() == 2, "two keys should be in the map");
    const ex = expectThrows!InvalidDataAccessApiUsageException({ kh.getKey(); });
    assert(ex.msg.startsWith("The getKey method should only be used when a single key is returned."), ex.msg);
}

@("KeyHolderTests.getKeyAsStringForSingleKey")
unittest
{
    auto kh = setUp();
    kh.getKeyList().add(keyRow(["key": Any.of("ABC")], ["key"]));

    assert(kh.getKeyAs!string() == "ABC", "single key should be returned");
}

@("KeyHolderTests.getKeyAsWrongType")
unittest
{
    auto kh = setUp();
    kh.getKeyList().add(keyRow(["key": Any.of("ABC")], ["key"]));

    const ex = expectThrows!DataRetrievalFailureException({ kh.getKeyAs!int(); });
    assert(ex.msg == "The generated key type is not supported. Unable to cast [string] to [int].", ex.msg);
}

@("KeyHolderTests.getKeyAsIntegerWithNullValue")
unittest
{
    auto kh = setUp();
    kh.getKeyList().add(keyRow(["key": Any.init], ["key"]));

    const ex = expectThrows!DataRetrievalFailureException({ kh.getKeyAs!int(); });
    version (FlintKeyHolderNullKeyType)
    {
        // Behaviour: getKeyAs!T on a null key reports getKey's "[Number]", not the requested type.
        assert(ex.msg == "The generated key type is not supported. Unable to cast [null] to [int].", ex.msg);
    }
}

@("KeyHolderTests.getKeysWithMultipleKeyRows")
unittest
{
    auto kh = setUp();
    auto m = keyRow(["key": Any.of(1), "seq": Any.of(2)], ["key", "seq"]);
    kh.getKeyList().add(m);
    kh.getKeyList().add(m);

    assert(kh.getKeyList().size() == 2, "two rows should be in the list");
    const ex = expectThrows!InvalidDataAccessApiUsageException({ kh.getKeys(); });
    enum expected = "The getKeys method should only be used when keys for a single row are returned.";
    assert(ex.msg.startsWith(expected), ex.msg);
}
