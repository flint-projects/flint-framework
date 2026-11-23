// Ported from spring-framework v7.1.0: spring-core/src/test/java/org/springframework/util
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/++
Port of spring-core's `org.springframework.util.StringUtilsTests` (v7.1.0): one `unittest` per Java test method,
each starting with a `// <JavaTestName>` comment. Parameterized tests run their rows in one block.

Skipped Java tests (15), all `java.util.Locale` (excluded from the port, jvm-platform):
parseLocaleStringSunnyDay, parseLocaleStringWithEmptyLocaleStringYieldsNullLocale,
parseLocaleWithMultiSpecialCharactersInVariant, parseLocaleWithMultiValuedVariant,
parseLocaleWithMultiValuedVariantUsingSpacesAsSeparators,
parseLocaleWithMultiValuedVariantUsingMixtureOfUnderscoresAndSpacesAsSeparators, parseLocaleWithInvalidCharacters,
parseLocaleWithSameLowercaseTokenForLanguageAndCountry, parseLocaleWithVariantContainingCountryCode,
parseJava7Variant, availableLocalesWithLocaleString, availableLocalesWithLanguageTag, invalidLocaleWithLocaleString,
invalidLocaleWithLanguageTag, parseLocaleStringWithEmptyCountryAndVariant.

Partially ported: truncateSurrogatePairs leaves out the rows with unpaired surrogates (not representable in valid
UTF-8) and the `StringBuilder` variant; quoteIfString uses an `int` for Java's boxed `5`.
+/
module flint.util.string_utils_test;

import flint.java.lang : IllegalArgumentException;
import flint.java.util : Collections;
import flint.util : StringUtils;
import flint.util.test_support : contains, expectThrows;

@safe:

// hasLengthForValidValues
unittest
{
    foreach (value; ["text", "  text  ", "  ", "\t", "\n text"])
        assert(StringUtils.hasLength(value));
}

// hasLengthForInvalidValues
unittest
{
    assert(!StringUtils.hasLength(null));
    assert(!StringUtils.hasLength(""));
}

// hasTextForValidValues
unittest
{
    foreach (value; ["text", "  text  ", "\n text"])
        assert(StringUtils.hasText(value));
}

// hasTextForInvalidValues
unittest
{
    foreach (value; [null, "", "  ", "\t"])
        assert(!StringUtils.hasText(value));
}

// containsWhitespace
unittest
{
    assert(!StringUtils.containsWhitespace(null));
    assert(!StringUtils.containsWhitespace(""));
    assert(!StringUtils.containsWhitespace("a"));
    assert(!StringUtils.containsWhitespace("abc"));
    assert(StringUtils.containsWhitespace(" "));
    assert(StringUtils.containsWhitespace("\t"));
    assert(StringUtils.containsWhitespace("\n"));
    assert(StringUtils.containsWhitespace(" a"));
    assert(StringUtils.containsWhitespace("abc "));
    assert(StringUtils.containsWhitespace("a b"));
    assert(StringUtils.containsWhitespace("a  b"));
}

// trimWhitespace
deprecated unittest
{
    assert(StringUtils.trimWhitespace(null) is null);
    assert(StringUtils.trimWhitespace("") == "");
    assert(StringUtils.trimWhitespace(" ") == "");
    assert(StringUtils.trimWhitespace("\t") == "");
    assert(StringUtils.trimWhitespace("\n") == "");
    assert(StringUtils.trimWhitespace(" \t\n") == "");
    assert(StringUtils.trimWhitespace(" a") == "a");
    assert(StringUtils.trimWhitespace("a ") == "a");
    assert(StringUtils.trimWhitespace(" a ") == "a");
    assert(StringUtils.trimWhitespace(" a b ") == "a b");
    assert(StringUtils.trimWhitespace(" a b  c ") == "a b  c");
}

// trimAllWhitespace
unittest
{
    assert(StringUtils.trimAllWhitespace(null) is null);
    assert(StringUtils.trimAllWhitespace("") == "");
    assert(StringUtils.trimAllWhitespace(" ") == "");
    assert(StringUtils.trimAllWhitespace("\t") == "");
    assert(StringUtils.trimAllWhitespace("\n") == "");
    assert(StringUtils.trimAllWhitespace(" \t\n") == "");
    assert(StringUtils.trimAllWhitespace(" a") == "a");
    assert(StringUtils.trimAllWhitespace("a ") == "a");
    assert(StringUtils.trimAllWhitespace(" a ") == "a");
    assert(StringUtils.trimAllWhitespace(" a b ") == "ab");
    assert(StringUtils.trimAllWhitespace(" a b  c ") == "abc");
}

// trimLeadingWhitespace
deprecated unittest
{
    assert(StringUtils.trimLeadingWhitespace(null) is null);
    assert(StringUtils.trimLeadingWhitespace("") == "");
    assert(StringUtils.trimLeadingWhitespace(" ") == "");
    assert(StringUtils.trimLeadingWhitespace("\t") == "");
    assert(StringUtils.trimLeadingWhitespace("\n") == "");
    assert(StringUtils.trimLeadingWhitespace(" \t\n") == "");
    assert(StringUtils.trimLeadingWhitespace(" a") == "a");
    assert(StringUtils.trimLeadingWhitespace("a ") == "a ");
    assert(StringUtils.trimLeadingWhitespace(" a ") == "a ");
    assert(StringUtils.trimLeadingWhitespace(" a b ") == "a b ");
    assert(StringUtils.trimLeadingWhitespace(" a b  c ") == "a b  c ");
}

// trimTrailingWhitespace
deprecated unittest
{
    assert(StringUtils.trimTrailingWhitespace(null) is null);
    assert(StringUtils.trimTrailingWhitespace("") == "");
    assert(StringUtils.trimTrailingWhitespace(" ") == "");
    assert(StringUtils.trimTrailingWhitespace("\t") == "");
    assert(StringUtils.trimTrailingWhitespace("\n") == "");
    assert(StringUtils.trimTrailingWhitespace(" \t\n") == "");
    assert(StringUtils.trimTrailingWhitespace("a ") == "a");
    assert(StringUtils.trimTrailingWhitespace(" a") == " a");
    assert(StringUtils.trimTrailingWhitespace(" a ") == " a");
    assert(StringUtils.trimTrailingWhitespace(" a b ") == " a b");
    assert(StringUtils.trimTrailingWhitespace(" a b  c ") == " a b  c");
}

// trimLeadingCharacter
unittest
{
    assert(StringUtils.trimLeadingCharacter(null, ' ') is null);
    assert(StringUtils.trimLeadingCharacter("", ' ') == "");
    assert(StringUtils.trimLeadingCharacter(" ", ' ') == "");
    assert(StringUtils.trimLeadingCharacter("\t", ' ') == "\t");
    assert(StringUtils.trimLeadingCharacter(" a", ' ') == "a");
    assert(StringUtils.trimLeadingCharacter("a ", ' ') == "a ");
    assert(StringUtils.trimLeadingCharacter(" a ", ' ') == "a ");
    assert(StringUtils.trimLeadingCharacter(" a b ", ' ') == "a b ");
    assert(StringUtils.trimLeadingCharacter(" a b  c ", ' ') == "a b  c ");
}

// trimTrailingCharacter
unittest
{
    assert(StringUtils.trimTrailingCharacter(null, ' ') is null);
    assert(StringUtils.trimTrailingCharacter("", ' ') == "");
    assert(StringUtils.trimTrailingCharacter(" ", ' ') == "");
    assert(StringUtils.trimTrailingCharacter("\t", ' ') == "\t");
    assert(StringUtils.trimTrailingCharacter("a ", ' ') == "a");
    assert(StringUtils.trimTrailingCharacter(" a", ' ') == " a");
    assert(StringUtils.trimTrailingCharacter(" a ", ' ') == " a");
    assert(StringUtils.trimTrailingCharacter(" a b ", ' ') == " a b");
    assert(StringUtils.trimTrailingCharacter(" a b  c ", ' ') == " a b  c");
}

// matchesCharacter
unittest
{
    assert(!StringUtils.matchesCharacter(null, '/'));
    assert(!StringUtils.matchesCharacter("/a", '/'));
    assert(!StringUtils.matchesCharacter("a", '/'));
    assert(StringUtils.matchesCharacter("/", '/'));
}

// startsWithIgnoreCase
unittest
{
    const prefix = "fOo";
    assert(StringUtils.startsWithIgnoreCase("foo", prefix));
    assert(StringUtils.startsWithIgnoreCase("Foo", prefix));
    assert(StringUtils.startsWithIgnoreCase("foobar", prefix));
    assert(StringUtils.startsWithIgnoreCase("foobarbar", prefix));
    assert(StringUtils.startsWithIgnoreCase("Foobar", prefix));
    assert(StringUtils.startsWithIgnoreCase("FoobarBar", prefix));
    assert(StringUtils.startsWithIgnoreCase("foObar", prefix));
    assert(StringUtils.startsWithIgnoreCase("FOObar", prefix));
    assert(StringUtils.startsWithIgnoreCase("fOobar", prefix));
    assert(!StringUtils.startsWithIgnoreCase(null, prefix));
    assert(!StringUtils.startsWithIgnoreCase("fOobar", null));
    assert(!StringUtils.startsWithIgnoreCase("b", prefix));
    assert(!StringUtils.startsWithIgnoreCase("barfoo", prefix));
    assert(!StringUtils.startsWithIgnoreCase("barfoobar", prefix));
}

// endsWithIgnoreCase
unittest
{
    const suffix = "fOo";
    assert(StringUtils.endsWithIgnoreCase("foo", suffix));
    assert(StringUtils.endsWithIgnoreCase("Foo", suffix));
    assert(StringUtils.endsWithIgnoreCase("barfoo", suffix));
    assert(StringUtils.endsWithIgnoreCase("barbarfoo", suffix));
    assert(StringUtils.endsWithIgnoreCase("barFoo", suffix));
    assert(StringUtils.endsWithIgnoreCase("barBarFoo", suffix));
    assert(StringUtils.endsWithIgnoreCase("barfoO", suffix));
    assert(StringUtils.endsWithIgnoreCase("barFOO", suffix));
    assert(StringUtils.endsWithIgnoreCase("barfOo", suffix));
    assert(!StringUtils.endsWithIgnoreCase(null, suffix));
    assert(!StringUtils.endsWithIgnoreCase("barfOo", null));
    assert(!StringUtils.endsWithIgnoreCase("b", suffix));
    assert(!StringUtils.endsWithIgnoreCase("foobar", suffix));
    assert(!StringUtils.endsWithIgnoreCase("barfoobar", suffix));
}

// substringMatch
unittest
{
    assert(StringUtils.substringMatch("foo", 0, "foo"));
    assert(StringUtils.substringMatch("foo", 1, "oo"));
    assert(StringUtils.substringMatch("foo", 2, "o"));
    assert(!StringUtils.substringMatch("foo", 0, "fOo"));
    assert(!StringUtils.substringMatch("foo", 1, "fOo"));
    assert(!StringUtils.substringMatch("foo", 2, "fOo"));
    assert(!StringUtils.substringMatch("foo", 3, "fOo"));
    assert(!StringUtils.substringMatch("foo", 1, "Oo"));
    assert(!StringUtils.substringMatch("foo", 2, "Oo"));
    assert(!StringUtils.substringMatch("foo", 3, "Oo"));
    assert(!StringUtils.substringMatch("foo", 2, "O"));
    assert(!StringUtils.substringMatch("foo", 3, "O"));
}

// countOccurrencesOf
unittest
{
    assert(StringUtils.countOccurrencesOf(null, null) == 0, "nullx2 = 0");
    assert(StringUtils.countOccurrencesOf("s", null) == 0, "null string = 0");
    assert(StringUtils.countOccurrencesOf(null, "s") == 0, "null substring = 0");
    const s = "erowoiueoiur";
    assert(StringUtils.countOccurrencesOf(s, "WERWER") == 0, "not found = 0");
    assert(StringUtils.countOccurrencesOf(s, "x") == 0, "not found char = 0");
    assert(StringUtils.countOccurrencesOf(s, " ") == 0, "not found ws = 0");
    assert(StringUtils.countOccurrencesOf(s, "") == 0, "not found empty string = 0");
    assert(StringUtils.countOccurrencesOf(s, "e") == 2, "found char=2");
    assert(StringUtils.countOccurrencesOf(s, "oi") == 2, "found substring=2");
    assert(StringUtils.countOccurrencesOf(s, "oiu") == 2, "found substring=2");
    assert(StringUtils.countOccurrencesOf(s, "oiur") == 1, "found substring=3");
    assert(StringUtils.countOccurrencesOf(s, "r") == 2, "test last");
}

// replace
unittest
{
    const inString = "a6AazAaa77abaa";
    const oldPattern = "aa";
    const newPattern = "foo";
    // Simple replace
    auto s = StringUtils.replace(inString, oldPattern, newPattern);
    assert(s == "a6AazAfoo77abfoo", "Replace 1 worked");
    // Non match: no change
    s = StringUtils.replace(inString, "qwoeiruqopwieurpoqwieur", newPattern);
    assert(s is inString, "Replace non-matched is returned as-is");
    // Null new pattern: should ignore
    s = StringUtils.replace(inString, oldPattern, null);
    assert(s is inString, "Replace non-matched is returned as-is");
    // Null old pattern: should ignore
    s = StringUtils.replace(inString, null, newPattern);
    assert(s is inString, "Replace non-matched is returned as-is");
}

// delete
unittest
{
    const inString = "The quick brown fox jumped over the lazy dog";
    assert(StringUtils.delete_(inString, "the") == "The quick brown fox jumped over  lazy dog");
    assert(StringUtils.delete_(inString, "he") == "T quick brown fox jumped over t lazy dog");
    assert(StringUtils.delete_(inString, " ") == "Thequickbrownfoxjumpedoverthelazydog");
    assert(StringUtils.delete_(inString, "dog") == "The quick brown fox jumped over the lazy ");
    assert(StringUtils.delete_(inString, "dxxcxcxog") == inString);
    assert(StringUtils.delete_(inString, "") == inString);
}

// deleteAny
unittest
{
    const inString = "Able was I ere I saw Elba";
    auto res = StringUtils.deleteAny(inString, "I");
    assert(res == "Able was  ere  saw Elba", "Result has no 'I'");
    res = StringUtils.deleteAny(inString, "AeEba!");
    assert(res == "l ws I r I sw l", "Result has no 'AeEba!'");
    res = StringUtils.deleteAny(inString, "#@$#$^");
    assert(res == inString, "Result is unchanged");
}

// deleteAnyWhitespace
unittest
{
    const whitespace = "This is\n\n\n    \t   a messagy string with whitespace\n";
    assert(whitespace.contains("\n"));
    assert(whitespace.contains("\t"));
    assert(whitespace.contains(" "));
    const cleaned = StringUtils.deleteAny(whitespace, "\n\t ");
    assert(!cleaned.contains("\n"));
    assert(!cleaned.contains("\t"));
    assert(!cleaned.contains(" "));
    assert(cleaned.length > 10);
}

// quote
unittest
{
    assert(StringUtils.quote("myString") == "'myString'");
    assert(StringUtils.quote("") == "''");
    assert(StringUtils.quote(null) is null);
}

// quoteIfString
unittest
{
    assert(StringUtils.quoteIfString("myString") == "'myString'");
    assert(StringUtils.quoteIfString("") == "''");
    assert(StringUtils.quoteIfString(5) == 5);
    assert(StringUtils.quoteIfString(cast(string) null) is null);
}

// unqualify
unittest
{
    const qualified = "i.am.not.unqualified";
    assert(StringUtils.unqualify(qualified) == "unqualified");
}

// capitalize
unittest
{
    assert(StringUtils.capitalize("i am not capitalized") == "I am not capitalized");
}

// uncapitalize
unittest
{
    assert(StringUtils.uncapitalize("I am capitalized") == "i am capitalized");
}

// getFilename
unittest
{
    assert(StringUtils.getFilename(null) is null);
    assert(StringUtils.getFilename("") == "");
    assert(StringUtils.getFilename("myfile") == "myfile");
    assert(StringUtils.getFilename("my/path/myfile") == "myfile");
    assert(StringUtils.getFilename("myfile.") == "myfile.");
    assert(StringUtils.getFilename("mypath/myfile.") == "myfile.");
    assert(StringUtils.getFilename("myfile.txt") == "myfile.txt");
    assert(StringUtils.getFilename("my/path/myfile.txt") == "myfile.txt");
}

// getFilenameExtension
unittest
{
    assert(StringUtils.getFilenameExtension(null) is null);
    assert(StringUtils.getFilenameExtension("") is null);
    assert(StringUtils.getFilenameExtension("myfile") is null);
    assert(StringUtils.getFilenameExtension("myPath/myfile") is null);
    assert(StringUtils.getFilenameExtension("/home/user/.m2/settings/myfile") is null);
    assert(StringUtils.getFilenameExtension("myfile.") == "");
    assert(StringUtils.getFilenameExtension("myPath/myfile.") == "");
    assert(StringUtils.getFilenameExtension("myfile.txt") == "txt");
    assert(StringUtils.getFilenameExtension("mypath/myfile.txt") == "txt");
    assert(StringUtils.getFilenameExtension("/home/user/.m2/settings/myfile.txt") == "txt");
}

// stripFilenameExtension
unittest
{
    assert(StringUtils.stripFilenameExtension("") == "");
    assert(StringUtils.stripFilenameExtension("myfile") == "myfile");
    assert(StringUtils.stripFilenameExtension("myfile.") == "myfile");
    assert(StringUtils.stripFilenameExtension("myfile.txt") == "myfile");
    assert(StringUtils.stripFilenameExtension("mypath/myfile") == "mypath/myfile");
    assert(StringUtils.stripFilenameExtension("mypath/myfile.") == "mypath/myfile");
    assert(StringUtils.stripFilenameExtension("mypath/myfile.txt") == "mypath/myfile");
    assert(StringUtils.stripFilenameExtension("/home/user/.m2/settings/myfile") == "/home/user/.m2/settings/myfile");
    assert(StringUtils.stripFilenameExtension("/home/user/.m2/settings/myfile.") == "/home/user/.m2/settings/myfile");
    const settings = "/home/user/.m2/settings/myfile";
    assert(StringUtils.stripFilenameExtension(settings ~ ".txt") == settings);
}

// cleanPath
unittest
{
    assert(StringUtils.cleanPath("mypath/myfile") == "mypath/myfile");
    assert(StringUtils.cleanPath("mypath\\myfile") == "mypath/myfile");
    assert(StringUtils.cleanPath("mypath/../mypath/myfile") == "mypath/myfile");
    assert(StringUtils.cleanPath("mypath/myfile/../../mypath/myfile") == "mypath/myfile");
    assert(StringUtils.cleanPath("../mypath/myfile") == "../mypath/myfile");
    assert(StringUtils.cleanPath("../mypath/../mypath/myfile") == "../mypath/myfile");
    assert(StringUtils.cleanPath("mypath/../../mypath/myfile") == "../mypath/myfile");
    assert(StringUtils.cleanPath("/../mypath/myfile") == "/../mypath/myfile");
    assert(StringUtils.cleanPath("/a/:b/../../mypath/myfile") == "/mypath/myfile");
    assert(StringUtils.cleanPath("/") == "/");
    assert(StringUtils.cleanPath("/mypath/../") == "/");
    assert(StringUtils.cleanPath("mypath/..") == "");
    assert(StringUtils.cleanPath("mypath/../.") == "");
    assert(StringUtils.cleanPath("mypath/../") == "./");
    assert(StringUtils.cleanPath("././") == "./");
    assert(StringUtils.cleanPath("./") == "./");
    assert(StringUtils.cleanPath("../") == "../");
    assert(StringUtils.cleanPath("./../") == "../");
    assert(StringUtils.cleanPath(".././") == "../");
    assert(StringUtils.cleanPath("file:/") == "file:/");
    assert(StringUtils.cleanPath("file:/mypath/../") == "file:/");
    assert(StringUtils.cleanPath("file:mypath/..") == "file:");
    assert(StringUtils.cleanPath("file:mypath/../.") == "file:");
    assert(StringUtils.cleanPath("file:mypath/../") == "file:./");
    assert(StringUtils.cleanPath("file:././") == "file:./");
    assert(StringUtils.cleanPath("file:./") == "file:./");
    assert(StringUtils.cleanPath("file:../") == "file:../");
    assert(StringUtils.cleanPath("file:./../") == "file:../");
    assert(StringUtils.cleanPath("file:.././") == "file:../");
    assert(StringUtils.cleanPath("file:/mypath/spring.factories") == "file:/mypath/spring.factories");
    assert(StringUtils.cleanPath("file:///c:/some/../path/the%20file.txt") == "file:///c:/path/the%20file.txt");
    assert(StringUtils.cleanPath(
            "jar:file:///c:\\some\\..\\path\\.\\the%20file.txt") == "jar:file:///c:/path/the%20file.txt");
    const jar = "jar:file:///c:/path/the%20file.txt";
    assert(StringUtils.cleanPath("jar:file:///c:/some/../path/./the%20file.txt") == jar);
    assert(StringUtils.cleanPath(
            "jar:file:///c:\\\\some\\\\..\\\\path\\\\.\\\\the%20file.txt") == "jar:file:///c:/path/the%20file.txt");
}

// pathEquals
unittest
{
    assert(StringUtils.pathEquals("/dummy1/dummy2/dummy3", "/dummy1/dummy2/dummy3"));
    assert(StringUtils.pathEquals("C:\\dummy1\\dummy2\\dummy3", "C:\\dummy1\\dummy2\\dummy3"));
    assert(StringUtils.pathEquals("/dummy1/bin/../dummy2/dummy3", "/dummy1/dummy2/dummy3"));
    assert(StringUtils.pathEquals("C:\\dummy1\\dummy2\\dummy3", "C:\\dummy1\\bin\\..\\dummy2\\dummy3"));
    assert(StringUtils.pathEquals("/dummy1/bin/../dummy2/bin/../dummy3", "/dummy1/dummy2/dummy3"));
    assert(StringUtils.pathEquals("C:\\dummy1\\dummy2\\dummy3", "C:\\dummy1\\bin\\..\\dummy2\\bin\\..\\dummy3"));
    assert(StringUtils.pathEquals("/dummy1/bin/tmp/../../dummy2/dummy3", "/dummy1/dummy2/dummy3"));
    assert(StringUtils.pathEquals("/dummy1/dummy2/dummy3", "/dummy1/dum/dum/../../dummy2/dummy3"));
    assert(StringUtils.pathEquals("./dummy1/dummy2/dummy3", "dummy1/dum/./dum/../../dummy2/dummy3"));
    assert(!StringUtils.pathEquals("./dummy1/dummy2/dummy3", "/dummy1/dum/./dum/../../dummy2/dummy3"));
    assert(!StringUtils.pathEquals("/dummy1/dummy2/dummy3", "/dummy1/dummy4/dummy3"));
    assert(!StringUtils.pathEquals("/dummy1/bin/tmp/../dummy2/dummy3", "/dummy1/dummy2/dummy3"));
    assert(!StringUtils.pathEquals("C:\\dummy1\\dummy2\\dummy3", "C:\\dummy1\\bin\\tmp\\..\\dummy2\\dummy3"));
    assert(!StringUtils.pathEquals("/dummy1/bin/../dummy2/dummy3", "/dummy1/dummy2/dummy4"));
}

// concatenateStringArrays
unittest
{
    string[] input1 = ["myString2"];
    string[] input2 = ["myString1", "myString2"];
    const result = StringUtils.concatenateStringArrays(input1, input2);
    assert(result == ["myString2", "myString1", "myString2"]);
    assert(StringUtils.concatenateStringArrays(input1, null) == input1);
    assert(StringUtils.concatenateStringArrays(null, input2) == input2);
    assert(StringUtils.concatenateStringArrays(null, null) is null);
}

// sortStringArray
unittest
{
    string[] input = ["myString2"];
    input = StringUtils.addStringToArray(input, "myString1");
    assert(input[0] == "myString2");
    assert(input[1] == "myString1");
    StringUtils.sortStringArray(input);
    assert(input[0] == "myString1");
    assert(input[1] == "myString2");
}

// trimArrayElements
unittest
{
    assert(StringUtils.trimArrayElements(null) is null);
    string[] empty = [];
    assert(StringUtils.trimArrayElements(empty).length == 0);
    assert(StringUtils.trimArrayElements(["", " ", "  ", "   "]) == ["", "", "", ""]);
    assert(StringUtils.trimArrayElements(["\n", "\t ", "\n\t"]) == ["", "", ""]);
    assert(StringUtils.trimArrayElements(["a", "b", "c"]) == ["a", "b", "c"]);
    assert(StringUtils.trimArrayElements(["  a  ", "  b b ", "  cc  "]) == ["a", "b b", "cc"]);
    assert(StringUtils.trimArrayElements(["  a  ", "b", "  c  "]) == ["a", "b", "c"]);
    const withNulls = StringUtils.trimArrayElements([null, "  a  ", null]);
    assert(withNulls[0] is null && withNulls[1] == "a" && withNulls[2] is null);
}

// removeDuplicateStrings
unittest
{
    string[] input = ["myString2", "myString1", "myString2"];
    input = StringUtils.removeDuplicateStrings(input);
    assert(input[0] == "myString2");
    assert(input[1] == "myString1");
}

// splitArrayElementsIntoProperties
unittest
{
    auto result = StringUtils.splitArrayElementsIntoProperties(["key1=value1 ", "key2 =\"value2\""], "=");
    assert(result.get("key1") == "value1");
    assert(result.get("key2") == "\"value2\"");
}

// splitArrayElementsIntoPropertiesAndDeletedChars
unittest
{
    auto result = StringUtils.splitArrayElementsIntoProperties(["key1=value1 ", "key2 =\"value2\""], "=", "\"");
    assert(result.get("key1") == "value1");
    assert(result.get("key2") == "value2");
}

// tokenizeToStringArray
unittest
{
    assert(StringUtils.tokenizeToStringArray("a,b , ,c", ",") == ["a", "b", "c"]);
}

// tokenizeToStringArrayWithNotIgnoreEmptyTokens
unittest
{
    assert(StringUtils.tokenizeToStringArray("a,b , ,c", ",", true, false) == ["a", "b", "", "c"]);
}

// tokenizeToStringArrayWithNotTrimTokens
unittest
{
    assert(StringUtils.tokenizeToStringArray("a,b ,c", ",", false, true) == ["a", "b ", "c"]);
}

// commaDelimitedListToStringArrayWithNullProducesEmptyArray
unittest
{
    assert(StringUtils.commaDelimitedListToStringArray(null).length == 0);
}

// commaDelimitedListToStringArrayWithEmptyStringProducesEmptyArray
unittest
{
    assert(StringUtils.commaDelimitedListToStringArray("").length == 0);
}

// delimitedListToStringArrayWithComma
unittest
{
    assert(StringUtils.delimitedListToStringArray("a,b", ",") == ["a", "b"]);
}

// delimitedListToStringArrayWithSemicolon
unittest
{
    assert(StringUtils.delimitedListToStringArray("a;b", ";") == ["a", "b"]);
}

// delimitedListToStringArrayWithEmptyDelimiter
unittest
{
    assert(StringUtils.delimitedListToStringArray("a,b", "") == ["a", ",", "b"]);
}

// delimitedListToStringArrayWithNullDelimiter
unittest
{
    assert(StringUtils.delimitedListToStringArray("a,b", null) == ["a,b"]);
}

// delimitedListToStringArrayWithCharacterToDelete
unittest
{
    assert(StringUtils.delimitedListToStringArray("a,b,c", ",", "a") == ["", "b", "c"]);
}

// delimitedListToStringArrayWithCharacterToDeleteEqualsToDelimiter
unittest
{
    assert(StringUtils.delimitedListToStringArray("a,b,c", ",", ",") == ["a", "b", "c"]);
}

private void doTestStringArrayReverseTransformationMatches(string[] array)
{
    const reverse = StringUtils.commaDelimitedListToStringArray(StringUtils.arrayToCommaDelimitedString(array));
    assert(reverse == array, "Reverse transformation is equal");
}

private void doTestCommaDelimitedListToStringArrayLegalMatch(string[] components)
{
    string sb;
    foreach (i, component; components)
        sb ~= (i ? "," : "") ~ component;
    assert(StringUtils.commaDelimitedListToStringArray(sb) == components, "Output equals input");
}

// commaDelimitedListToStringArrayMatchWords
unittest
{
    string[] array = ["foo", "bar", "big"];
    doTestCommaDelimitedListToStringArrayLegalMatch(array);
    doTestStringArrayReverseTransformationMatches(array);
    array = ["a", "b", "c"];
    doTestCommaDelimitedListToStringArrayLegalMatch(array);
    doTestStringArrayReverseTransformationMatches(array);
    // Test same words
    array = ["AA", "AA", "AA", "AA", "AA"];
    doTestCommaDelimitedListToStringArrayLegalMatch(array);
    doTestStringArrayReverseTransformationMatches(array);
}

// commaDelimitedListToStringArraySingleString
unittest
{
    const s = "woeirqupoiewuropqiewuorpqiwueopriquwopeiurqopwieur";
    assert(StringUtils.commaDelimitedListToStringArray(s) == [s]);
}

// commaDelimitedListToStringArrayWithOtherPunctuation
unittest
{
    doTestCommaDelimitedListToStringArrayLegalMatch(["xcvwert4456346&*.", "///", ".!", ".", ";"]);
}

// commaDelimitedListToStringArrayEmptyStrings
unittest
{
    assert(StringUtils.commaDelimitedListToStringArray("a,,b") == ["a", "", "b"]);
    doTestCommaDelimitedListToStringArrayLegalMatch(["", "", "a", ""]);
}

// split
unittest
{
    assert(StringUtils.split("Hello, world", ",") == ["Hello", " world"]);
    assert(StringUtils.split(",Hello world", ",") == ["", "Hello world"]);
    assert(StringUtils.split("Hello world,", ",") == ["Hello world", ""]);
    assert(StringUtils.split("Hello, world,", ",") == ["Hello", " world,"]);
}

// splitWithEmptyStringOrNull
unittest
{
    assert(StringUtils.split("Hello, world", "") is null);
    assert(StringUtils.split("", ",") is null);
    assert(StringUtils.split(null, ",") is null);
    assert(StringUtils.split("Hello, world", null) is null);
    assert(StringUtils.split(null, null) is null);
}

// collectionToDelimitedStringWithNullValuesShouldNotFail
unittest
{
    assert(StringUtils.collectionToCommaDelimitedString(Collections.singletonList!string(null)) == "null");
}

// applyRelativePath
unittest
{
    // Basic combination
    assert(StringUtils.applyRelativePath("mypath/myfile", "otherfile") == "mypath/otherfile");
    // Relative path starts with slash
    assert(StringUtils.applyRelativePath("mypath/myfile", "/otherfile") == "mypath/otherfile");
    // Includes root path
    assert(StringUtils.applyRelativePath("/mypath/myfile", "otherfile") == "/mypath/otherfile");
    assert(StringUtils.applyRelativePath("/mypath/myfile", "/otherfile") == "/mypath/otherfile");
    // When base path has no slash
    assert(StringUtils.applyRelativePath("myfile", "otherfile") == "otherfile");
    // Keep parent directory token as-is
    assert(StringUtils.applyRelativePath("mypath/myfile", "../otherfile") == "mypath/../otherfile");
    // Base path ends with slash
    assert(StringUtils.applyRelativePath("mypath/", "otherfile") == "mypath/otherfile");
    // Empty relative path
    assert(StringUtils.applyRelativePath("mypath/myfile", "") == "mypath/");
}

// truncatePreconditions
unittest
{
    auto e = expectThrows!IllegalArgumentException(() { StringUtils.truncate("foo", 0); });
    assert(e.getMessage() == "Truncation threshold must be a positive number: 0");
    e = expectThrows!IllegalArgumentException(() { StringUtils.truncate("foo", -99); });
    assert(e.getMessage() == "Truncation threshold must be a positive number: -99");
}

// truncate
unittest
{
    assert(StringUtils.truncate("", 10) == "");
    assert(StringUtils.truncate("aardvark", 10) == "aardvark");
    assert(StringUtils.truncate("aardvark12", 10) == "aardvark12");
    assert(StringUtils.truncate("aardvark123", 10) == "aardvark12 (truncated)...");
    assert(StringUtils.truncate("aardvark, bird, cat", 10) == "aardvark,  (truncated)...");
}

// truncateSurrogatePairs
unittest
{
    // U+1F600 "Grinning Face" is a surrogate pair in UTF-16: thresholds count UTF-16 code units (R14).
    assert(StringUtils.truncate("a\U0001F600", 3) == "a\U0001F600");
    assert(StringUtils.truncate("a\U0001F600b", 4) == "a\U0001F600b");
    assert(StringUtils.truncate("a\U0001F600b", 3) == "a\U0001F600 (truncated)...");
    assert(StringUtils.truncate("a\U0001F600b", 2) == "a (truncated)...");
    assert(StringUtils.truncate("\U0001F600b", 1) == " (truncated)...");
}

// Flint (R14): index, case and character routines on non-ASCII input.
unittest
{
    // substringMatch takes a UTF-16 index, as in Java.
    assert(StringUtils.substringMatch("日本語", 1, "本"));
    assert(StringUtils.substringMatch("a\U0001F600b", 3, "b"));
    assert(StringUtils.substringMatch("a\U0001F600b", 1, "\U0001F600"));
    assert(!StringUtils.substringMatch("a\U0001F600b", 2, "b"), "an index inside a surrogate pair never matches");
    assert(!StringUtils.substringMatch("日本", 3, "x"));
    assert(StringUtils.countOccurrencesOf("日本日本", "本") == 2);
    assert(StringUtils.trimLeadingCharacter("ééa", 'é') == "a");
    assert(StringUtils.trimTrailingCharacter("a😀😀", '😀') == "a");
    assert(StringUtils.matchesCharacter("é", 'é'));
    assert(!StringUtils.matchesCharacter("éé", 'é'));
    assert(StringUtils.deleteAny("café 😀!", "é😀") == "caf !");
    assert(StringUtils.trimAllWhitespace("日\u3000本 語") == "日本語");
    assert(StringUtils.containsWhitespace("日本\u2003"));
    assert(!StringUtils.containsWhitespace("日本\u00A0"), "Java's isWhitespace excludes no-break spaces");
    assert(StringUtils.capitalize("élan") == "Élan");
    assert(StringUtils.uncapitalize("Élan") == "élan");
    assert(StringUtils.uncapitalizeAsProperty("ÉCOLE") == "ÉCOLE");
    assert(StringUtils.uncapitalizeAsProperty("École") == "école");
    assert(StringUtils.startsWithIgnoreCase("ÉCOLE normale", "éc"));
    assert(StringUtils.endsWithIgnoreCase("日本ÄB", "äb"));
    assert(!StringUtils.endsWithIgnoreCase("日本", "x日本"));
    assert(StringUtils.unqualify("名前.空間", '.') == "空間");
    assert(StringUtils.unqualify("a→b→c", '→') == "c");
    assert(StringUtils.getFilename("/路径/文件.txt") == "文件.txt");
    assert(StringUtils.getFilenameExtension("/路径/文件.日本") == "日本");
    assert(StringUtils.stripFilenameExtension("/路径/文件.txt") == "/路径/文件");
    assert(StringUtils.cleanPath("/目录/../文件/./ü") == "/文件/ü");
    assert(StringUtils.tokenizeToStringArray(" α ,β;γ", ",;") == ["α", "β", "γ"]);
    assert(StringUtils.delimitedListToStringArray("日本😀", "") == ["日", "本", "😀"]);
    assert(StringUtils.delimitedListToStringArray("日→本→語", "→") == ["日", "本", "語"]);
    assert(StringUtils.split("日本:語", ":") == ["日本", "語"]);
    assert(StringUtils.truncate("日本語", 2) == "日本 (truncated)...");
    assert(StringUtils.replace("日本日本", "本", "😀") == "日😀日😀");
    string[] sorted = ["b", "é", "a", "\U0001F600", "\uFF21"];
    StringUtils.sortStringArray(sorted);
    // Java's order: UTF-16 units, so the surrogate pair (0xD83D...) sorts before U+FF21.
    assert(sorted == ["a", "b", "é", "\U0001F600", "\uFF21"]);
}

// Flint: uriDecode (UTF-8; the Java tests exercise it elsewhere).
unittest
{
    assert(StringUtils.uriDecode("") == "");
    assert(StringUtils.uriDecode("foobar") == "foobar");
    assert(StringUtils.uriDecode("foo%20bar") == "foo bar");
    assert(StringUtils.uriDecode("foo%2bbar") == "foo+bar");
    assert(StringUtils.uriDecode("caf%C3%A9") == "café");
    assert(StringUtils.uriDecode("%E6%97%A5%E6%9C%AC/x") == "日本/x");
    assert(StringUtils.uriDecode("%FF") == "\uFFFD");
    auto e = expectThrows!IllegalArgumentException(() { StringUtils.uriDecode("foo%ZZbar"); });
    assert(e.getMessage() == "Invalid encoded sequence \"%ZZbar\"");
    e = expectThrows!IllegalArgumentException(() { StringUtils.uriDecode("foo%2"); });
    assert(e.getMessage() == "Incomplete trailing escape (%) pattern");
}

// Flint: the collection and array joins, and the deprecated isEmpty.
deprecated unittest
{
    import flint.java.util : Arrays;

    assert(StringUtils.collectionToDelimitedString(Arrays.asList("a", "b"), "-", "<", ">") == "<a>-<b>");
    assert(StringUtils.arrayToDelimitedString([1, 2, 3], "|") == "1|2|3");
    assert(StringUtils.arrayToCommaDelimitedString(["x"]) == "x");
    assert(StringUtils.commaDelimitedListToSet("a,b,a").toArray() == ["a", "b"]);
    assert(StringUtils.toStringArray(Arrays.asList("p", "q")) == ["p", "q"]);
    assert(StringUtils.isEmpty(cast(string) null));
    assert(StringUtils.isEmpty(""));
    assert(!StringUtils.isEmpty(" "));
    assert(StringUtils.isEmpty(cast(Object) null));
    assert(!StringUtils.isEmpty(new Object));
}
