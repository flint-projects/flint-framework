/*
 * Copyright 2002-present the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by the Flint authors: ported from spring-framework v7.1.0,
 * spring-core/src/test/java/org/springframework/core/SimpleAliasRegistryTests.java.
 *
 * Skipped Java tests:
 * - removeNullAlias: asserts the NullPointerException ConcurrentHashMap throws for a null key; a null D string is an
 *   ordinary (empty) key, so removeAlias(null) reports "No alias '' registered".
 * The two @ParameterizedTest methods run their three @ValueSource cases in a loop.
 */
module flint.core.alias_test;

import flint.core : SimpleAliasRegistry;
import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.util : StringValueResolver;
import std.exception : collectException;

@safe:

private enum REAL_NAME = "real_name";
private enum NICKNAME = "nickname";
private enum NAME1 = "name1";
private enum NAME2 = "name2";
private enum NAME3 = "name3";
private enum NAME4 = "name4";
private enum NAME5 = "name5";
private enum ALIAS1 = "alias1";
private enum ALIAS2 = "alias2";
private enum ALIAS3 = "alias3";
private enum ALIAS4 = "alias4";
private enum ALIAS5 = "alias5";

/// Exposes the protected `checkForAliasCircle`, which Java's same-package test calls directly.
private class TestAliasRegistry : SimpleAliasRegistry
{
    void callCheckForAliasCircle(string name, string alias_)
    {
        checkForAliasCircle(name, alias_);
    }
}

/// Replaces each value with a supplied placeholder, otherwise returns the original value.
private class StubStringValueResolver : StringValueResolver
{
    private string[string] placeholders;

    this(string[string] placeholders = null)
    {
        this.placeholders = placeholders;
    }

    string resolveStringValue(string str)
    {
        return placeholders.get(str, str);
    }
}

private bool containsExactlyInAnyOrder(string[] actual, string[] expected...)
{
    if (actual.length != expected.length)
        return false;
    foreach (e; expected)
    {
        bool found;
        foreach (a; actual)
            found |= a == e;
        if (!found)
            return false;
    }
    return true;
}

private bool contains(string text, string part)
{
    import std.string : indexOf;

    return text.indexOf(part) >= 0;
}

unittest
{
    // aliasChaining
    auto registry = new SimpleAliasRegistry;
    registry.registerAlias(NAME1, ALIAS1);
    registry.registerAlias(ALIAS1, ALIAS2);
    registry.registerAlias(ALIAS2, ALIAS3);
    assert(registry.hasAlias(NAME1, ALIAS1));
    assert(registry.hasAlias(NAME1, ALIAS2));
    assert(registry.hasAlias(NAME1, ALIAS3));
    assert(registry.canonicalName(ALIAS1) == NAME1);
    assert(registry.canonicalName(ALIAS2) == NAME1);
    assert(registry.canonicalName(ALIAS3) == NAME1);
}

unittest
{
    // aliasChainingWithMultipleAliases
    auto registry = new SimpleAliasRegistry;
    registry.registerAlias(NAME1, ALIAS1);
    registry.registerAlias(NAME1, ALIAS2);
    assert(registry.hasAlias(NAME1, ALIAS1));
    assert(registry.hasAlias(NAME1, ALIAS2));
    registry.registerAlias(REAL_NAME, NAME1);
    assert(registry.hasAlias(REAL_NAME, NAME1));
    assert(registry.hasAlias(REAL_NAME, ALIAS1));
    assert(registry.hasAlias(REAL_NAME, ALIAS2));
    registry.registerAlias(NAME1, ALIAS3);
    foreach (alias_; [NAME1, ALIAS1, ALIAS2, ALIAS3])
        assert(registry.hasAlias(REAL_NAME, alias_));
}

unittest
{
    // removeNonExistentAlias
    auto registry = new SimpleAliasRegistry;
    const alias_ = NICKNAME;
    assert(!registry.hasAlias(REAL_NAME, alias_));
    const e = collectException!IllegalStateException(registry.removeAlias(alias_));
    assert(e !is null && e.msg == "No alias 'nickname' registered");
}

unittest
{
    // removeExistingAlias
    auto registry = new SimpleAliasRegistry;
    registry.registerAlias(REAL_NAME, NICKNAME);
    assert(registry.hasAlias(REAL_NAME, NICKNAME));
    registry.removeAlias(NICKNAME);
    assert(!registry.hasAlias(REAL_NAME, NICKNAME));
}

unittest
{
    // isAlias
    auto registry = new SimpleAliasRegistry;
    registry.registerAlias(REAL_NAME, NICKNAME);
    assert(registry.isAlias(NICKNAME));
    assert(!registry.isAlias(REAL_NAME));
    assert(!registry.isAlias("bogus"));
}

unittest
{
    // getAliases
    auto registry = new SimpleAliasRegistry;
    assert(registry.getAliases(NAME1).length == 0);
    registry.registerAlias(NAME1, ALIAS1);
    assert(registry.getAliases(NAME1) == [ALIAS1]);
    registry.registerAlias(ALIAS1, ALIAS2);
    registry.registerAlias(ALIAS2, ALIAS3);
    assert(containsExactlyInAnyOrder(registry.getAliases(NAME1), ALIAS1, ALIAS2, ALIAS3));
    assert(containsExactlyInAnyOrder(registry.getAliases(ALIAS1), ALIAS2, ALIAS3));
    assert(registry.getAliases(ALIAS2) == [ALIAS3]);
    assert(registry.getAliases(ALIAS3).length == 0);
}

unittest
{
    // checkForAliasCircle
    auto registry = new TestAliasRegistry;
    // No aliases registered, so no cycles possible.
    registry.callCheckForAliasCircle(NAME1, ALIAS1);
    registry.registerAlias(NAME1, ALIAS1); // ALIAS1 -> NAME1
    // No cycles possible.
    registry.callCheckForAliasCircle(NAME1, ALIAS1);
    // NAME1 -> ALIAS1 -> NAME1
    auto e = collectException!IllegalStateException(registry.registerAlias(ALIAS1, NAME1));
    assert(e !is null && contains(e.msg, "'alias1' is a direct or indirect alias for 'name1'"), e.msg);
    registry.registerAlias(ALIAS1, ALIAS2); // ALIAS2 -> ALIAS1 -> NAME1
    // NAME1 -> ALIAS1 -> ALIAS2 -> NAME1
    e = collectException!IllegalStateException(registry.registerAlias(ALIAS2, NAME1));
    assert(e !is null && contains(e.msg, "'alias2' is a direct or indirect alias for 'name1'"), e.msg);
}

unittest
{
    // resolveAliasesPreconditions
    auto registry = new SimpleAliasRegistry;
    const e = collectException!IllegalArgumentException(registry.resolveAliases(null));
    assert(e !is null && e.msg == "StringValueResolver must not be null");
}

unittest
{
    // resolveAliasesWithoutPlaceholderReplacement
    auto registry = new SimpleAliasRegistry;
    StringValueResolver valueResolver = new StubStringValueResolver;
    registry.registerAlias(NAME1, ALIAS1);
    registry.registerAlias(NAME1, ALIAS3);
    registry.registerAlias(NAME2, ALIAS2);
    registry.registerAlias(NAME2, ALIAS4);
    assert(containsExactlyInAnyOrder(registry.getAliases(NAME1), ALIAS1, ALIAS3));
    assert(containsExactlyInAnyOrder(registry.getAliases(NAME2), ALIAS2, ALIAS4));
    registry.resolveAliases(valueResolver);
    assert(containsExactlyInAnyOrder(registry.getAliases(NAME1), ALIAS1, ALIAS3));
    assert(containsExactlyInAnyOrder(registry.getAliases(NAME2), ALIAS2, ALIAS4));
    registry.removeAlias(ALIAS1);
    registry.resolveAliases(valueResolver);
    assert(registry.getAliases(NAME1) == [ALIAS3]);
    assert(containsExactlyInAnyOrder(registry.getAliases(NAME2), ALIAS2, ALIAS4));
}

unittest
{
    // resolveAliasesWithPlaceholderReplacement
    auto registry = new SimpleAliasRegistry;
    StringValueResolver valueResolver = new StubStringValueResolver([NAME1: NAME2, ALIAS1: ALIAS2]);
    registry.registerAlias(NAME1, ALIAS1);
    assert(registry.getAliases(NAME1) == [ALIAS1]);
    registry.resolveAliases(valueResolver);
    assert(registry.getAliases(NAME1).length == 0);
    assert(registry.getAliases(NAME2) == [ALIAS2]);
    registry.removeAlias(ALIAS2);
    assert(registry.getAliases(NAME1).length == 0);
    assert(registry.getAliases(NAME2).length == 0);
}

unittest
{
    // resolveAliasesWithPlaceholderReplacementConflict
    auto registry = new SimpleAliasRegistry;
    StringValueResolver valueResolver = new StubStringValueResolver([ALIAS1: ALIAS2]);
    registry.registerAlias(NAME1, ALIAS1);
    registry.registerAlias(NAME2, ALIAS2);
    // Original state: ALIAS1 -> NAME1, ALIAS2 -> NAME2.
    // After processing ALIAS1 -> NAME1: ALIAS2 -> NAME1 conflicts with the existing ALIAS2 -> NAME2.
    const e = collectException!IllegalStateException(registry.resolveAliases(valueResolver));
    assert(e !is null && e.msg == "Cannot register resolved alias 'alias2' (original: 'alias1') for name 'name1': "
            ~ "It is already registered for name 'name2'.", e.msg);
}

unittest
{
    // resolveAliasesWithPlaceholderReplacementCircularReference
    auto registry = new SimpleAliasRegistry;
    StringValueResolver valueResolver = new StubStringValueResolver([NAME1: ALIAS2]);
    registry.registerAlias(NAME1, ALIAS1);
    registry.registerAlias(ALIAS1, ALIAS2);
    // Original state: ALIAS1 -> NAME1, ALIAS2 -> ALIAS1.
    // After processing ALIAS1 -> NAME1: ALIAS1 -> ALIAS2 is circular, since ALIAS2 already points to ALIAS1.
    auto e = collectException!IllegalStateException(registry.resolveAliases(valueResolver));
    assert(e !is null && contains(e.msg, "'alias2' is a direct or indirect alias for 'alias1'"), e.msg);
}

unittest
{
    // resolveAliasesWithComplexPlaceholderReplacementWithAliasSwitching
    foreach (aliasX; ["alias4", "test", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"])
    {
        auto registry = new SimpleAliasRegistry;
        StringValueResolver valueResolver = new StubStringValueResolver([
            ALIAS3: ALIAS1,
            aliasX: ALIAS5,
            ALIAS5: ALIAS2
        ]);
        // Since SimpleAliasRegistry processes aliases in declaration order, ALIAS5 is registered before aliasX.
        registry.registerAlias(NAME3, ALIAS3);
        registry.registerAlias(NAME5, ALIAS5);
        registry.registerAlias(NAME4, aliasX);
        // Final state: ALIAS1 -> NAME3, ALIAS2 -> NAME5, ALIAS5 -> NAME4.
        registry.resolveAliases(valueResolver);
        assert(registry.getAliases(NAME3) == [ALIAS1], aliasX);
        assert(registry.getAliases(NAME4) == [ALIAS5], aliasX);
        assert(registry.getAliases(NAME5) == [ALIAS2], aliasX);
    }
}

unittest
{
    // resolveAliasesWithComplexPlaceholderReplacementWithAliasAndNameSwitching
    foreach (aliasX; ["alias4", "test", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"])
    {
        auto registry = new SimpleAliasRegistry;
        StringValueResolver valueResolver = new StubStringValueResolver([
            ALIAS3: ALIAS1,
            aliasX: ALIAS5,
            ALIAS5: ALIAS2,
            NAME3: NAME4,
            NAME4: NAME3
        ]);
        registry.registerAlias(NAME3, ALIAS3);
        registry.registerAlias(NAME5, ALIAS5);
        registry.registerAlias(NAME4, aliasX);
        // Final state: ALIAS1 -> NAME4, ALIAS2 -> NAME5, ALIAS5 -> NAME3.
        registry.resolveAliases(valueResolver);
        assert(registry.getAliases(NAME3) == [ALIAS5], aliasX);
        assert(registry.getAliases(NAME4) == [ALIAS1], aliasX);
        assert(registry.getAliases(NAME5) == [ALIAS2], aliasX);
    }
}
