// Ported from spring-framework v7.1.0: spring-core/src/main/java/org/springframework/core/env
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
 * spring-core/src/main/java/org/springframework/core/env/*.java (all but JOptCommandLinePropertySource).
 * PropertySource is not generic (its type parameter only typed getSource); property values are
 * flint.engine.aot.any.Any; Class-typed getProperty overloads are template façades (R4); `spring.` keys become
 * `flint.` keys, with `spring.` accepted as an alias (ADR-030 section 1).
 */

/++
`org.springframework.core.env`: Spring's environment abstraction: property sources, profiles and placeholder
resolution.

Keys: `AbstractEnvironment.ACTIVE_PROFILES_PROPERTY_NAME` is `flint.profiles.active`, so `FLINT_PROFILES_ACTIVE`
selects profiles through the system environment, and every lookup of a `flint.` key that finds nothing retries the
same key under `spring.`, so existing Spring configuration keeps working.
+/
module flint.core.env;

import flint.core.convert : ConversionService, TypeDescriptor;
import flint.core.convert.support : ConfigurableConversionService, DefaultConversionService;
import flint.engine.aot.any : Any;
import flint.engine.aot.name : typeNameOf;
import flint.java.lang : IllegalArgumentException, IllegalStateException, UnsupportedOperationException, valueOf;
import flint.java.util : HashMap, Iterator, LinkedHashMap, LinkedHashSet, List, Map, NoSuchElementException, Set;
import flint.java.util.stream : Stream;
import flint.util : Assert, PropertyPlaceholderHelper, StringUtils;

@safe:

// ---------------------------------------------------------------------------------------------------------------
// Property resolution

/++
Interface for resolving properties against any underlying source.

Java's `getProperty` and `getRequiredProperty` overloads are `final` here, over the virtual `getPropertyErased`,
so the `Class`-typed overloads can be template façades (R4) callable on any implementation (deviation D-22).
+/
interface PropertyResolver
{
    /// Whether the property `key` is available (its value is not null).
    bool containsProperty(string key);

    /// The erased primitive behind every `getProperty`: the property converted to `targetType` (nested
    /// placeholders resolved), or `Any.init` when it cannot be resolved.
    Any getPropertyErased(string key, const TypeDescriptor targetType);

    /// Resolve `${...}` placeholders in `text`, leaving unresolvable ones unchanged.
    string resolvePlaceholders(string text);

    /// Resolve `${...}` placeholders in `text`. Throws `IllegalArgumentException` on an unresolvable one.
    string resolveRequiredPlaceholders(string text);

    /// The property `key` as a string, or null when it cannot be resolved.
    final string getProperty(string key)
    {
        auto value = getPropertyErased(key, TypeDescriptor.valueOf!string);
        return value.isNull ? null : value.get!string;
    }

    /// The property `key`, or `defaultValue` when it cannot be resolved.
    final string getProperty(string key, string defaultValue)
    {
        auto value = getProperty(key);
        return value !is null ? value : defaultValue;
    }

    /// The property `key` converted to `T`, or `T.init` (null for references) when it cannot be resolved.
    T getProperty(T)(string key)
    {
        auto value = getPropertyErased(key, TypeDescriptor.valueOf!T);
        return value.isNull ? T.init : value.get!T;
    }

    /// The property `key` converted to `T`, or `defaultValue`.
    T getProperty(T)(string key, T defaultValue) if (!is(T == string))
    {
        auto value = getPropertyErased(key, TypeDescriptor.valueOf!T);
        return value.isNull ? defaultValue : value.get!T;
    }

    /// The property `key`. Throws `IllegalStateException("Required key 'k' not found")` when it is missing.
    final string getRequiredProperty(string key)
    {
        auto value = getProperty(key);
        if (value is null)
            throw new IllegalStateException("Required key '" ~ key ~ "' not found");
        return value;
    }

    /// The property `key` converted to `T`. Throws `IllegalStateException` when it is missing.
    T getRequiredProperty(T)(string key)
    {
        auto value = getPropertyErased(key, TypeDescriptor.valueOf!T);
        if (value.isNull)
            throw new IllegalStateException("Required key '" ~ key ~ "' not found");
        return value.get!T;
    }
}

/// Configuration interface implemented by most `PropertyResolver`s.
interface ConfigurablePropertyResolver : PropertyResolver
{
    /// The conversion service used when converting property values.
    ConfigurableConversionService getConversionService();
    /// Set the conversion service used when converting property values.
    void setConversionService(ConfigurableConversionService conversionService);
    /// Set the placeholder prefix (default `${`).
    void setPlaceholderPrefix(string placeholderPrefix);
    /// Set the placeholder suffix (default `}`).
    void setPlaceholderSuffix(string placeholderSuffix);
    /// Set the separator between a placeholder and its default value (default `:`); null for none.
    void setValueSeparator(string valueSeparator);
    /// Set the escape character for placeholders (default `\`); `char.init` for none.
    void setEscapeCharacter(char escapeCharacter);
    /// Whether unresolvable nested placeholders are left unchanged instead of failing.
    void setIgnoreUnresolvableNestedPlaceholders(bool ignoreUnresolvableNestedPlaceholders);
    /// Properties `validateRequiredProperties` requires.
    void setRequiredProperties(string[] requiredProperties...);
    /// Throw `MissingRequiredPropertiesException` when a required property is missing.
    void validateRequiredProperties();
}

/// Thrown when required properties are not found.
class MissingRequiredPropertiesException : IllegalStateException
{
    private string[] missingRequiredProperties;

    /// No missing properties yet.
    this() pure nothrow
    {
        super();
    }

    /// The missing properties.
    string[] getMissingRequiredProperties() const
    {
        return missingRequiredProperties.dup;
    }

    /// Record `key` as missing. The message becomes "The following properties were declared as required but could
    /// not be resolved: [a, b]".
    void addMissingRequiredProperty(string key) pure nothrow
    {
        missingRequiredProperties ~= key;
        string list;
        foreach (i, missing; missingRequiredProperties)
            list ~= (i ? ", " : "") ~ missing;
        msg = "The following properties were declared as required but could not be resolved: [" ~ list ~ "]";
    }
}

/// Abstract base class for resolving properties against any underlying source.
abstract class AbstractPropertyResolver : ConfigurablePropertyResolver
{
    /// The property naming the default escape character.
    enum DEFAULT_PLACEHOLDER_ESCAPE_CHARACTER_PROPERTY_NAME = "flint.placeholder.escapeCharacter.default";

    private ConfigurableConversionService conversionService;
    private PropertyPlaceholderHelper nonStrictHelper, strictHelper;
    private bool ignoreUnresolvableNestedPlaceholders;
    private string placeholderPrefix = "${";
    private string placeholderSuffix = "}";
    private string valueSeparator = ":";
    private char escapeCharacter = '\\';
    private string[] requiredProperties;

    /// The conversion service, created on first use.
    ConfigurableConversionService getConversionService()
    {
        if (conversionService is null)
            conversionService = new DefaultConversionService;
        return conversionService;
    }

    /// Set the conversion service.
    void setConversionService(ConfigurableConversionService conversionService)
    {
        Assert.notNull(conversionService, "ConversionService must not be null");
        this.conversionService = conversionService;
    }

    /// Set the placeholder prefix.
    void setPlaceholderPrefix(string placeholderPrefix)
    {
        Assert.notNull(placeholderPrefix, "'placeholderPrefix' must not be null");
        this.placeholderPrefix = placeholderPrefix;
        resetHelpers();
    }

    /// Set the placeholder suffix.
    void setPlaceholderSuffix(string placeholderSuffix)
    {
        Assert.notNull(placeholderSuffix, "'placeholderSuffix' must not be null");
        this.placeholderSuffix = placeholderSuffix;
        resetHelpers();
    }

    /// Set the value separator.
    void setValueSeparator(string valueSeparator)
    {
        this.valueSeparator = valueSeparator;
        resetHelpers();
    }

    /// Set the escape character.
    void setEscapeCharacter(char escapeCharacter)
    {
        this.escapeCharacter = escapeCharacter;
        resetHelpers();
    }

    /// Whether unresolvable nested placeholders are ignored.
    void setIgnoreUnresolvableNestedPlaceholders(bool ignoreUnresolvableNestedPlaceholders)
    {
        this.ignoreUnresolvableNestedPlaceholders = ignoreUnresolvableNestedPlaceholders;
    }

    /// Add required properties.
    void setRequiredProperties(string[] requiredProperties...)
    {
        foreach (key; requiredProperties)
            this.requiredProperties ~= key;
    }

    /// Throw `MissingRequiredPropertiesException` listing every required property that is missing.
    void validateRequiredProperties()
    {
        auto ex = new MissingRequiredPropertiesException;
        foreach (key; requiredProperties)
            if (getProperty(key) is null)
                ex.addMissingRequiredProperty(key);
        if (ex.getMissingRequiredProperties().length)
            throw ex;
    }

    /// Whether `key` resolves to a non-null value.
    bool containsProperty(string key)
    {
        return getProperty(key) !is null;
    }

    abstract Any getPropertyErased(string key, const TypeDescriptor targetType);

    /// Resolve placeholders leniently.
    string resolvePlaceholders(string text)
    {
        if (nonStrictHelper is null)
            nonStrictHelper = createPlaceholderHelper(true);
        return nonStrictHelper.replacePlaceholders(text, &getPropertyAsRawString);
    }

    /// Resolve placeholders strictly.
    string resolveRequiredPlaceholders(string text)
    {
        if (strictHelper is null)
            strictHelper = createPlaceholderHelper(false);
        return strictHelper.replacePlaceholders(text, &getPropertyAsRawString);
    }

    /// Resolve placeholders in a property value, strictly unless nested placeholders are ignored.
    protected string resolveNestedPlaceholders(string value)
    {
        if (value.length == 0)
            return value;
        return ignoreUnresolvableNestedPlaceholders ? resolvePlaceholders(value) : resolveRequiredPlaceholders(value);
    }

    private PropertyPlaceholderHelper createPlaceholderHelper(bool ignoreUnresolvablePlaceholders)
    {
        return new PropertyPlaceholderHelper(placeholderPrefix, placeholderSuffix, valueSeparator,
                escapeCharacter, ignoreUnresolvablePlaceholders);
    }

    private void resetHelpers() pure nothrow @nogc
    {
        nonStrictHelper = null;
        strictHelper = null;
    }

    /// `value` converted to `targetType`, unless it already is one.
    protected Any convertValueIfNecessary(Any value, const TypeDescriptor targetType)
    {
        if (targetType is null || value.typeName == targetType.getName())
            return value;
        ConversionService service = conversionService;
        if (service is null)
            service = DefaultConversionService.getSharedInstance();
        return service.convert(value, TypeDescriptor.forObject(value), targetType);
    }

    /// The property as a raw string, with no placeholder resolution; null when absent.
    protected abstract string getPropertyAsRawString(string key);
}

/// `PropertyResolver` over a set of `PropertySources`.
class PropertySourcesPropertyResolver : AbstractPropertyResolver
{
    private PropertySources propertySources;

    /// Resolve against `propertySources` (may be null).
    this(PropertySources propertySources) pure nothrow @nogc
    {
        this.propertySources = propertySources;
    }

    /// Whether some property source contains `key` (or its `spring.` alias).
    override bool containsProperty(string key)
    {
        if (propertySources is null)
            return false;
        foreach (candidate; aliasesOf(key))
            foreach (source; propertySources.toArray())
                if (source.containsProperty(candidate))
                    return true;
        return false;
    }

    override Any getPropertyErased(string key, const TypeDescriptor targetType)
    {
        return lookup(key, targetType, true);
    }

    protected override string getPropertyAsRawString(string key)
    {
        auto value = lookup(key, TypeDescriptor.valueOf!string, false);
        return value.isNull ? null : value.get!string;
    }

    /// The property from the first source holding it, nested placeholders resolved, converted to `targetType`.
    protected Any lookup(string key, const TypeDescriptor targetType, bool resolveNested)
    {
        if (propertySources is null)
            return Any.init;
        foreach (candidate; aliasesOf(key))
        {
            foreach (source; propertySources.toArray())
            {
                auto value = source.getProperty(candidate);
                if (value.isNull)
                    continue;
                if (resolveNested && value.typeName == "string")
                    value = Any.of(resolveNestedPlaceholders(value.get!string));
                return convertValueIfNecessary(value, targetType);
            }
        }
        return Any.init;
    }
}

/// `key`, then its `spring.` alias when `key` is a `flint.` key (ADR-030 section 1).
string[] aliasesOf(string key) pure nothrow
{
    enum prefix = "flint.";
    if (key.length > prefix.length && key[0 .. prefix.length] == prefix)
        return [key, "spring." ~ key[prefix.length .. $]];
    return [key];
}

// ---------------------------------------------------------------------------------------------------------------
// Property sources

/++
A source of name/value property pairs: a map, the system environment, the command line. Not generic in Flint: the
type parameter only typed `getSource()`, which returns `Object`.
+/
abstract class PropertySource
{
    /// The unique name of this source.
    protected string name;
    /// The underlying source object.
    protected Object source;

    /// A source named `name` over `source`.
    this(string name, Object source)
    {
        Assert.hasText(name, "Property source name must contain at least one character");
        Assert.notNull(source, "Property source must not be null");
        this.name = name;
        this.source = source;
    }

    /// A source named `name` over a new `Object` (for stubs and placeholders).
    this(string name)
    {
        this(name, new Object);
    }

    /// The name.
    string getName() const pure nothrow @nogc
    {
        return name;
    }

    /// The underlying source object.
    Object getSource() pure nothrow @nogc
    {
        return source;
    }

    /// Whether `name` resolves to a non-null value.
    bool containsProperty(string name)
    {
        return !getProperty(name).isNull;
    }

    /// The value of `name`, or `Any.init`.
    abstract Any getProperty(string name);

    /// Equal when the names are equal (Spring's `PropertySource.equals`).
    override bool opEquals(Object other)
    {
        auto that = cast(PropertySource) other;
        return that !is null && that.name == name;
    }

    /// Hash of the name.
    override size_t toHash() nothrow
    {
        return hashOf(name);
    }

    /// `ClassName {name='name'}`.
    override string toString()
    {
        import flint.engine.aot.name : simpleTypeName;

        return simpleTypeName(typeid(this).name) ~ " {name='" ~ name ~ "'}";
    }

    /// A placeholder source with the given name, for collection lookups by name.
    static PropertySource named(string name)
    {
        return new ComparisonPropertySource(name);
    }
}

/// A `PropertySource` that is not yet initialized: a placeholder replaced later.
class StubPropertySource : PropertySource
{
    /// A stub named `name`.
    this(string name)
    {
        super(name);
    }

    /// Always `Any.init`.
    override Any getProperty(string)
    {
        return Any.init;
    }
}

private final class ComparisonPropertySource : StubPropertySource
{
    this(string name)
    {
        super(name);
    }

    override Any getProperty(string)
    {
        throw new UnsupportedOperationException(
                "ComparisonPropertySource instances are for use with collection comparison only");
    }
}

/// A `PropertySource` that can list its property names.
abstract class EnumerablePropertySource : PropertySource
{
    /// A source named `name` over `source`.
    this(string name, Object source)
    {
        super(name, source);
    }

    /// A source named `name`.
    this(string name)
    {
        super(name);
    }

    /// Whether `name` is among `getPropertyNames()`.
    override bool containsProperty(string name)
    {
        foreach (candidate; getPropertyNames())
            if (candidate == name)
                return true;
        return false;
    }

    /// The names of every property.
    abstract string[] getPropertyNames();
}

/// A `PropertySource` over a `Map!(string, Any)`.
class MapPropertySource : EnumerablePropertySource
{
    /// The map.
    protected Map!(string, Any) map;

    /// A source named `name` over `source`.
    this(string name, Map!(string, Any) source)
    {
        super(name, cast(Object) source);
        map = source;
    }

    /// The value, or `Any.init`.
    override Any getProperty(string name)
    {
        return map.get(name);
    }

    /// Whether the map has `name`.
    override bool containsProperty(string name)
    {
        return map.containsKey(name);
    }

    /// The map's keys, in its iteration order.
    override string[] getPropertyNames()
    {
        return map.keySet().toArray();
    }
}

/++
A `MapPropertySource` for the system environment, with Spring's relaxed lookup: `foo.bar-baz` also finds `foo_bar_baz`,
`FOO.BAR-BAZ` and `FOO_BAR_BAZ`.
+/
class SystemEnvironmentPropertySource : MapPropertySource
{
    /// A source named `name` over the environment `source`.
    this(string name, Map!(string, Any) source)
    {
        super(name, source);
    }

    /// Whether the relaxed name resolves.
    override bool containsProperty(string name)
    {
        return !getProperty(name).isNull;
    }

    /// The value of the relaxed name, or `Any.init`.
    override Any getProperty(string name)
    {
        return super.getProperty(resolvePropertyName(name));
    }

    /// The environment variable name `name` resolves to; `name` itself when none matches.
    protected final string resolvePropertyName(string name)
    {
        import std.ascii : toUpper;

        Assert.notNull(name, "Property name must not be null");
        auto resolved = checkPropertyName(name);
        if (resolved !is null)
            return resolved;
        char[] upper = name.dup;
        foreach (ref c; upper)
            c = toUpper(c);
        if (upper != name)
        {
            resolved = checkPropertyName(upper.idup);
            if (resolved !is null)
                return resolved;
        }
        return name;
    }

    private string checkPropertyName(string name)
    {
        if (map.containsKey(name))
            return name;
        const noDot = replaceChar(name, '.', '_');
        if (noDot != name && map.containsKey(noDot))
            return noDot;
        const noHyphen = replaceChar(name, '-', '_');
        if (noHyphen != name && map.containsKey(noHyphen))
            return noHyphen;
        const noDotNoHyphen = replaceChar(noDot, '-', '_');
        if (noDotNoHyphen != noDot && map.containsKey(noDotNoHyphen))
            return noDotNoHyphen;
        return null;
    }

    private static string replaceChar(string text, char from, char to) pure
    {
        char[] result = text.dup;
        foreach (ref c; result)
            if (c == from)
                c = to;
        return result.idup;
    }
}

/// A `PropertySource` iterating a set of sources, the first one found winning.
class CompositePropertySource : EnumerablePropertySource
{
    private PropertySource[] propertySources;

    /// An empty composite named `name`.
    this(string name)
    {
        super(name);
    }

    /// The value from the first source that has `name`.
    override Any getProperty(string name)
    {
        foreach (source; propertySources)
        {
            auto candidate = source.getProperty(name);
            if (!candidate.isNull)
                return candidate;
        }
        return Any.init;
    }

    /// Whether any source has `name`.
    override bool containsProperty(string name)
    {
        foreach (source; propertySources)
            if (source.containsProperty(name))
                return true;
        return false;
    }

    /// The union of the sources' names. Throws `IllegalStateException` for a non-enumerable source.
    override string[] getPropertyNames()
    {
        auto names = new LinkedHashSet!string();
        foreach (source; propertySources)
        {
            auto enumerable = cast(EnumerablePropertySource) source;
            if (enumerable is null)
                throw new IllegalStateException(
                        "Failed to enumerate property names due to non-enumerable property "
                        ~ "source: " ~ source.toString());
            foreach (n; enumerable.getPropertyNames())
                names.add(n);
        }
        return names.toArray();
    }

    /// Add `propertySource` at the end.
    void addPropertySource(PropertySource propertySource)
    {
        propertySources ~= propertySource;
    }

    /// Add `propertySource` at the start.
    void addFirstPropertySource(PropertySource propertySource)
    {
        PropertySource[] kept;
        foreach (source; propertySources)
            if (source.getName() != propertySource.getName())
                kept ~= source;
        propertySources = propertySource ~ kept;
    }

    /// The nested sources.
    PropertySource[] getPropertySources()
    {
        return propertySources.dup;
    }

    /// `CompositePropertySource {name='n', propertySources=[...]}`.
    override string toString()
    {
        string list;
        foreach (i, source; propertySources)
            list ~= (i ? ", " : "") ~ source.toString();
        return "CompositePropertySource {name='" ~ name ~ "', propertySources=[" ~ list ~ "]}";
    }
}

/// Holder containing one or more `PropertySource`s.
interface PropertySources
{
    /// The sources, in precedence order.
    PropertySource[] toArray();
    /// Whether a source named `name` exists.
    bool contains(string name);
    /// The source named `name`, or null.
    PropertySource get(string name);

    /// `foreach (source; sources)`.
    final int opApply(scope int delegate(PropertySource) @safe dg)
    {
        foreach (source; toArray())
            if (const result = dg(source))
                return result;
        return 0;
    }

    /// An iterator over a snapshot of the sources (Spring's copy-on-write list): `remove` throws
    /// `UnsupportedOperationException`.
    final Iterator!PropertySource iterator()
    {
        return new SnapshotIterator(toArray());
    }

    /// The sources as a sequential stream.
    final Stream!PropertySource stream()
    {
        return Stream!PropertySource.ofArray(toArray());
    }
}

private final class SnapshotIterator : Iterator!PropertySource
{
    private PropertySource[] sources;
    private size_t position;

    this(PropertySource[] sources) pure nothrow @nogc
    {
        this.sources = sources;
    }

    bool hasNext()
    {
        return position < sources.length;
    }

    PropertySource next()
    {
        if (position >= sources.length)
            throw new NoSuchElementException();
        return sources[position++];
    }

    void remove()
    {
        throw new UnsupportedOperationException();
    }
}

/// The default `PropertySources`: precedence-ordered, with relative insertion.
class MutablePropertySources : PropertySources
{
    private PropertySource[] list;

    /// Empty.
    this() pure nothrow @nogc
    {
    }

    /// A copy of `propertySources`, in order (each added as `addLast` would, without a virtual call).
    this(PropertySources propertySources)
    {
        foreach (source; propertySources.toArray())
        {
            const index = indexOf(source.getName());
            if (index >= 0)
                list = list[0 .. index] ~ list[index + 1 .. $];
            list ~= source;
        }
    }

    /// The sources, in precedence order.
    PropertySource[] toArray()
    {
        return list.dup;
    }

    /// Whether a source named `name` exists.
    bool contains(string name)
    {
        return indexOf(name) >= 0;
    }

    /// The source named `name`, or null.
    PropertySource get(string name)
    {
        const index = indexOf(name);
        return index < 0 ? null : list[index];
    }

    /// Add with the highest precedence.
    void addFirst(PropertySource propertySource)
    {
        removeIfPresent(propertySource);
        list = propertySource ~ list;
    }

    /// Add with the lowest precedence.
    void addLast(PropertySource propertySource)
    {
        removeIfPresent(propertySource);
        list ~= propertySource;
    }

    /// Add immediately before the source named `relativePropertySourceName`.
    void addBefore(string relativePropertySourceName, PropertySource propertySource)
    {
        assertLegalRelativeAddition(relativePropertySourceName, propertySource);
        removeIfPresent(propertySource);
        addAtIndex(assertPresentAndGetIndex(relativePropertySourceName), propertySource);
    }

    /// Add immediately after the source named `relativePropertySourceName`.
    void addAfter(string relativePropertySourceName, PropertySource propertySource)
    {
        assertLegalRelativeAddition(relativePropertySourceName, propertySource);
        removeIfPresent(propertySource);
        addAtIndex(assertPresentAndGetIndex(relativePropertySourceName) + 1, propertySource);
    }

    /// The precedence of `propertySource`, or -1.
    int precedenceOf(PropertySource propertySource)
    {
        return indexOf(propertySource.getName());
    }

    /// Remove and return the source named `name`, or null.
    PropertySource remove(string name)
    {
        const index = indexOf(name);
        if (index < 0)
            return null;
        auto removed = list[index];
        list = list[0 .. index] ~ list[index + 1 .. $];
        return removed;
    }

    /// Replace the source named `name`. Throws `IllegalArgumentException` when it does not exist.
    void replace(string name, PropertySource propertySource)
    {
        list[assertPresentAndGetIndex(name)] = propertySource;
    }

    /// How many sources.
    int size() const pure nothrow @nogc
    {
        return cast(int) list.length;
    }

    /// `[source, source]`.
    override string toString()
    {
        string result = "[";
        foreach (i, source; list)
            result ~= (i ? ", " : "") ~ source.toString();
        return result ~ "]";
    }

    /// Throw when a source would be added relative to itself.
    protected void assertLegalRelativeAddition(string relativePropertySourceName, PropertySource propertySource)
    {
        if (relativePropertySourceName == propertySource.getName())
            throw new IllegalArgumentException("PropertySource named '" ~ propertySource.getName()
                    ~ "' cannot be added relative to itself");
    }

    /// Remove `propertySource` (by name) if present.
    protected void removeIfPresent(PropertySource propertySource)
    {
        remove(propertySource.getName());
    }

    private void addAtIndex(int index, PropertySource propertySource)
    {
        removeIfPresent(propertySource);
        list = list[0 .. index] ~ propertySource ~ list[index .. $];
    }

    private int assertPresentAndGetIndex(string name)
    {
        const index = indexOf(name);
        if (index < 0)
            throw new IllegalArgumentException("PropertySource named '" ~ name ~ "' does not exist");
        return index;
    }

    private int indexOf(string name) const pure nothrow @nogc
    {
        foreach (i, source; list)
            if (source.getName() == name)
                return cast(int) i;
        return -1;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Command line

/// A simple representation of command line arguments: option arguments and non-option arguments.
class CommandLineArgs
{
    private string[] optionNames;
    private string[][string] optionArgs;
    private string[] nonOptionArgs;

    /// Add `optionValue` (null for a valueless option) for `optionName`.
    void addOptionArg(string optionName, string optionValue)
    {
        if ((optionName in optionArgs) is null)
        {
            optionNames ~= optionName;
            optionArgs[optionName] = null;
        }
        if (optionValue !is null)
            optionArgs[optionName] ~= optionValue;
    }

    /// The option names, in first-seen order.
    string[] getOptionNames()
    {
        return optionNames.dup;
    }

    /// Whether `optionName` was given.
    bool containsOption(string optionName)
    {
        return (optionName in optionArgs) !is null;
    }

    /// The values of `optionName`: empty for a valueless option, null when it was not given.
    string[] getOptionValues(string optionName)
    {
        auto values = optionName in optionArgs;
        if (values is null)
            return null;
        // A present option without values is an empty but non-null slice, so callers can tell it from an absent one.
        return (*values).length ? (*values).dup : (new string[1])[0 .. 0];
    }

    /// Add a non-option argument.
    void addNonOptionArg(string value)
    {
        nonOptionArgs ~= value;
    }

    /// The non-option arguments, in order.
    string[] getNonOptionArgs()
    {
        return nonOptionArgs.dup;
    }
}

/// Parses `--name=value`, `--name` and non-option arguments; `--` ends the options.
struct SimpleCommandLineArgsParser
{
    /// Parse `args`. Throws `IllegalArgumentException("Invalid argument syntax: --=x")` for an empty option name.
    CommandLineArgs parse(string[] args...)
    {
        auto commandLineArgs = new CommandLineArgs;
        bool endOfOptions;
        foreach (arg; args)
        {
            if (!endOfOptions && arg.length >= 2 && arg[0 .. 2] == "--")
            {
                const optionText = arg[2 .. $];
                ptrdiff_t equals = -1;
                foreach (i, c; optionText)
                    if (c == '=')
                    {
                        equals = i;
                        break;
                    }
                if (equals > -1)
                {
                    if (equals == 0)
                        throw new IllegalArgumentException("Invalid argument syntax: " ~ arg);
                    commandLineArgs.addOptionArg(optionText[0 .. equals], optionText[equals + 1 .. $]);
                }
                else if (optionText.length)
                    commandLineArgs.addOptionArg(optionText, null);
                else
                    endOfOptions = true;
            }
            else
                commandLineArgs.addNonOptionArg(arg);
        }
        return commandLineArgs;
    }
}

/// Abstract base class for command line property sources: options are properties, and `nonOptionArgs` lists the rest.
abstract class CommandLinePropertySource : EnumerablePropertySource
{
    /// The default name of a command line property source.
    enum COMMAND_LINE_PROPERTY_SOURCE_NAME = "commandLineArgs";
    /// The default name of the property representing non-option arguments.
    enum DEFAULT_NON_OPTION_ARGS_PROPERTY_NAME = "nonOptionArgs";

    private string nonOptionArgsPropertyName = DEFAULT_NON_OPTION_ARGS_PROPERTY_NAME;

    /// A source named `name` over `source`.
    this(string name, Object source)
    {
        super(name, source);
    }

    /// Set the name of the property representing non-option arguments.
    void setNonOptionArgsPropertyName(string nonOptionArgsPropertyName)
    {
        this.nonOptionArgsPropertyName = nonOptionArgsPropertyName;
    }

    /// Whether the option, or (for the non-option property) any non-option argument, exists.
    final override bool containsProperty(string name)
    {
        if (name == nonOptionArgsPropertyName)
            return getNonOptionArgs().length != 0;
        return containsOption(name);
    }

    /// The option's values (or the non-option arguments) joined with commas; `Any.init` when absent.
    final override Any getProperty(string name)
    {
        if (name == nonOptionArgsPropertyName)
        {
            auto args = getNonOptionArgs();
            return args.length == 0 ? Any.init : Any.of(joinComma(args));
        }
        auto values = getOptionValues(name);
        return values is null ? Any.init : Any.of(joinComma(values));
    }

    /// Whether the option was given.
    protected abstract bool containsOption(string name);
    /// The option's values: empty for a valueless option, null when absent.
    protected abstract string[] getOptionValues(string name);
    /// The non-option arguments.
    protected abstract string[] getNonOptionArgs();

    private static string joinComma(string[] values)
    {
        string result;
        foreach (i, value; values)
            result ~= (i ? "," : "") ~ value;
        return result.length ? result : ""; // "" is not null: an option given without a value has the value ""
    }
}

/// A `CommandLinePropertySource` over `SimpleCommandLineArgsParser`'s results.
class SimpleCommandLinePropertySource : CommandLinePropertySource
{
    private CommandLineArgs args;

    /// A source named `commandLineArgs` over `args`.
    this(string[] args...)
    {
        this(COMMAND_LINE_PROPERTY_SOURCE_NAME, args.dup);
    }

    /// A source named `name` over `args`.
    this(string name, string[] args)
    {
        auto parsed = SimpleCommandLineArgsParser.init.parse(args);
        super(name, parsed);
        this.args = parsed;
    }

    /// The option names.
    override string[] getPropertyNames()
    {
        return args.getOptionNames();
    }

    protected override bool containsOption(string name)
    {
        return args.containsOption(name);
    }

    protected override string[] getOptionValues(string name)
    {
        return args.getOptionValues(name);
    }

    protected override string[] getNonOptionArgs()
    {
        return args.getNonOptionArgs();
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Profiles and environments

/// A profile predicate that an `Environment` may accept.
interface Profiles
{
    /// Whether these profiles match, given which profile names are active.
    bool matches(bool delegate(string) @safe isProfileActive);

    /// Profiles from expressions with `!`, `&`, `|` and parentheses; several expressions match if any matches.
    static Profiles of(string[] profileExpressions...)
    {
        return ProfilesParser.parse(profileExpressions.dup);
    }
}

/// Parses profile expressions (internal to `Profiles.of`).
struct ProfilesParser
{
    private enum Operator
    {
        none,
        and,
        or,
    }

    private enum Context
    {
        none,
        negate,
        parenthesis,
    }

    /// The `Profiles` matching any of `expressions`.
    static Profiles parse(string[] expressions)
    {
        if (expressions.length == 0)
            throw new IllegalArgumentException("Must specify at least one profile expression");
        Profiles[] parsed;
        foreach (expression; expressions)
            parsed ~= parseExpression(expression);
        return new ParsedProfiles(expressions, parsed);
    }

    private static Profiles parseExpression(string expression)
    {
        if (!StringUtils.hasText(expression))
            throw new IllegalArgumentException(
                    "Invalid profile expression [" ~ valueOf(expression) ~ "]: must contain text");
        auto tokens = tokenize(expression);
        size_t position;
        return parseTokens(expression, tokens, position, Context.none);
    }

    private static string[] tokenize(string expression) pure
    {
        string[] tokens;
        size_t start;
        foreach (i, c; expression)
        {
            if (c == '(' || c == ')' || c == '&' || c == '|' || c == '!')
            {
                if (i > start)
                    tokens ~= expression[start .. i];
                tokens ~= expression[i .. i + 1];
                start = i + 1;
            }
        }
        if (start < expression.length)
            tokens ~= expression[start .. $];
        return tokens;
    }

    private struct ParseState
    {
        Profiles[] elements;
        Operator operator;
        bool operandExpected = true;
    }

    private static Profiles parseTokens(string expression, string[] tokens, ref size_t position, Context context)
    {
        ParseState state;
        while (position < tokens.length)
        {
            const token = trim(tokens[position++]);
            if (token.length == 0)
                continue;
            Profiles result;
            if (parseToken(expression, token, tokens, position, context, state, result))
                return result;
        }
        assertWellFormed(expression, context != Context.parenthesis && !state.operandExpected);
        return merge(expression, state.elements, state.operator);
    }

    /// Handle one token; true when it ends the enclosing group (a negation or parenthesis) with `result`.
    private static bool parseToken(string expression, string token, string[] tokens,
            ref size_t position, Context context, ref ParseState state, out Profiles result)
    {
        switch (token)
        {
        case "(":
            assertWellFormed(expression, state.operandExpected);
            return operand(parseTokens(expression, tokens, position, Context.parenthesis), context, state, result);
        case "&", "|":
            const op = token == "&" ? Operator.and : Operator.or;
            assertWellFormed(expression, state.operator == op || (state.operator == Operator.none
                    && !state.operandExpected));
            state.operator = op;
            state.operandExpected = true;
            return false;
        case "!":
            assertWellFormed(expression, state.operandExpected);
            return operand(negate(parseTokens(expression, tokens, position, Context.negate)), context, state, result);
        case ")":
            if (context == Context.parenthesis)
            {
                assertWellFormed(expression, !state.operandExpected);
                result = merge(expression, state.elements, state.operator);
                return true;
            }
            assertWellFormed(expression, false);
            return false;
        default:
            assertWellFormed(expression, state.operandExpected);
            assertWellFormed(expression, !containsWhitespace(token));
            return operand(profile(token), context, state, result);
        }
    }

    /// An operand ends a negation, or joins the group's elements.
    private static bool operand(Profiles value, Context context, ref ParseState state, out Profiles result)
    {
        if (context == Context.negate)
        {
            result = value;
            return true;
        }
        state.elements ~= value;
        state.operandExpected = false;
        return false;
    }

    private static Profiles merge(string expression, Profiles[] elements, Operator operator)
    {
        assertWellFormed(expression, elements.length != 0);
        if (elements.length == 1)
            return elements[0];
        return new Combined(elements, operator == Operator.and);
    }

    private static void assertWellFormed(string expression, bool wellFormed)
    {
        if (!wellFormed)
            throw new IllegalArgumentException("Malformed profile expression [" ~ expression ~ "]");
    }

    private static string trim(string token) pure nothrow @nogc
    {
        size_t start, end = token.length;
        while (start < end && token[start] <= ' ')
            start++;
        while (end > start && token[end - 1] <= ' ')
            end--;
        return token[start .. end];
    }

    private static bool containsWhitespace(string token) pure nothrow @nogc
    {
        foreach (c; token)
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f')
                return true;
        return false;
    }

    private static Profiles profile(string name)
    {
        return new Single(name);
    }

    private static Profiles negate(Profiles profiles)
    {
        return new Negated(profiles);
    }
}

private final class Single : Profiles
{
    private string name;

    this(string name) pure nothrow @nogc
    {
        this.name = name;
    }

    bool matches(bool delegate(string) @safe isProfileActive)
    {
        return isProfileActive(name);
    }
}

private final class Negated : Profiles
{
    private Profiles inner;

    this(Profiles inner) pure nothrow @nogc
    {
        this.inner = inner;
    }

    bool matches(bool delegate(string) @safe isProfileActive)
    {
        return !inner.matches(isProfileActive);
    }
}

private final class Combined : Profiles
{
    private Profiles[] elements;
    private bool all;

    this(Profiles[] elements, bool all) pure nothrow @nogc
    {
        this.elements = elements;
        this.all = all;
    }

    bool matches(bool delegate(string) @safe isProfileActive)
    {
        foreach (element; elements)
        {
            const matched = element.matches(isProfileActive);
            if (matched != all)
                return matched;
        }
        return all;
    }
}

private final class ParsedProfiles : Profiles
{
    private string[] expressions;
    private Profiles[] parsed;

    this(string[] expressions, Profiles[] parsed)
    {
        foreach (expression; expressions)
        {
            bool seen;
            foreach (existing; this.expressions)
                seen |= existing == expression;
            if (!seen)
                this.expressions ~= expression;
        }
        this.parsed = parsed;
    }

    bool matches(bool delegate(string) @safe isProfileActive)
    {
        foreach (candidate; parsed)
            if (candidate.matches(isProfileActive))
                return true;
        return false;
    }

    /// Equal expression sets: the order of the expressions does not matter (Spring's `LinkedHashSet.equals`).
    override bool opEquals(Object other)
    {
        auto that = cast(ParsedProfiles) other;
        if (that is null || that.expressions.length != expressions.length)
            return false;
        foreach (expression; expressions)
        {
            bool found;
            foreach (candidate; that.expressions)
                found |= candidate == expression;
            if (!found)
                return false;
        }
        return true;
    }

    /// The sum of the expressions' hashes, independent of their order (Spring's `Set.hashCode`).
    override size_t toHash() nothrow
    {
        size_t hash;
        foreach (expression; expressions)
            hash += hashOf(expression);
        return hash;
    }

    override string toString()
    {
        if (expressions.length == 1)
            return expressions[0];
        string result;
        foreach (i, expression; expressions)
            result ~= (i ? " | " : "") ~ "(" ~ expression ~ ")";
        return result;
    }
}

/// Interface indicating a component that contains and exposes an `Environment`.
interface EnvironmentCapable
{
    /// The environment.
    Environment getEnvironment();
}

/// The environment the application runs in: profiles and properties.
interface Environment : PropertyResolver
{
    /// The explicitly active profiles.
    string[] getActiveProfiles();
    /// The profiles active when none are explicitly active (`default`).
    string[] getDefaultProfiles();
    /// Whether one of the profile expressions matches (Spring 5.3.28's `matchesProfiles`).
    bool matchesProfiles(string[] profileExpressions...);
    /++
    Whether one of `profiles` is active (or, when none is active, a default profile); a profile beginning with `!`
    matches when that profile is not active. Throws `IllegalArgumentException` for an empty list or profile.

    Deprecated since Spring 5.1 in favour of `acceptsProfiles(Profiles)` and `matchesProfiles`; kept for the API.
    +/
    bool acceptsProfiles(string[] profiles...);
    /// Whether `profiles` match the active (or default) profiles.
    bool acceptsProfiles(Profiles profiles);
}

/// Configuration interface implemented by most `Environment`s.
interface ConfigurableEnvironment : Environment, ConfigurablePropertyResolver
{
    /// Replace the active profiles.
    void setActiveProfiles(string[] profiles...);
    /// Add an active profile.
    void addActiveProfile(string profile);
    /// Replace the default profiles.
    void setDefaultProfiles(string[] profiles...);
    /// The property sources, mutable.
    MutablePropertySources getPropertySources();
    /// The system properties (an empty, mutable map in Flint: D has no JVM system properties).
    Map!(string, Any) getSystemProperties();
    /// The process environment variables.
    Map!(string, Any) getSystemEnvironment();
    /// Append `parent`'s property sources and profiles.
    void merge(ConfigurableEnvironment parent);
}

/// Abstract base class for `Environment` implementations.
abstract class AbstractEnvironment : ConfigurableEnvironment
{
    /// The property that, when true, suppresses system environment access.
    enum IGNORE_GETENV_PROPERTY_NAME = "flint.getenv.ignore";
    /// The property listing the active profiles (`spring.profiles.active` is accepted as an alias).
    enum ACTIVE_PROFILES_PROPERTY_NAME = "flint.profiles.active";
    /// The property listing the default profiles (`spring.profiles.default` is accepted as an alias).
    enum DEFAULT_PROFILES_PROPERTY_NAME = "flint.profiles.default";
    /// The name of the reserved default profile.
    enum RESERVED_DEFAULT_PROFILE_NAME = "default";

    private string[] activeProfiles;
    private string[] defaultProfiles;
    private MutablePropertySources propertySources;
    private ConfigurablePropertyResolver propertyResolver;
    private Map!(string, Any) systemProperties;

    /// An environment over new, empty property sources, customized by subclasses.
    this()
    {
        this(new MutablePropertySources);
    }

    /// An environment over `propertySources`, customized by subclasses.
    protected this(MutablePropertySources propertySources)
    {
        this.propertySources = propertySources;
        systemProperties = new LinkedHashMap!(string, Any)();
        initialize();
    }

    // Spring's constructor calls these template hooks during construction, by design: subclasses customize the
    // reserved default profiles, the resolver and the property sources before the environment is used.
    private void initialize()
    {
        defaultProfiles = getReservedDefaultProfiles();
        propertyResolver = createPropertyResolver(propertySources);
        customizePropertySources(propertySources);
    }

    /// The resolver over the property sources.
    protected ConfigurablePropertyResolver createPropertyResolver(MutablePropertySources propertySources)
    {
        return new PropertySourcesPropertyResolver(propertySources);
    }

    /// The resolver.
    protected final ConfigurablePropertyResolver getPropertyResolver()
    {
        return propertyResolver;
    }

    /// Add the environment's default property sources. The default adds none.
    protected void customizePropertySources(MutablePropertySources)
    {
    }

    /// The reserved default profiles: `["default"]`.
    protected string[] getReservedDefaultProfiles()
    {
        return [RESERVED_DEFAULT_PROFILE_NAME];
    }

    /// The active profiles, read from `flint.profiles.active` on first use.
    string[] getActiveProfiles()
    {
        return doGetActiveProfiles().dup;
    }

    /// The active profiles, read from the property on first use.
    protected string[] doGetActiveProfiles()
    {
        if (activeProfiles.length == 0)
        {
            const profiles = doGetActiveProfilesProperty();
            if (StringUtils.hasText(profiles))
                setActiveProfiles(profileList(profiles));
        }
        return activeProfiles;
    }

    /// The value of `flint.profiles.active` (or its `spring.` alias).
    protected string doGetActiveProfilesProperty()
    {
        return getProperty(ACTIVE_PROFILES_PROPERTY_NAME);
    }

    /// Replace the active profiles.
    void setActiveProfiles(string[] profiles...)
    {
        string[] validated;
        foreach (profile; profiles)
        {
            validateProfile(profile);
            addUnique(validated, profile);
        }
        activeProfiles = validated;
    }

    /// Add an active profile, after reading the property.
    void addActiveProfile(string profile)
    {
        validateProfile(profile);
        doGetActiveProfiles();
        addUnique(activeProfiles, profile);
    }

    /// The default profiles, read from `flint.profiles.default` on first use.
    string[] getDefaultProfiles()
    {
        return doGetDefaultProfiles().dup;
    }

    /// The default profiles, read from the property while they are the reserved ones.
    protected string[] doGetDefaultProfiles()
    {
        if (defaultProfiles == getReservedDefaultProfiles())
        {
            const profiles = doGetDefaultProfilesProperty();
            if (StringUtils.hasText(profiles))
                setDefaultProfiles(profileList(profiles));
        }
        return defaultProfiles;
    }

    /// The value of `flint.profiles.default` (or its `spring.` alias).
    protected string doGetDefaultProfilesProperty()
    {
        return getProperty(DEFAULT_PROFILES_PROPERTY_NAME);
    }

    /// Replace the default profiles.
    void setDefaultProfiles(string[] profiles...)
    {
        string[] validated;
        foreach (profile; profiles)
        {
            validateProfile(profile);
            addUnique(validated, profile);
        }
        defaultProfiles = validated;
    }

    /// Whether one of the profile expressions matches.
    bool matchesProfiles(string[] profileExpressions...)
    {
        return acceptsProfiles(Profiles.of(profileExpressions));
    }

    /// Whether one of `profiles` (`!`-negated or not) is active; deprecated in Spring since 5.1.
    bool acceptsProfiles(string[] profiles...)
    {
        if (profiles.length == 0)
            throw new IllegalArgumentException("Must specify at least one profile");
        foreach (profile; profiles)
        {
            if (profile.length && profile[0] == '!')
            {
                if (!isProfileActive(profile[1 .. $]))
                    return true;
            }
            else if (isProfileActive(profile))
                return true;
        }
        return false;
    }

    /// Whether `profiles` match.
    bool acceptsProfiles(Profiles profiles)
    {
        Assert.notNull(profiles, "Profiles must not be null");
        return profiles.matches(&isProfileActive);
    }

    /// Whether `profile` is active, or is a default profile while none is active.
    protected bool isProfileActive(string profile)
    {
        validateProfile(profile);
        auto current = doGetActiveProfiles();
        return contains(current, profile) || (current.length == 0 && contains(doGetDefaultProfiles(), profile));
    }

    /// Throw `IllegalArgumentException` for an empty profile or one beginning with `!`.
    protected void validateProfile(string profile)
    {
        if (!StringUtils.hasText(profile))
            throw new IllegalArgumentException("Invalid profile [" ~ valueOf(profile) ~ "]: must contain text");
        if (profile[0] == '!')
            throw new IllegalArgumentException("Invalid profile [" ~ profile ~ "]: must not begin with ! operator");
    }

    /// The property sources.
    MutablePropertySources getPropertySources()
    {
        return propertySources;
    }

    /// The (empty, mutable) system properties.
    Map!(string, Any) getSystemProperties()
    {
        return systemProperties;
    }

    /// The process environment, or an empty map when `flint.getenv.ignore` is set.
    Map!(string, Any) getSystemEnvironment()
    {
        import std.process : environment;

        auto result = new LinkedHashMap!(string, Any)();
        if (suppressGetenvAccess())
            return result;
        foreach (key, value; environment.toAA())
            result.put(key, Any.of(value));
        return result;
    }

    /++
    Whether `flint.getenv.ignore` is `true`. Spring reads the flag through `SpringProperties` (a JVM system property
    or `spring.properties`); Flint reads this environment's system properties (`flint.getenv.ignore`, or its
    `spring.` alias) and then the environment variable `FLINT_GETENV_IGNORE`.
    +/
    protected bool suppressGetenvAccess()
    {
        import std.process : environment;
        import flint.java.lang : Boolean;

        if (systemProperties !is null)
        {
            foreach (key; aliasesOf(IGNORE_GETENV_PROPERTY_NAME))
            {
                auto value = systemProperties.get(key);
                if (!value.isNull)
                    return Boolean.parseBoolean(value.toString());
            }
        }
        return Boolean.parseBoolean(environment.get("FLINT_GETENV_IGNORE", null));
    }

    /// Append `parent`'s sources and profiles.
    void merge(ConfigurableEnvironment parent)
    {
        foreach (source; parent.getPropertySources().toArray())
            if (!propertySources.contains(source.getName()))
                propertySources.addLast(source);
        foreach (profile; parent.getActiveProfiles())
            addUnique(activeProfiles, profile);
        auto parentDefaults = parent.getDefaultProfiles();
        if (parentDefaults.length)
        {
            string[] merged;
            foreach (profile; defaultProfiles)
                if (profile != RESERVED_DEFAULT_PROFILE_NAME)
                    merged ~= profile;
            foreach (profile; parentDefaults)
                addUnique(merged, profile);
            defaultProfiles = merged;
        }
    }

    /// The resolver's conversion service.
    ConfigurableConversionService getConversionService()
    {
        return propertyResolver.getConversionService();
    }

    /// Set the resolver's conversion service.
    void setConversionService(ConfigurableConversionService conversionService)
    {
        propertyResolver.setConversionService(conversionService);
    }

    /// Set the placeholder prefix.
    void setPlaceholderPrefix(string placeholderPrefix)
    {
        propertyResolver.setPlaceholderPrefix(placeholderPrefix);
    }

    /// Set the placeholder suffix.
    void setPlaceholderSuffix(string placeholderSuffix)
    {
        propertyResolver.setPlaceholderSuffix(placeholderSuffix);
    }

    /// Set the value separator.
    void setValueSeparator(string valueSeparator)
    {
        propertyResolver.setValueSeparator(valueSeparator);
    }

    /// Set the escape character.
    void setEscapeCharacter(char escapeCharacter)
    {
        propertyResolver.setEscapeCharacter(escapeCharacter);
    }

    /// Whether unresolvable nested placeholders are ignored.
    void setIgnoreUnresolvableNestedPlaceholders(bool ignoreUnresolvableNestedPlaceholders)
    {
        propertyResolver.setIgnoreUnresolvableNestedPlaceholders(ignoreUnresolvableNestedPlaceholders);
    }

    /// Add required properties.
    void setRequiredProperties(string[] requiredProperties...)
    {
        propertyResolver.setRequiredProperties(requiredProperties);
    }

    /// Validate the required properties.
    void validateRequiredProperties()
    {
        propertyResolver.validateRequiredProperties();
    }

    /// Whether the property is available.
    bool containsProperty(string key)
    {
        return propertyResolver.containsProperty(key);
    }

    /// The property converted to `targetType`, from the resolver.
    Any getPropertyErased(string key, const TypeDescriptor targetType)
    {
        return propertyResolver.getPropertyErased(key, targetType);
    }

    /// Resolve placeholders leniently.
    string resolvePlaceholders(string text)
    {
        return propertyResolver.resolvePlaceholders(text);
    }

    /// Resolve placeholders strictly.
    string resolveRequiredPlaceholders(string text)
    {
        return propertyResolver.resolveRequiredPlaceholders(text);
    }

    /// `StandardEnvironment {activeProfiles=[..], defaultProfiles=[..], propertySources=[..]}`.
    override string toString()
    {
        import flint.engine.aot.name : simpleTypeName;

        const profiles = "activeProfiles=" ~ list(activeProfiles) ~ ", defaultProfiles=" ~ list(defaultProfiles);
        return simpleTypeName(typeid(this).name) ~ " {" ~ profiles ~ ", propertySources=" ~ propertySources.toString()
            ~ "}";
    }

    /// A comma-delimited profile property, every whitespace character removed.
    private static string[] profileList(string profiles)
    {
        return StringUtils.commaDelimitedListToStringArray(StringUtils.trimAllWhitespace(profiles));
    }

    private static string list(string[] values)
    {
        string result = "[";
        foreach (i, value; values)
            result ~= (i ? ", " : "") ~ value;
        return result ~ "]";
    }

    private static bool contains(string[] values, string value) pure nothrow @nogc
    {
        foreach (candidate; values)
            if (candidate == value)
                return true;
        return false;
    }

    private static void addUnique(ref string[] values, string value) pure nothrow
    {
        if (!contains(values, value))
            values ~= value;
    }
}

/// The `Environment` for standard applications: system properties, then the system environment.
class StandardEnvironment : AbstractEnvironment
{
    /// The name of the system environment property source.
    enum SYSTEM_ENVIRONMENT_PROPERTY_SOURCE_NAME = "systemEnvironment";
    /// The name of the system properties property source.
    enum SYSTEM_PROPERTIES_PROPERTY_SOURCE_NAME = "systemProperties";

    /// A standard environment.
    this()
    {
        super();
    }

    /// A standard environment over `propertySources`.
    protected this(MutablePropertySources propertySources)
    {
        super(propertySources);
    }

    /// Add `systemProperties` then `systemEnvironment`.
    protected override void customizePropertySources(MutablePropertySources propertySources)
    {
        propertySources.addLast(new MapPropertySource(SYSTEM_PROPERTIES_PROPERTY_SOURCE_NAME, getSystemProperties()));
        propertySources.addLast(new SystemEnvironmentPropertySource(SYSTEM_ENVIRONMENT_PROPERTY_SOURCE_NAME,
                getSystemEnvironment()));
    }
}
