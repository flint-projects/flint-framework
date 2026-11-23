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
 * spring-core/src/test/java/org/springframework/core/env/{SimpleCommandLineArgsParserTests,
 * SimpleCommandLinePropertySourceTests}.java.
 *
 * Skipped Java tests: none. optionNamesSetIsUnmodifiable and nonOptionArgsListIsUnmodifiable are adapted: D returns
 * array copies rather than unmodifiable views, so the tests assert that changing a returned array leaves the parsed
 * arguments unchanged.
 */
module flint.core.env_command_line_test;

import flint.core.env : CommandLineArgs, CommandLinePropertySource, EnumerablePropertySource,
    PropertySource, SimpleCommandLineArgsParser, SimpleCommandLinePropertySource, StandardEnvironment;
import flint.java.lang : IllegalArgumentException;
import flint.java.util : List;
import std.exception : collectException;

@safe:

private enum parser = SimpleCommandLineArgsParser.init;

private string stringProperty(PropertySource ps, string name)
{
    auto value = ps.getProperty(name);
    return value.isNull ? null : value.get!string;
}

// SimpleCommandLineArgsParserTests

unittest
{
    // withNoOptions
    assert(parser.parse().getOptionValues("foo") is null);
}

unittest
{
    // withSingleOptionAndNoValue
    auto args = parser.parse("--o1");
    assert(args.containsOption("o1"));
    const values = args.getOptionValues("o1");
    assert(values !is null && values.length == 0);
}

unittest
{
    // withSingleOptionAndValue
    auto args = parser.parse("--o1=v1");
    assert(args.containsOption("o1"));
    assert(args.getOptionValues("o1") == ["v1"]);
}

unittest
{
    // withRepeatedOptionAndSameValues
    auto args = parser.parse("--o1=v1", "--o1=v1", "--o1=v1");
    assert(args.containsOption("o1"));
    assert(args.getOptionValues("o1") == ["v1", "v1", "v1"]);
}

unittest
{
    // withRepeatedOptionAndDifferentValues
    auto args = parser.parse("--o1=v1", "--o1=v2", "--o1=v3");
    assert(args.containsOption("o1"));
    assert(args.getOptionValues("o1") == ["v1", "v2", "v3"]);
}

unittest
{
    // withMixOfOptionsHavingValueAndOptionsHavingNoValue
    auto args = parser.parse("--o1=v1", "--o2");
    assert(args.containsOption("o1"));
    assert(args.containsOption("o2"));
    assert(!args.containsOption("o3"));
    assert(args.getOptionValues("o1") == ["v1"]);
    const o2 = args.getOptionValues("o2");
    assert(o2 !is null && o2.length == 0);
    assert(args.getOptionValues("o3") is null);
}

unittest
{
    // withEmptyOptionName
    const e = collectException!IllegalArgumentException(parser.parse("--=v1"));
    assert(e !is null && e.msg == "Invalid argument syntax: --=v1");
}

unittest
{
    // withEmptyOptionValue
    auto args = parser.parse("--o1=");
    assert(args.containsOption("o1"));
    assert(args.getOptionValues("o1") == [""]);
}

unittest
{
    // withEmptyOptionNameAndEmptyOptionValue
    assert(collectException!IllegalArgumentException(parser.parse("--=")) !is null);
}

unittest
{
    // withNonOptionArguments
    auto args = parser.parse("--o1=v1", "noa1", "--o2=v2", "noa2");
    assert(args.getOptionValues("o1") == ["v1"]);
    assert(args.getOptionValues("o2") == ["v2"]);
    assert(args.getNonOptionArgs() == ["noa1", "noa2"]);
}

unittest
{
    // optionNamesSetIsUnmodifiable
    CommandLineArgs args = SimpleCommandLineArgsParser.init.parse("--o1");
    auto names = args.getOptionNames();
    names ~= "bogus";
    names[0] = "changed";
    assert(args.getOptionNames() == ["o1"]);
}

unittest
{
    // nonOptionArgsListIsUnmodifiable
    CommandLineArgs args = SimpleCommandLineArgsParser.init.parse("noa1");
    auto nonOptions = args.getNonOptionArgs();
    nonOptions ~= "foo";
    nonOptions[0] = "changed";
    assert(args.getNonOptionArgs() == ["noa1"]);
}

unittest
{
    // supportsEndOfOptionsDelimiter
    auto args = parser.parse("--o1=v1", "--", "--o2=v2");
    assert(args.containsOption("o1"));
    assert(!args.containsOption("o2"));
    assert(args.getOptionValues("o1") == ["v1"]);
    bool found;
    foreach (arg; args.getNonOptionArgs())
        found |= arg == "--o2=v2";
    assert(found);
}

// SimpleCommandLinePropertySourceTests

unittest
{
    // withDefaultName
    PropertySource ps = new SimpleCommandLinePropertySource();
    assert(ps.getName() == CommandLinePropertySource.COMMAND_LINE_PROPERTY_SOURCE_NAME);
}

unittest
{
    // withCustomName
    PropertySource ps = new SimpleCommandLinePropertySource("ps1", new string[0]);
    assert(ps.getName() == "ps1");
}

unittest
{
    // withNoArgs
    PropertySource ps = new SimpleCommandLinePropertySource();
    assert(!ps.containsProperty("foo"));
    assert(ps.getProperty("foo").isNull);
}

unittest
{
    // withOptionArgsOnly
    CommandLinePropertySource ps = new SimpleCommandLinePropertySource("--o1=v1", "--o2");
    assert(ps.containsProperty("o1"));
    assert(ps.containsProperty("o2"));
    assert(!ps.containsProperty("o3"));
    assert(stringProperty(ps, "o1") == "v1");
    const o2 = stringProperty(ps, "o2");
    assert(o2 !is null && o2.length == 0);
    assert(ps.getProperty("o3").isNull);
}

unittest
{
    // withRepeatedOptionArgs
    CommandLinePropertySource ps = new SimpleCommandLinePropertySource("--o1=v1", "--o1=v2", "--o1=v3");
    assert(ps.containsProperty("o1"));
    assert(!ps.containsProperty("o2"));
    assert(stringProperty(ps, "o1") == "v1,v2,v3");
    assert(ps.getProperty("o2").isNull);
}

unittest
{
    // withOptionalArg_andArgIsEmpty
    EnumerablePropertySource ps = new SimpleCommandLinePropertySource("--foo=");
    assert(ps.containsProperty("foo"));
    const foo = stringProperty(ps, "foo");
    assert(foo !is null && foo == "");
}

unittest
{
    // withDefaultNonOptionArgsNameAndNoNonOptionArgsPresent
    EnumerablePropertySource ps = new SimpleCommandLinePropertySource("--o1=v1", "--o2");
    assert(!ps.containsProperty("nonOptionArgs"));
    assert(ps.containsProperty("o1"));
    assert(ps.containsProperty("o2"));
    assert(!ps.containsProperty("nonOptionArgs"));
    assert(ps.getProperty("nonOptionArgs").isNull);
    assert(ps.getPropertyNames().length == 2);
}

unittest
{
    // withDefaultNonOptionArgsNameAndNonOptionArgsPresent
    CommandLinePropertySource ps = new SimpleCommandLinePropertySource("--o1=v1", "noa1", "--o2", "noa2");
    assert(ps.containsProperty("nonOptionArgs"));
    assert(ps.containsProperty("o1"));
    assert(ps.containsProperty("o2"));
    assert(stringProperty(ps, "nonOptionArgs") == "noa1,noa2");
}

unittest
{
    // withCustomNonOptionArgsNameAndNoNonOptionArgsPresent
    CommandLinePropertySource ps = new SimpleCommandLinePropertySource("--o1=v1", "noa1", "--o2", "noa2");
    ps.setNonOptionArgsPropertyName("NOA");
    assert(!ps.containsProperty("nonOptionArgs"));
    assert(ps.containsProperty("NOA"));
    assert(ps.containsProperty("o1"));
    assert(ps.containsProperty("o2"));
    assert(stringProperty(ps, "NOA") == "noa1,noa2");
}

unittest
{
    // covertNonOptionArgsToStringArrayAndList
    CommandLinePropertySource ps = new SimpleCommandLinePropertySource("--o1=v1", "noa1", "--o2", "noa2");
    auto env = new StandardEnvironment;
    env.getPropertySources().addFirst(ps);
    assert(env.getProperty("nonOptionArgs") == "noa1,noa2");
    auto nonOptionArgsArray = env.getProperty!(string[])("nonOptionArgs");
    assert(nonOptionArgsArray[0] == "noa1");
    assert(nonOptionArgsArray[1] == "noa2");
    auto nonOptionArgsList = env.getProperty!(List!string)("nonOptionArgs");
    assert(nonOptionArgsList.toArray() == ["noa1", "noa2"]);
}
