/++
Ported from FasterXML/jackson-databind 3.1.8,
src/test/java/tools/jackson/databind/introspect/TestNamingStrategyStd.java.
Copyright FasterXML and contributors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit assertions become D asserts; `nameForField(null, null, name)` and
`nameForGetterMethod(null, null, name)` are `nameForProperty(name)`, Flint's one translation method; the shared
mappers are built per test; TestNamingStrategyCustom's PersonBean is declared here; D identifiers cannot hold `$`, so
`from$user` and `$User` are fields `fromDollarUser` and `dollarUser` (and `Results`, against D style, is
`upperResults`) whose descriptors carry the Java names, as
Bean428's `@JsonProperty` method is a read-only property in its descriptor; FirstNameBean's default constructor is
public, so `descriptorOf` can create instances (Jackson calls the protected one). The SNAKE_CASE and
UPPER_SNAKE_CASE tables are also checked, as data, by tests/naming_test.d.
+/
module naming_strategy_std_test;

import databind_test_util : a2q, jsonMapperBuilder, newJsonMapper, q;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, DescriptorTable, MergedAnnotation, PropertyDescriptor, descriptorOf;
import flint.engine.aot.name : typeNameOf;
import flint.jackson.annotation : JsonCreator, JsonProperty, JsonPropertyOrder;
import flint.jackson.databind : JsonMapper, MapperFeature, PropertyNamingStrategies, PropertyNamingStrategy;
import flint.jackson.databind.annotation : JsonNaming;
import flint.jackson.databind.node : ObjectNode;
import flint.java.lang : classOf;

@safe:

@JsonPropertyOrder(["www", "some_url", "some_uris"])
private final class Acronyms
{
    string WWW;
    string someURL;
    string someURIs;

    this()
    {
        this(null, null, null);
    }

    this(string WWW, string someURL, string someURIs)
    {
        this.WWW = WWW;
        this.someURL = someURL;
        this.someURIs = someURIs;
    }
}

@JsonPropertyOrder(["from_user", "user", "from$user", "from7user", "_x"])
private final class UnchangedNames
{
    string from_user;
    string _user;
    string fromDollarUser; // from$user
    string from7user;
    // Used to test "_", but it's explicitly deprecated in JDK8 so...
    string _x;

    this()
    {
        this(null, null, null, null, null);
    }

    this(string from_user, string _user, string fromDollarUser, string from7user, string _x)
    {
        this.from_user = from_user;
        this._user = _user;
        this.fromDollarUser = fromDollarUser;
        this.from7user = from7user;
        this._x = _x;
    }
}

@JsonPropertyOrder(["results", "user", "__", "$_user"])
private final class OtherNonStandardNames
{
    string upperResults; // Results
    string _User;
    string ___;
    string dollarUser; // $User

    this()
    {
        this(null, null, null, null);
    }

    this(string upperResults, string _User, string ___, string dollarUser)
    {
        this.upperResults = upperResults;
        this._User = _User;
        this.___ = ___;
        this.dollarUser = dollarUser;
    }
}

private final class Bean428
{
    @JsonProperty("fooBar")
    string whatever()
    {
        return "";
    }
}

@JsonPropertyOrder(["firstName", "lastName"])
@JsonNaming(classOf!(PropertyNamingStrategies.LowerCaseStrategy))
private final class BoringBean
{
    string firstName = "Bob";
    string lastName = "Burger";
}

private final class ClassWithObjectNodeField
{
    string id;
    ObjectNode json;
}

private final class ExplicitBean
{
    @JsonProperty("firstName")
    string userFirstName = "Peter";
    @JsonProperty("lastName")
    string userLastName = "Venkman";
    @JsonProperty
    string userAge = "35";
}

@JsonNaming()
private final class DefaultNaming
{
    int someValue = 3;
}

private final class FirstNameBean
{
    string firstName;

    this()
    {
    }

    this(string n)
    {
        firstName = n;
    }
}

// TestNamingStrategyCustom.PersonBean.
@JsonPropertyOrder(["firstName", "lastName", "age"])
private final class PersonBean
{
    string firstName;
    string lastName;
    int age;

    this()
    {
        this(null, null, 0);
    }

    protected this(string f, string l, int a)
    {
        firstName = f;
        lastName = l;
        age = a;
    }
}

// The descriptor of `T` with properties renamed from their D names to their Java names (pairs), as Flint AOT
// names them.
private Descriptor renamed(T)(string[] dAndJavaNames...)
{
    auto d = descriptorOf!T();
    foreach (ref p; d.properties)
        for (size_t i = 0; i + 1 < dAndJavaNames.length; i += 2)
            if (p.name == dAndJavaNames[i])
                p.name = dAndJavaNames[i + 1];
    return d;
}

private Descriptor bean428Descriptor()
{
    auto d = descriptorOf!Bean428();
    d.properties ~= PropertyDescriptor("whatever", "string",
            [MergedAnnotation(typeNameOf!JsonProperty, Any.of(JsonProperty("fooBar")), 0)],
            (ref Any self) => Any.of(self.get!Bean428().whatever()), null);
    return d;
}

private DescriptorTable table()
{
    auto t = DescriptorTable.withBuiltins();
    foreach (d; [
        descriptorOf!Acronyms(), renamed!UnchangedNames("fromDollarUser", "from$user"),
        renamed!OtherNonStandardNames("dollarUser", "$User", "upperResults", "Results"),
        bean428Descriptor(), descriptorOf!BoringBean(), descriptorOf!ClassWithObjectNodeField(),
        descriptorOf!ExplicitBean(), descriptorOf!DefaultNaming(),
        descriptorOf!FirstNameBean(), descriptorOf!PersonBean()
    ])
        t.add(d);
    return t;
}

private string[2][] snakeCaseNameTranslations()
{
    return [
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
        // [databind#1026]
        ["_Bars", "bars"],
        // [databind#2267]
        ["usId", "us_id"], ["uId", "u_id"],
        // [databind#4409]
        ["xCoordinate", "x_coordinate"], ["RGBA", "rgba"], ["RGBa", "rgba"]
    ];
}

private string[2][] upperSnakeCaseNameTranslations()
{
    return [
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
}

private JsonMapper lcWithUnderscoreMapper()
{
    return jsonMapperBuilder(table()).propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE).build();
}

private JsonMapper ucWithUnderscoreMapper()
{
    return jsonMapperBuilder(table()).propertyNamingStrategy(PropertyNamingStrategies.UPPER_SNAKE_CASE).build();
}

/**
 * Unit test to verify translations of
 * `PropertyNamingStrategies.SNAKE_CASE`
 * outside the context of an ObjectMapper.
 */
@("TestNamingStrategyStd.testLowerCaseStrategyStandAlone")
unittest
{
    foreach (pair; snakeCaseNameTranslations())
    {
        const translatedJavaName = PropertyNamingStrategies.SNAKE_CASE.nameForProperty(pair[0]);
        assert(translatedJavaName == pair[1], pair[0] ~ " -> " ~ translatedJavaName);
    }
}

@("TestNamingStrategyStd.testLowerCaseTranslations")
unittest
{
    auto mapper = lcWithUnderscoreMapper();
    // First serialize
    const json = mapper.writeValueAsString(new PersonBean("Joe", "Sixpack", 42));
    assert(json == `{"first_name":"Joe","last_name":"Sixpack","age":42}`, json);

    // then deserialize
    const result = mapper.readValue!PersonBean(json);
    assert(result.firstName == "Joe");
    assert(result.lastName == "Sixpack");
    assert(result.age == 42);
}

// flint.jackson's ObjectWriter has no with/without/forType (per-call features).
version (FlintJacksonObjectWriterConfig)
{
    @("TestNamingStrategyStd.testLowerCaseAcronymsTranslations")
    unittest
    {
        import flint.jackson.core.json : JsonWriteFeature;

        auto mapper = lcWithUnderscoreMapper();
        // First serialize
        const json = mapper.writer().without(JsonWriteFeature.ESCAPE_FORWARD_SLASHES)
            .writeValueAsString(new Acronyms("world wide web", "http://jackson.codehaus.org", "/path1/,/path2/"));
        assert(
                json == `{"www":"world wide web","some_url":"http://jackson.codehaus.org",`
                ~ `"some_uris":"/path1/,/path2/"}`);

        // then deserialize
        const result = mapper.readValue!Acronyms(json);
        assert(result.WWW == "world wide web");
        assert(result.someURL == "http://jackson.codehaus.org");
        assert(result.someURIs == "/path1/,/path2/");
    }
}

@("TestNamingStrategyStd.testLowerCaseOtherNonStandardNamesTranslations")
unittest
{
    auto mapper = lcWithUnderscoreMapper();
    // First serialize
    const json = mapper.writeValueAsString(new OtherNonStandardNames("Results", "_User", "___", "$User"));
    assert(json == `{"results":"Results","user":"_User","__":"___","$_user":"$User"}`, json);

    // then deserialize
    const result = mapper.readValue!OtherNonStandardNames(json);
    assert(result.upperResults == "Results");
    assert(result._User == "_User");
    assert(result.___ == "___");
    assert(result.dollarUser == "$User");
}

@("TestNamingStrategyStd.testLowerCaseUnchangedNames")
unittest
{
    auto mapper = lcWithUnderscoreMapper();
    // First serialize
    const json = mapper.writeValueAsString(new UnchangedNames("from_user", "_user", "from$user", "from7user", "_x"));
    assert(json == `{"from_user":"from_user","user":"_user","from$user":"from$user","from7user":"from7user",`
            ~ `"x":"_x"}`, json);

    // then deserialize
    const result = mapper.readValue!UnchangedNames(json);
    assert(result.from_user == "from_user");
    assert(result._user == "_user");
    assert(result.fromDollarUser == "from$user");
    assert(result.from7user == "from7user");
    assert(result._x == "_x");
}

// flint.jackson has no ObjectReader (ObjectMapper.readerFor), nor @JsonProperty on non-setter methods.
version (FlintJacksonObjectReader)
{
    @JsonNaming(classOf!(PropertyNamingStrategies.SnakeCaseStrategy))
    private final class Value3368
    {
        import flint.java.util : Map;

        private string timeZone;
        private string utcZone;

        @JsonProperty("time_zone")
        void unpackTimeZone(Map!(string, string) timeZone)
        {
            this.setTimeZone(timeZone.get("name"));
            this.setUtcZone(timeZone.get("utc_zone"));
        }

        string getTimeZone()
        {
            return this.timeZone;
        }

        string getUtcZone()
        {
            return this.utcZone;
        }

        void setTimeZone(string timeZone)
        {
            this.timeZone = timeZone;
        }

        void setUtcZone(string utcZone)
        {
            this.utcZone = utcZone;
        }
    }

    // [databind#3368]
    @("TestNamingStrategyStd.testSnakeCase3368")
    unittest
    {
        const test = "    {\n" ~ "      \"time_zone\": {\n" ~ "        \"name\": \"XXX\",\n"
            ~ "        \"utc_zone\": \"ZZZ\"\n" ~ "      }\n" ~ "    }";
        auto res = newJsonMapper(table()).readerFor!Value3368().readValue(test);
        assert(res.getTimeZone() == "XXX");
        assert(res.getUtcZone() == "ZZZ");
    }
}

@("TestNamingStrategyStd.testUpperSnakeCaseStrategyStandAlone")
unittest
{
    foreach (pair; upperSnakeCaseNameTranslations())
    {
        const translatedJavaName = PropertyNamingStrategies.UPPER_SNAKE_CASE.nameForProperty(pair[0]);
        assert(translatedJavaName == pair[1], pair[0] ~ " -> " ~ translatedJavaName);
    }
}

@("TestNamingStrategyStd.testUpperSnakeCaseTranslations")
unittest
{
    auto mapper = ucWithUnderscoreMapper();
    // First serialize
    const json = mapper.writeValueAsString(new PersonBean("Joe", "Sixpack", 42));
    assert(json == `{"FIRST_NAME":"Joe","LAST_NAME":"Sixpack","AGE":42}`, json);

    // then deserialize
    const result = mapper.readValue!PersonBean(json);
    assert(result.firstName == "Joe");
    assert(result.lastName == "Sixpack");
    assert(result.age == 42);
}

/**
 * Unit test to verify translations of
 * `PropertyNamingStrategies.UPPER_CAMEL_CASE`
 * outside the context of an ObjectMapper.
 */
@("TestNamingStrategyStd.testPascalCaseStandAlone")
unittest
{
    PropertyNamingStrategy upperCamel = PropertyNamingStrategies.UPPER_CAMEL_CASE;
    assert(upperCamel.nameForProperty("userName") == "UserName");
    assert(upperCamel.nameForProperty("User") == "User");
    assert(upperCamel.nameForProperty("user") == "User");
    assert(upperCamel.nameForProperty("x") == "X");

    assert(upperCamel.nameForProperty("bADPublicName") == "BADPublicName");
    assert(upperCamel.nameForProperty("bADPublicName") == "BADPublicName");
}

// [databind#428]
@("TestNamingStrategyStd.testIssue428PascalWithOverrides")
unittest
{
    import std.string : indexOf;

    const json = jsonMapperBuilder(table()).propertyNamingStrategy(
            PropertyNamingStrategies.UPPER_CAMEL_CASE).build().writeValueAsString(new Bean428());
    assert(json.indexOf(q("fooBar")) >= 0, "Should use name 'fooBar', does not: " ~ json);
}

// For [databind#461]
@("TestNamingStrategyStd.testSimpleLowerCase")
unittest
{
    auto input = new BoringBean();
    auto m = newJsonMapper(table());

    assert(m.writeValueAsString(input) == a2q("{'firstname':'Bob','lastname':'Burger'}"));
}

@("TestNamingStrategyStd.testKebabCaseStrategyStandAlone")
unittest
{
    PropertyNamingStrategy kebab = PropertyNamingStrategies.KEBAB_CASE;
    assert(kebab.nameForProperty("someValue") == "some-value");
    assert(kebab.nameForProperty("SomeValue") == "some-value");
    assert(kebab.nameForProperty("URL") == "url");
    assert(kebab.nameForProperty("URLStuff") == "url-stuff");
    assert(kebab.nameForProperty("SomeURLStuff") == "some-url-stuff");
}

@("TestNamingStrategyStd.testSimpleKebabCase")
unittest
{
    auto input = new FirstNameBean("Bob");
    auto m = jsonMapperBuilder(table()).propertyNamingStrategy(PropertyNamingStrategies.KEBAB_CASE).build();
    assert(m.writeValueAsString(input) == a2q("{'first-name':'Bob'}"));

    const result = m.readValue!FirstNameBean(a2q("{'first-name':'Billy'}"));
    assert(result.firstName == "Billy");
}

@("TestNamingStrategyStd.testLowerCaseWithDotsStrategyStandAlone")
unittest
{
    PropertyNamingStrategy dots = PropertyNamingStrategies.LOWER_DOT_CASE;
    assert(dots.nameForProperty("someValue") == "some.value");
    assert(dots.nameForProperty("SomeValue") == "some.value");
    assert(dots.nameForProperty("URL") == "url");
    assert(dots.nameForProperty("URLStuff") == "url.stuff");
    assert(dots.nameForProperty("SomeURLStuff") == "some.url.stuff");
}

@("TestNamingStrategyStd.testSimpleLowerCaseWithDots")
unittest
{
    auto m = jsonMapperBuilder(table()).propertyNamingStrategy(PropertyNamingStrategies.LOWER_DOT_CASE).build();

    auto input = new FirstNameBean("Bob");
    assert(m.writeValueAsString(input) == a2q("{'first.name':'Bob'}"));

    const result = m.readValue!FirstNameBean(a2q("{'first.name':'Billy'}"));
    assert(result.firstName == "Billy");
}

/**
 * Test [databind#815], problems with ObjectNode, naming strategy
 */
@("TestNamingStrategyStd.testNamingWithObjectNode")
unittest
{
    auto m = jsonMapperBuilder(table()).propertyNamingStrategy(PropertyNamingStrategies.LOWER_CASE).build();
    verifyObjectNodeField(m.readValue!ClassWithObjectNodeField(
            "{ \"id\": \"1\", \"json\": { \"foo\": \"bar\", \"baz\": \"bing\" } }"));
}

private void verifyObjectNodeField(ClassWithObjectNodeField result)
{
    assert(result !is null);
    assert(result.id == "1");
    assert(result.json !is null);
    assert(result.json.size() == 2);
    assert(result.json.path("baz").asString() == "bing");
}

// flint.jackson accepts MapperFeature.ALLOW_EXPLICIT_PROPERTY_RENAMING but never renames explicit names.
// LIKELY BUG: with the feature enabled, ExplicitBean writes {"firstName":"Peter","lastName":"Venkman","user_age":"35"},
// expected {"first_name":"Peter","last_name":"Venkman","user_age":"35"}.
version (FlintJacksonExplicitPropertyRenaming)
{
    @("TestNamingStrategyStd.testExplicitRename")
    unittest
    {
        auto m = jsonMapperBuilder(table()).enable(MapperFeature.SORT_PROPERTIES_ALPHABETICALLY)
            .propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE).build();
        // by default, renaming will not take place on explicitly named fields
        assert(m.writeValueAsString(new ExplicitBean()) == a2q(
                "{'firstName':'Peter','lastName':'Venkman','user_age':'35'}"));

        m = jsonMapperBuilder(table()).propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE)
            .enable(MapperFeature.SORT_PROPERTIES_ALPHABETICALLY)
            .enable(MapperFeature.ALLOW_EXPLICIT_PROPERTY_RENAMING).build();
        // w/ feature enabled, ALL property names should get re-written
        assert(m.writeValueAsString(new ExplicitBean()) == a2q(
                "{'first_name':'Peter','last_name':'Venkman','user_age':'35'}"));

        // test deserialization as well
        const bean = m.readValue!ExplicitBean(a2q("{'first_name':'Egon','last_name':'Spengler','user_age':'32'}"));

        assert(bean !is null);
        assert(bean.userFirstName == "Egon");
        assert(bean.userLastName == "Spengler");
        assert(bean.userAge == "32");
    }
}

// Also verify that "no naming strategy" should be ok
@("TestNamingStrategyStd.testExplicitNoNaming")
unittest
{
    auto mapper = newJsonMapper(table());
    const json = mapper.writeValueAsString(new DefaultNaming());
    assert(json == a2q("{'someValue':3}"), json);
}

// flint.jackson has no pluggable AnnotationIntrospector (MapperBuilder.annotationIntrospector).
version (FlintJacksonAnnotationIntrospector)
{
    // @Target({FIELD, PARAMETER, TYPE}) @Retention(RUNTIME) @JacksonAnnotation
    private struct Name
    {
        string value;
    }

    private final class ParamNameIntrospector : JacksonAnnotationIntrospector
    {
        override string findImplicitPropertyName(MapperConfig config, AnnotatedMember param)
        {
            Name nameAnn;
            if (param.getAnnotation(nameAnn))
                return nameAnn.value;
            return super.findImplicitPropertyName(config, param);
        }
    }

    @JsonNaming(classOf!(PropertyNamingStrategies.SnakeCaseStrategy))
    private final class SnakeNameBean
    {
        string _id, _fullName;

        @JsonCreator
        protected this(@Name("id") string id, @Name("fullName") string fn)
        {
            _id = id;
            _fullName = fn;
        }
    }

    // Try to reproduce [databind#3102] but with regular POJO. Oddly,
    // does not actually fail.
    @("TestNamingStrategyStd.testNamingViaConstructorParams")
    unittest
    {
        auto mapper = jsonMapperBuilder(table()).annotationIntrospector(new ParamNameIntrospector()).build();
        const value = mapper.readValue!SnakeNameBean(a2q("{'id':'foobar', 'full_name' : 'Foo Bar'}"));
        assert(value._id == "foobar");
        assert(value._fullName == "Foo Bar");
    }
}
