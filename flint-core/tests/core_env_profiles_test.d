// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/core
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
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
 * spring-core/src/test/java/org/springframework/core/env/ProfilesTests.java.
 *
 * Skipped Java tests: none. `Profiles.of((String[]) null)` passes a null `string[]`, which D cannot tell from an empty
 * variadic call, so ofWhenNullThrowsException and ofWhenEmptyThrowsException assert the same thing.
 */
module flint.core.env_profiles_test;

import flint.core.env : Profiles;
import flint.java.lang : IllegalArgumentException;
import flint.util : StringUtils;
import std.exception : collectException;

@safe:

/// Spring's `MockActiveProfiles`: rejects invalid profile names, so the parser never passes one on.
private bool delegate(string) @safe activeProfiles(string[] profiles...)
{
    auto active = profiles.dup;
    return (string profile) {
        if (!StringUtils.hasText(profile) || profile[0] == '!')
            throw new IllegalArgumentException("Invalid profile [" ~ profile ~ "]");
        foreach (candidate; active)
            if (candidate == profile)
                return true;
        return false;
    };
}

private void assertMalformed(string expression)
{
    auto e = collectException!IllegalArgumentException(Profiles.of(expression));
    assert(e !is null, expression);
    assert(e.msg.length >= 28 && e.msg[0 .. 28] == "Malformed profile expression", e.msg);
}

private void assertOrExpression(Profiles profiles)
{
    assert(profiles.matches(activeProfiles("spring")));
    assert(profiles.matches(activeProfiles("framework")));
    assert(profiles.matches(activeProfiles("spring", "framework")));
    assert(!profiles.matches(activeProfiles("java")));
}

private void assertAndExpression(Profiles profiles)
{
    assert(!profiles.matches(activeProfiles("spring")));
    assert(!profiles.matches(activeProfiles("framework")));
    assert(profiles.matches(activeProfiles("spring", "framework")));
    assert(!profiles.matches(activeProfiles("java")));
}

private void assertOfNotAndExpression(Profiles profiles)
{
    assert(profiles.matches(activeProfiles("spring")));
    assert(profiles.matches(activeProfiles("framework")));
    assert(!profiles.matches(activeProfiles("spring", "framework")));
    assert(profiles.matches(activeProfiles("java")));
}

private void assertOfAndExpressionWithInvertedSingleElement(Profiles profiles)
{
    assert(profiles.matches(activeProfiles("framework")));
    assert(!profiles.matches(activeProfiles("java")));
    assert(!profiles.matches(activeProfiles("spring", "framework")));
    assert(!profiles.matches(activeProfiles("spring")));
}

private void assertOfOrExpressionWithInvertedSingleElement(Profiles profiles)
{
    assert(profiles.matches(activeProfiles("framework")));
    assert(profiles.matches(activeProfiles("java")));
    assert(profiles.matches(activeProfiles("spring", "framework")));
    assert(!profiles.matches(activeProfiles("spring")));
}

private void assertOfNotOrExpression(Profiles profiles)
{
    assert(!profiles.matches(activeProfiles("spring")));
    assert(!profiles.matches(activeProfiles("framework")));
    assert(!profiles.matches(activeProfiles("spring", "framework")));
    assert(profiles.matches(activeProfiles("java")));
}

private void assertComplexExpression(Profiles profiles)
{
    assert(!profiles.matches(activeProfiles("spring")));
    assert(profiles.matches(activeProfiles("spring", "framework")));
    assert(profiles.matches(activeProfiles("spring", "java")));
    assert(!profiles.matches(activeProfiles("java", "framework")));
}

private void assertThatToStringGeneratesValidCompositeProfileExpression(string[] profileExpressions...)
{
    auto profiles = Profiles.of(profileExpressions);
    assert(profiles.matches(activeProfiles("spring", "java")));
    assert(!profiles.matches(activeProfiles("kotlin")));
    auto compositeProfiles = Profiles.of(profileString(profiles));
    assert(compositeProfiles.matches(activeProfiles("spring", "java")));
    assert(!compositeProfiles.matches(activeProfiles("kotlin")));
}

private string profileString(Profiles profiles)
{
    import flint.engine.aot.objects : objectToString;

    return objectToString(cast(Object) profiles);
}

private bool profilesEqual(Profiles a, Profiles b)
{
    import flint.engine.aot.objects : objectEquals;

    return objectEquals(cast(Object) a, cast(Object) b);
}

private size_t profilesHash(Profiles profiles)
{
    import flint.engine.aot.objects : objectToHash;

    return objectToHash(cast(Object) profiles);
}

private void assertEqual(string[] expressions...)
{
    auto profiles1 = Profiles.of(expressions);
    auto profiles2 = Profiles.of(expressions);
    assert(profilesEqual(profiles1, profiles2));
    assert(profilesEqual(profiles2, profiles1));
}

private void assertHashCode(string[] expressions...)
{
    assert(profilesHash(Profiles.of(expressions)) == profilesHash(Profiles.of(expressions)));
}

unittest
{
    // ofWhenNullThrowsException
    string[] none = null;
    const e = collectException!IllegalArgumentException(Profiles.of(none));
    assert(e !is null && e.msg == "Must specify at least one profile expression");
}

unittest
{
    // ofWhenEmptyThrowsException
    const e = collectException!IllegalArgumentException(Profiles.of());
    assert(e !is null && e.msg == "Must specify at least one profile expression");
}

unittest
{
    // ofNullElement
    string nullElement = null;
    const e = collectException!IllegalArgumentException(Profiles.of(nullElement));
    assert(e !is null && e.msg == "Invalid profile expression [null]: must contain text", e.msg);
}

unittest
{
    // ofEmptyElement
    const e = collectException!IllegalArgumentException(Profiles.of("  "));
    assert(e !is null && e.msg == "Invalid profile expression [  ]: must contain text");
}

unittest
{
    // ofSingleElement
    auto profiles = Profiles.of("spring");
    assert(profiles.matches(activeProfiles("spring")));
    assert(!profiles.matches(activeProfiles("framework")));
}

unittest
{
    // ofSingleInvertedElement
    auto profiles = Profiles.of("!spring");
    assert(!profiles.matches(activeProfiles("spring")));
    assert(profiles.matches(activeProfiles("framework")));
}

unittest
{
    // ofMultipleElements
    auto profiles = Profiles.of("spring", "framework");
    assert(profiles.matches(activeProfiles("spring")));
    assert(profiles.matches(activeProfiles("framework")));
    assert(!profiles.matches(activeProfiles("java")));
}

unittest
{
    // ofMultipleElementsWithInverted
    auto profiles = Profiles.of("!spring", "framework");
    assert(!profiles.matches(activeProfiles("spring")));
    assert(profiles.matches(activeProfiles("spring", "framework")));
    assert(profiles.matches(activeProfiles("framework")));
    assert(profiles.matches(activeProfiles("java")));
}

unittest
{
    // ofMultipleElementsAllInverted
    auto profiles = Profiles.of("!spring", "!framework");
    assert(profiles.matches(activeProfiles("spring")));
    assert(profiles.matches(activeProfiles("framework")));
    assert(profiles.matches(activeProfiles("java")));
    assert(!profiles.matches(activeProfiles("spring", "framework")));
    assert(!profiles.matches(activeProfiles("spring", "framework", "java")));
}

unittest
{
    // ofSingleExpression
    auto profiles = Profiles.of("(spring)");
    assert(profiles.matches(activeProfiles("spring")));
    assert(!profiles.matches(activeProfiles("framework")));
}

unittest
{
    // ofSingleExpressionInverted
    auto profiles = Profiles.of("!(spring)");
    assert(!profiles.matches(activeProfiles("spring")));
    assert(profiles.matches(activeProfiles("framework")));
}

unittest
{
    // ofSingleInvertedExpression
    auto profiles = Profiles.of("(!spring)");
    assert(!profiles.matches(activeProfiles("spring")));
    assert(profiles.matches(activeProfiles("framework")));
}

unittest
{
    // ofOrExpression
    assertOrExpression(Profiles.of("(spring | framework)"));
}

unittest
{
    // ofOrExpressionWithoutSpaces
    assertOrExpression(Profiles.of("(spring|framework)"));
}

unittest
{
    // ofOrExpressionWithDoubledOperator
    assertOrExpression(Profiles.of("(spring || framework)"));
}

unittest
{
    // ofAndExpression
    assertAndExpression(Profiles.of("(spring & framework)"));
}

unittest
{
    // ofAndExpressionWithoutSpaces
    assertAndExpression(Profiles.of("(spring&framework)"));
}

unittest
{
    // ofAndExpressionWithoutParentheses
    assertAndExpression(Profiles.of("spring & framework"));
}

unittest
{
    // ofAndExpressionWithDoubledOperator
    assertAndExpression(Profiles.of("(spring && framework)"));
}

unittest
{
    // ofNotAndExpression
    assertOfNotAndExpression(Profiles.of("!(spring & framework)"));
}

unittest
{
    // ofNotAndExpressionWithoutSpaces
    assertOfNotAndExpression(Profiles.of("!(spring&framework)"));
}

unittest
{
    // ofAndExpressionWithInvertedSingleElement
    assertOfAndExpressionWithInvertedSingleElement(Profiles.of("!spring & framework"));
}

unittest
{
    // ofAndExpressionWithInBracketsInvertedSingleElement
    assertOfAndExpressionWithInvertedSingleElement(Profiles.of("(!spring) & framework"));
}

unittest
{
    // ofAndExpressionWithInvertedSingleElementInBrackets
    assertOfAndExpressionWithInvertedSingleElement(Profiles.of("! (spring) & framework"));
}

unittest
{
    // ofAndExpressionWithInvertedSingleElementInBracketsWithoutSpaces
    assertOfAndExpressionWithInvertedSingleElement(Profiles.of("!(spring)&framework"));
}

unittest
{
    // ofAndExpressionWithInvertedSingleElementWithoutSpaces
    assertOfAndExpressionWithInvertedSingleElement(Profiles.of("!spring&framework"));
}

unittest
{
    // ofOrExpressionWithInvertedSingleElementWithoutSpaces
    assertOfOrExpressionWithInvertedSingleElement(Profiles.of("!spring|framework"));
}

unittest
{
    // ofNotOrExpression
    assertOfNotOrExpression(Profiles.of("!(spring | framework)"));
}

unittest
{
    // ofNotOrExpressionWithoutSpaces
    assertOfNotOrExpression(Profiles.of("!(spring|framework)"));
}

unittest
{
    // ofAndExpressionWithDoubleInvertedSingleElement
    assertAndExpression(Profiles.of("!!spring & framework"));
}

unittest
{
    // ofOrExpressionWithDoubleInvertedSingleElement
    assertOrExpression(Profiles.of("!!spring | framework"));
}

unittest
{
    // ofAndExpressionWithTripleInvertedSingleElement
    assertOfAndExpressionWithInvertedSingleElement(Profiles.of("!!!spring & framework"));
}

unittest
{
    // ofComplexExpression
    assertComplexExpression(Profiles.of("(spring & framework) | (spring & java)"));
}

unittest
{
    // ofComplexExpressionWithoutSpaces
    assertComplexExpression(Profiles.of("(spring&framework)|(spring&java)"));
}

unittest
{
    // ofComplexExpressionEnclosedInParentheses
    assertComplexExpression(Profiles.of("((spring & framework) | (spring & java))"));
}

unittest
{
    // malformedExpressions
    assertMalformed("(");
    assertMalformed(")");
    assertMalformed("a & b | c");
}

unittest
{
    // malformedExpressionsWithMissingOperator
    foreach (expression; [
        "dev !prod", "dev (prod)", "(dev) prod", "(dev) (prod)", "(dev) !prod", "!dev (prod)"
    ])
        assertMalformed(expression);
}

unittest
{
    // malformedExpressionsWithMissingOperand
    foreach (expression; [
        "dev &", "dev |", "& dev", "| dev", "&& dev", "|| dev", "(dev &)", "(| dev)", "(dev) &",
        "dev & ()", "dev & !"
    ])
        assertMalformed(expression);
}

unittest
{
    // malformedExpressionsWithUnbalancedParentheses
    foreach (expression; ["dev)", "(dev", "spring&framework)", "((dev)", "(dev))"])
        assertMalformed(expression);
}

unittest
{
    // malformedExpressionsWithWhitespaceSeparatedProfiles
    foreach (expression; [
        "dev prod", "dev\tprod", "!dev prod", "(dev prod)", "dev prod & test", "test | dev prod"
    ])
        assertMalformed(expression);
}

unittest
{
    // sensibleToString
    assert(profileString(Profiles.of("spring")) == "spring");
    assert(profileString(Profiles.of(
            "(spring & framework) | (spring & java)")) == "(spring & framework) | (spring & java)");
    assert(profileString(Profiles.of("(spring&framework)|(spring&java)")) == "(spring&framework)|(spring&java)");
    const springAndFramework = "spring & framework", javaOrKotlin = "java | kotlin";
    assert(profileString(Profiles.of(springAndFramework, javaOrKotlin)) == "(spring & framework) | (java | kotlin)");
    assert(profileString(Profiles.of(javaOrKotlin, springAndFramework)) == "(java | kotlin) | (spring & framework)");
    assert(profileString(Profiles.of("java | kotlin", "spring & framework",
            "cat | dog")) == "(java | kotlin) | (spring & framework) | (cat | dog)");
}

unittest
{
    // toStringGeneratesValidCompositeProfileExpression
    assertThatToStringGeneratesValidCompositeProfileExpression("spring");
    assertThatToStringGeneratesValidCompositeProfileExpression("(spring & kotlin) | (spring & java)");
    assertThatToStringGeneratesValidCompositeProfileExpression("spring & kotlin", "spring & java");
    assertThatToStringGeneratesValidCompositeProfileExpression("spring & kotlin", "spring & java", "cat | dog");
}

unittest
{
    // sensibleEquals
    assertEqual("(spring & framework) | (spring & java)");
    assertEqual("(spring&framework)|(spring&java)");
    assertEqual("spring & framework", "java | kotlin");
    // Ensure order of individual expressions does not affect equals().
    const expression1 = "A | B";
    const expression2 = "C & (D | E)";
    auto profiles1 = Profiles.of(expression1, expression2);
    auto profiles2 = Profiles.of(expression2, expression1);
    assert(profilesEqual(profiles1, profiles2));
    assert(profilesEqual(profiles2, profiles1));
}

unittest
{
    // sensibleHashCode
    assertHashCode("(spring & framework) | (spring & java)");
    assertHashCode("(spring&framework)|(spring&java)");
    assertHashCode("spring & framework", "java | kotlin");
    // Ensure order of individual expressions does not affect hashCode().
    const expression1 = "A | B";
    const expression2 = "C & (D | E)";
    assert(profilesHash(Profiles.of(expression1, expression2)) == profilesHash(Profiles.of(expression2, expression1)));
}

unittest
{
    // equalsAndHashCodeAreNotBasedOnLogicalStructureOfNodesWithinExpressionTree
    auto profiles1 = Profiles.of("A | B");
    auto profiles2 = Profiles.of("B | A");
    assert(profiles1.matches(activeProfiles("A")));
    assert(profiles1.matches(activeProfiles("B")));
    assert(profiles2.matches(activeProfiles("A")));
    assert(profiles2.matches(activeProfiles("B")));
    assert(!profilesEqual(profiles1, profiles2));
    assert(!profilesEqual(profiles2, profiles1));
    assert(profilesHash(profiles1) != profilesHash(profiles2));
}
