/*
 * Ported from Jackson (jackson-databind) 3.1.8 tests, https://github.com/FasterXML/jackson-databind,
 * tag jackson-databind-3.1.8: src/test/java/tools/jackson/databind/introspect/TestNamingStrategyStd.java
 * (the name translation tables).
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: translated to D.
 */
module naming_test;

import flint.jackson.databind : PropertyNamingStrategies, PropertyNamingStrategy;

@safe:

private void check(PropertyNamingStrategy strategy, string[2][] table, string label)
{
    foreach (row; table)
    {
        const actual = strategy.nameForProperty(row[0]);
        assert(actual == row[1], label ~ ": " ~ row[0] ~ " -> " ~ actual ~ ", expected " ~ row[1]);
    }
}

@("TestNamingStrategyStd: SNAKE_CASE_NAME_TRANSLATIONS")
unittest
{
    string[2][] table = [
        ["", ""], ["a", "a"], ["abc", "abc"], ["1", "1"], ["123", "123"], ["1a", "1a"], ["a1",
            "a1"], ["$", "$"], ["$a", "$a"], ["a$", "a$"], ["$_a", "$_a"], ["a_$", "a_$"],
        ["a$a", "a$a"], ["$A", "$_a"], ["$_A", "$_a"], ["_", "_"], ["__", "_"], ["___", "__"],
        ["A", "a"], ["A1", "a1"], ["1A", "1_a"], ["_a", "a"], ["_A", "a"], ["a_a", "a_a"],
        ["a_A", "a_a"], ["A_A", "a_a"], ["A_a", "a_a"], ["WWW", "www"], ["someURI", "some_uri"],
        ["someURIs", "some_uris"], ["Results", "results"], ["_Results", "results"],
        ["_results", "results"], ["__results", "_results"], ["__Results", "_results"],
        ["___results", "__results"], ["___Results", "__results"], ["userName", "user_name"],
        ["user_name", "user_name"], ["user__name", "user__name"], ["UserName", "user_name"],
        ["User_Name", "user_name"], ["User__Name", "user__name"], ["_user_name", "user_name"],
        ["_UserName", "user_name"], ["_User_Name", "user_name"], ["UGLY_NAME", "ugly_name"],
        ["_Bars", "bars"], ["usId", "us_id"], ["uId", "u_id"], ["xCoordinate", "x_coordinate"],
        ["RGBA", "rgba"], ["RGBa", "rgba"]
    ];
    check(PropertyNamingStrategies.SNAKE_CASE, table, "SNAKE_CASE");
}

@("TestNamingStrategyStd: UPPER_SNAKE_CASE_NAME_TRANSLATIONS")
unittest
{
    string[2][] table = [
        ["", ""], ["a", "A"], ["abc", "ABC"], ["1", "1"], ["123", "123"], ["1a", "1A"], ["a1",
            "A1"], ["$", "$"], ["$a", "$A"], ["a$", "A$"], ["$_a", "$_A"], ["a_$", "A_$"],
        ["a$a", "A$A"], ["$A", "$_A"], ["$_A", "$_A"], ["_", "_"], ["__", "_"], ["___", "__"],
        ["A", "A"], ["A1", "A1"], ["1A", "1_A"], ["_a", "A"], ["_A", "A"], ["a_a", "A_A"],
        ["a_A", "A_A"], ["A_A", "A_A"], ["A_a", "A_A"], ["WWW", "WWW"], ["someURI", "SOME_URI"],
        ["someURIs", "SOME_URIS"], ["Results", "RESULTS"], ["_Results", "RESULTS"],
        ["_results", "RESULTS"], ["__results", "_RESULTS"], ["__Results", "_RESULTS"],
        ["___results", "__RESULTS"], ["___Results", "__RESULTS"], ["userName", "USER_NAME"],
        ["user_name", "USER_NAME"], ["user__name", "USER__NAME"], ["UserName", "USER_NAME"],
        ["User_Name", "USER_NAME"], ["User__Name", "USER__NAME"], ["_user_name", "USER_NAME"],
        ["_UserName", "USER_NAME"], ["_User_Name", "USER_NAME"], ["USER_NAME", "USER_NAME"],
        ["_Bars", "BARS"], ["usId", "US_ID"], ["uId", "U_ID"], ["xCoordinate", "X_COORDINATE"]
    ];
    check(PropertyNamingStrategies.UPPER_SNAKE_CASE, table, "UPPER_SNAKE_CASE");
}
