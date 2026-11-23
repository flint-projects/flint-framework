/*
 * Ported from Jackson (jackson-databind) 3.1.8, https://github.com/FasterXML/jackson-databind,
 * tag jackson-databind-3.1.8: src/main/java/tools/jackson/databind/introspect/
 * {POJOPropertiesCollector,BeanPropertyDefinition,POJOPropertyBuilder}.java
 *
 * Jackson JSON-processor.
 * Copyright (c) 2007- Tatu Saloranta, tatu.saloranta@iki.fi
 * Licensed under the Apache License, Version 2.0.
 *
 * Modified by the Flint authors: the collector reads a Flint AOT descriptor
 * (Java-Beans properties with merged annotations, and constructors) instead of
 * reflecting over a class. Its rules are Jackson 3.1.8's: explicit names, ignoral,
 * naming strategies applied to implicit names, creator selection (_addCreators),
 * and ordering (_sortProperties).
 */

/// Property introspection: from a descriptor to the ordered logical properties Jackson serializes.
module flint.jackson.databind.introspect;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : ConstructorDescriptor, Descriptor, MergedAnnotation,
    PropertyDescriptor, TypeKind, findAnnotation;
import flint.engine.aot.name : typeNameOf;
import std.traits : isDynamicArray;
import flint.jackson.annotation : JsonAlias, JsonAnyGetter, JsonCreator, JsonUnwrapped, JsonFormat,
    JsonGetter, JsonIgnore,
    JsonIgnoreProperties, JsonInclude, JsonIncludeProperties, JsonProperty, JsonPropertyOrder,
    JsonRawValue, JsonSetter, JsonValue;
import flint.jackson.databind.annotation : JsonNaming;
import flint.jackson.databind.exc : InvalidDefinitionException;

@safe:

/// Read the merged annotation of type `T`, as a value; false when it is absent.
bool annotation(T)(scope const(MergedAnnotation)[] annotations, out T value)
{
    auto found = findAnnotation(annotations, typeNameOf!T);
    if (found is null)
        return false;
    // The merged value is const; copy it element by element, duplicating arrays, into a mutable T.
    const merged = found.value.get!T();
    static foreach (i; 0 .. T.tupleof.length)
    {
        static if (is(typeof(T.tupleof[i]) : const(char)[]) || !isDynamicArray!(typeof(T.tupleof[i])))
            value.tupleof[i] = merged.tupleof[i];
        else
            value.tupleof[i] = merged.tupleof[i].dup;
    }
    return true;
}

/// A logical property: its external name, accessors and the annotation-derived settings serialization uses.
final class BeanPropertyDefinition
{
    /// The external (JSON) name.
    string name;
    /// The descriptor's property name (the implicit name), or the creator parameter's name.
    string internalName;
    /// Whether the name came from an annotation, so naming strategies leave it alone.
    bool explicitName;
    /// The descriptor property, or null for a creator-only property.
    const(PropertyDescriptor)* accessor;
    /// The declared Flint type name.
    string type;
    /// Alternative names accepted on input.
    string[] aliases;
    /// `@JsonProperty(access)`.
    JsonProperty.Access access = JsonProperty.Access.AUTO;
    /// `@JsonInclude` on the property, or `USE_DEFAULTS`.
    JsonInclude.Include inclusion = JsonInclude.Include.USE_DEFAULTS;
    /// `@JsonFormat` on the property, when `hasFormat`.
    JsonFormat format;
    /// Whether the property has `@JsonFormat`.
    bool hasFormat;
    /// `@JsonRawValue`.
    bool rawValue;
    /// `@JsonValue`.
    bool jsonValue;
    /// `@JsonAnyGetter`: a map whose entries are written as properties of the containing object.
    bool anyGetter;
    /// `@JsonUnwrapped`: the value's properties are written inline, renamed with `unwrapPrefix`/`unwrapSuffix`.
    bool unwrapped;
    /// ditto
    string unwrapPrefix;
    /// ditto
    string unwrapSuffix;
    /// `@JsonProperty(required)`.
    bool required;
    /// `@JsonProperty(index)`.
    int index = -1;
    /// Position among the creator's parameters, or -1.
    int creatorIndex = -1;
    /// The merged annotations of the property, for datatype handlers.
    const(MergedAnnotation)[] annotations;
    /// Whether a type-level `NON_DEFAULT` compares this property with `defaultValue`, its value in a
    /// default-constructed bean (Jackson's `PropertyBuilder` "real property defaults").
    bool realDefault;
    /// ditto
    Any defaultValue;

    /// Whether serialization writes this property.
    bool isReadable() const pure nothrow @nogc
    {
        return accessor !is null && accessor.get !is null && access != JsonProperty.Access.WRITE_ONLY;
    }

    /// Whether deserialization accepts this property.
    bool isWritable() const pure nothrow @nogc
    {
        return access != JsonProperty.Access.READ_ONLY && (creatorIndex >= 0 || (accessor !is null
                && accessor.set !is null));
    }
}

/// The collected view of one type: ordered properties, the creator, and type-level settings.
final class BeanDescription
{
    /// The descriptor.
    const Descriptor descriptor;
    /// Properties in serialization order.
    BeanPropertyDefinition[] properties;
    /// The properties-based creator, when one was selected.
    const(ConstructorDescriptor)* creator;
    /// Creator properties, by parameter position.
    BeanPropertyDefinition[] creatorProperties;
    /// Names that are ignored on input without being unknown.
    bool[string] ignoredNames;
    /// `@JsonIgnoreProperties(ignoreUnknown: true)`.
    bool ignoreUnknown;
    /// `@JsonInclude` on the type, or `USE_DEFAULTS`.
    JsonInclude.Include inclusion = JsonInclude.Include.USE_DEFAULTS;
    /// The `@JsonValue` property, if any.
    BeanPropertyDefinition jsonValue;
    /// The `@JsonAnyGetter` property, if any: written after the regular properties, not as one of them.
    BeanPropertyDefinition anyGetter;

    ///
    this(const Descriptor descriptor) pure nothrow @nogc
    {
        this.descriptor = descriptor;
    }

    /// The property accepting `name` on input (by name or alias), or null.
    BeanPropertyDefinition findForInput(scope const(char)[] name)
    {
        foreach (p; properties)
            if (p.name == name)
                return p;
        foreach (p; properties)
            foreach (a; p.aliases)
                if (a == name)
                    return p;
        return null;
    }
}

/// The naming strategy hook the collector applies to implicit names.
alias NameTranslator = string delegate(string implicitName) @safe;

/**
 * Helper class used for aggregating information about all possible properties
 * of a POJO, and their ordering.
 */
struct POJOPropertiesCollector
{
    /// `MapperFeature.SORT_PROPERTIES_ALPHABETICALLY`.
    bool sortAlphabetically = true;
    /// `MapperFeature.SORT_CREATOR_PROPERTIES_FIRST`.
    bool sortCreatorPropertiesFirst = true;
    /// Whether properties-based creators may be detected without `@JsonCreator`.
    bool implicitCreators = true;
    /// The naming strategy, or null.
    NameTranslator naming;
    /// The strategy a `@JsonNaming` class names, or null when it has no binding.
    NameTranslator function(string strategyClass) @safe classNaming;

    /// Collect the logical properties of the type `d` describes.
    BeanDescription collect(const Descriptor d)
    {
        auto bean = new BeanDescription(d);
        JsonInclude classInclude;
        if (annotation(d.annotations, classInclude))
            bean.inclusion = classInclude.value;
        foreach (i, ref p; d.properties)
            bean.properties ~= define(&d.properties[i]);
        addCreator(bean);
        removeIgnored(bean);
        rename(bean);
        sort(bean);
        BeanPropertyDefinition[] regular;
        foreach (p; bean.properties)
        {
            if (p.jsonValue)
                bean.jsonValue = p;
            if (p.anyGetter && bean.anyGetter is null)
                bean.anyGetter = p;
            else
                regular ~= p;
        }
        bean.properties = regular;
        return bean;
    }

    private static BeanPropertyDefinition define(const(PropertyDescriptor)* p)
    {
        auto def = new BeanPropertyDefinition();
        def.internalName = p.name;
        def.name = p.name;
        def.accessor = p;
        def.type = p.type;
        def.annotations = p.annotations;
        readAnnotations(def, p.annotations);
        return def;
    }

    private static void readAnnotations(BeanPropertyDefinition def, scope const(MergedAnnotation)[] annotations)
    {
        JsonProperty property;
        if (annotation(annotations, property))
        {
            if (property.value.length)
                rename(def, property.value);
            def.access = property.access;
            def.index = property.index;
            def.required = property.required;
        }
        JsonGetter getter;
        if (annotation(annotations, getter) && getter.value.length)
            rename(def, getter.value);
        JsonSetter setter;
        if (annotation(annotations, setter) && setter.value.length)
            rename(def, setter.value);
        JsonAlias alias_;
        if (annotation(annotations, alias_))
            def.aliases = alias_.value.dup;
        JsonInclude include;
        if (annotation(annotations, include))
            def.inclusion = include.value;
        def.hasFormat = annotation(annotations, def.format);
        JsonRawValue raw;
        def.rawValue = annotation(annotations, raw) && raw.value;
        JsonValue value;
        def.jsonValue = annotation(annotations, value) && value.value;
        JsonAnyGetter any;
        def.anyGetter = annotation(annotations, any) && any.enabled;
        JsonUnwrapped unwrap;
        if (annotation(annotations, unwrap) && unwrap.enabled)
        {
            def.unwrapped = true;
            def.unwrapPrefix = unwrap.prefix;
            def.unwrapSuffix = unwrap.suffix;
        }
    }

    private static void rename(BeanPropertyDefinition def, string name)
    {
        def.name = name;
        def.explicitName = true;
    }

    // _addCreators: an explicit @JsonCreator, else a constructor whose parameters are all named with
    // @JsonProperty, else a record's canonical constructor, else one public non-default constructor.
    // Flint AOT marks a struct's field-wise constructor canonical; a hand-built struct descriptor without
    // parameterized constructors is treated as a record over its fields.
    private void addCreator(BeanDescription bean)
    {
        const d = bean.descriptor;
        if (d.kind == TypeKind.struct_ && !hasParameterizedConstructor(d))
        {
            // Rulebook R11: a struct without constructors is a record; its fields are the canonical creator's
            // parameters, in declaration order.
            int position;
            foreach (p; bean.properties)
            {
                if (p.accessor.set is null || p.accessor.get is null)
                    continue;
                p.creatorIndex = position;
                position += 1;
            }
            return;
        }
        auto chosen = chooseCreator(d);
        if (chosen !is null)
            bindCreator(bean, chosen);
    }

    private const(ConstructorDescriptor)* chooseCreator(const Descriptor d)
    {
        const(ConstructorDescriptor)* named;
        const(ConstructorDescriptor)* implicit;
        const(ConstructorDescriptor)* canonical;
        size_t candidates;
        foreach (i, ref c; d.constructors)
        {
            if (c.parameters.length == 0)
                continue;
            JsonCreator creator;
            if (annotation(c.annotations, creator))
            {
                if (creator.mode != JsonCreator.Mode.DISABLED && creator.mode != JsonCreator.Mode.DELEGATING)
                    return &d.constructors[i];
                continue;
            }
            if (c.canonical && canonical is null)
                canonical = &d.constructors[i];
            ++candidates;
            implicit = &d.constructors[i];
            if (named is null && allParametersNamed(c))
                named = &d.constructors[i];
        }
        // A record's canonical constructor is its creator unless another is annotated (POJOPropertiesCollector).
        if (canonical !is null)
            return canonical;
        if (named !is null)
            return named;
        return implicitCreators && candidates == 1 ? implicit : null;
    }

    private static void bindCreator(BeanDescription bean, const(ConstructorDescriptor)* chosen)
    {
        bean.creator = chosen;
        foreach (i, ref parameter; chosen.parameters)
        {
            JsonProperty named;
            const external = annotation(parameter.annotations, named) && named.value.length
                ? named.value : parameter.name;
            auto def = bean.findForInput(external);
            if (def is null)
            {
                def = new BeanPropertyDefinition();
                def.name = external;
                def.internalName = parameter.name;
                def.type = parameter.type;
                def.annotations = parameter.annotations;
                readAnnotations(def, parameter.annotations);
                bean.properties ~= def;
            }
            def.creatorIndex = cast(int) i;
            bean.creatorProperties ~= def;
        }
    }

    private static bool hasParameterizedConstructor(const Descriptor d) pure nothrow @nogc
    {
        foreach (ref c; d.constructors)
            if (c.parameters.length)
                return true;
        return false;
    }

    private static bool allParametersNamed(ref const ConstructorDescriptor c)
    {
        foreach (ref parameter; c.parameters)
        {
            JsonProperty named;
            if (!annotation(parameter.annotations, named) || named.value.length == 0)
                return false;
        }
        return true;
    }

    // _removeUnwantedProperties plus @JsonIgnoreProperties and @JsonIncludeProperties.
    private static void removeIgnored(BeanDescription bean)
    {
        const d = bean.descriptor;
        JsonIgnoreProperties ignore;
        if (annotation(d.annotations, ignore))
        {
            bean.ignoreUnknown = ignore.ignoreUnknown;
            foreach (name; ignore.value)
                bean.ignoredNames[name] = true;
        }
        JsonIncludeProperties include;
        const including = annotation(d.annotations, include);
        BeanPropertyDefinition[] kept;
        string[] ignoredAccessors;
        foreach (p; bean.properties)
        {
            // @JsonIgnore removes its own accessor's property; another property explicitly named the same stays
            // (Jackson's ignoral is by accessor; @JsonIgnoreProperties ignores by name).
            JsonIgnore ignored;
            if (annotation(p.annotations, ignored) && ignored.value)
            {
                ignoredAccessors ~= p.name;
                continue;
            }
            if (p.name in bean.ignoredNames || (including && !contains(include.value, p.name)))
            {
                bean.ignoredNames[p.name] = true;
                continue;
            }
            kept ~= p;
        }
        bean.properties = kept;
        foreach (name; ignoredAccessors)
            if (bean.findForInput(name) is null)
                bean.ignoredNames[name] = true;
    }

    // A class's @JsonNaming overrides the mapper's strategy.
    private void rename(BeanDescription bean)
    {
        auto translator = naming;
        JsonNaming named;
        if (annotation(bean.descriptor.annotations, named) && named.value.name.length)
        {
            translator = classNaming is null ? null : classNaming(named.value.name);
            if (translator is null)
                throw new InvalidDefinitionException("Cannot construct naming strategy `" ~ named.value.name ~ "` for `"
                        ~ bean.descriptor.name ~ "`: Flint binds the standard PropertyNamingStrategies only",
                        bean.descriptor.name);
        }
        if (translator is null)
            return;
        foreach (p; bean.properties)
            if (!p.explicitName)
                p.name = translator(p.name);
    }

    // _sortProperties: @JsonPropertyOrder names, then indexed properties, then creator properties in creator
    // order, then the rest, alphabetically when sorting is on.
    private void sort(BeanDescription bean)
    {
        const d = bean.descriptor;
        JsonPropertyOrder order;
        const hasOrder = annotation(d.annotations, order);
        auto rest = bean.properties.dup;
        if ((hasOrder && order.alphabetic) || sortAlphabetically)
            sortBy!((a, b) => compareUtf16(a.name, b.name) > 0)(rest);
        BeanPropertyDefinition[] ordered;
        if (hasOrder)
            foreach (name; order.value)
                take(rest, ordered, (p) => p.name == name || p.internalName == name);
        auto indexed = select(rest, (p) => p.index >= 0);
        sortBy!((a, b) => a.index > b.index)(indexed);
        foreach (p; indexed)
            take(rest, ordered, (q) => q is p);
        if (sortCreatorPropertiesFirst)
        {
            auto creators = select(rest, (p) => p.creatorIndex >= 0);
            sortBy!((a, b) => a.creatorIndex > b.creatorIndex)(creators);
            foreach (p; creators)
                take(rest, ordered, (q) => q is p);
        }
        bean.properties = ordered ~ rest;
    }

    // A stable insertion sort; `after(a, b)` says whether a belongs after b.
    private static void sortBy(alias after)(BeanPropertyDefinition[] items)
    {
        foreach (i; 1 .. items.length)
            for (size_t j = i; j > 0 && after(items[j - 1], items[j]); --j)
                exchange(items[j], items[j - 1]);
    }

    private static void exchange(ref BeanPropertyDefinition a, ref BeanPropertyDefinition b) pure nothrow @nogc
    {
        BeanPropertyDefinition[2] pair = [b, a];
        a = pair[0];
        b = pair[1];
    }

    private static BeanPropertyDefinition[] select(BeanPropertyDefinition[] items,
            scope bool delegate(BeanPropertyDefinition) @safe keep)
    {
        BeanPropertyDefinition[] result;
        foreach (p; items)
            if (keep(p))
                result ~= p;
        return result;
    }

    // Move every item of `rest` that `matches` to the end of `ordered`, keeping their order.
    private static void take(ref BeanPropertyDefinition[] rest, ref BeanPropertyDefinition[] ordered,
            scope bool delegate(BeanPropertyDefinition) @safe matches)
    {
        BeanPropertyDefinition[] kept;
        foreach (p; rest)
        {
            if (matches(p))
                ordered ~= p;
            else
                kept ~= p;
        }
        rest = kept;
    }

    private static bool contains(scope const(string)[] names, string name) pure nothrow @nogc
    {
        foreach (n; names)
            if (n == name)
                return true;
        return false;
    }
}

/// Java's `String.compareTo`: lexicographic order of UTF-16 code units (rulebook R14).
int compareUtf16(scope const(char)[] a, scope const(char)[] b) pure nothrow
{
    import std.utf : byWchar;

    auto x = a.byWchar;
    auto y = b.byWchar;
    for (; !x.empty && !y.empty; x.popFront(), y.popFront())
        if (x.front != y.front)
            return x.front < y.front ? -1 : 1;
    if (x.empty && y.empty)
        return 0;
    return x.empty ? -1 : 1;
}

@("compareUtf16 orders as Java's String.compareTo")
unittest
{
    assert(compareUtf16("content", "id") < 0 && compareUtf16("id", "id") == 0 && compareUtf16("idx", "id") > 0);
    assert(compareUtf16("Zeta", "alpha") < 0, "upper case sorts before lower case, as in Java");
    // U+FF21 (one UTF-16 unit) sorts after U+1F600 (a surrogate pair starting 0xD83D) in Java, unlike UTF-8 order.
    assert(compareUtf16("Ａ", "\U0001F600") > 0);
}
