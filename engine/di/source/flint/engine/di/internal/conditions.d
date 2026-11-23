/// Compile-time conditional registration and starter auto-configuration (ADR-028 section 1).
///
/// Conditions are resolved while the bean list is flattened, before the graph is built, so a disabled bean costs
/// nothing at run time and an enabled one is wired exactly like an explicit registration. Configuration presence
/// is read from the application's `config/application.toml`, which flint makes a string import; a context can
/// instead declare its sections with `ConfiguredSections`.
module flint.engine.di.internal.conditions;

import flint.engine.di.internal.registrations : BeanRegistrar, Bind, Concrete, Key, Provided, Registrations;
import std.meta : AliasSeq, Filter, staticMap;

@safe:

/// Register the annotated bean only when the application's configuration has this section (a table such as
/// `[database]`, a dotted key such as `database.url`, or a nested table such as `[database.pool]`).
struct ConditionalOnConfig
{
    /// Section name, without brackets.
    string section;
}

/// Register the annotated bean only when no other registration has the same key. Auto-configuration entries
/// behave this way without the attribute.
struct ConditionalOnMissingBean
{
}

/// A starter's default registrations. Each entry yields to an explicit registration of the same key and honours
/// its own `@ConditionalOnConfig`. Each Flint Boot auto-configuration library exports one, such as
/// `flint.boot_autoconfigure_data.DataSourceAutoConfiguration`.
struct AutoConfiguration(Entries...)
{
}

/// Declare which configuration sections are present instead of reading `config/application.toml`; for tests and
/// for builds without flint.
struct ConfiguredSections(Names...)
{
    static foreach (name; Names)
        static assert(is(typeof(name) : string), "ConfiguredSections takes section names");
}

/// Not a bean: a type an application runner calls after the context starts, such as a web server launcher
/// (ADR-028 section 8). It honours the `@ConditionalOnConfig` of `T`; `AppContext.Launchers` lists the enabled
/// ones in order.
struct Launcher(T)
{
}

// An entry that came from an auto-configuration list.
private struct Default(T)
{
}

private template expandExplicit(T)
{
    static if (is(T == BeanRegistrar!Entries, Entries...))
        alias expandExplicit = staticMap!(.expandExplicit, Entries);
    else static if (is(T == AutoConfiguration!Entries, Entries...))
        alias expandExplicit = staticMap!(expandDefault, Entries);
    else
        alias expandExplicit = T;
}

private template expandDefault(T)
{
    static if (is(T == BeanRegistrar!Entries, Entries...) || is(T == AutoConfiguration!Entries, Entries...))
        alias expandDefault = staticMap!(.expandDefault, Entries);
    else static if (is(T == ConfiguredSections!Names, Names...) || is(T == Launcher!U, U))
        alias expandDefault = T;
    else
        alias expandDefault = Default!T;
}

private enum bool isDefault(T) = is(T == Default!U, U);
private enum bool isSections(T) = is(T == ConfiguredSections!Names, Names...);
private enum bool isLauncher(T) = is(T == Launcher!U, U);

private template unwrap(T)
{
    static if (is(T == Default!U, U))
        alias unwrap = U;
    else
        alias unwrap = T;
}

// The type whose attributes carry an entry's conditions.
private template Annotated(T)
{
    alias Plain = unwrap!T;
    static if (is(Plain == Launcher!Value, Value))
        alias Annotated = Value;
    else static if (is(Plain == Provided!Value, Value))
        alias Annotated = Value;
    else
        alias Annotated = Concrete!Plain;
}

/// The sections an entry requires.
private string[] requiredSections(T)()
{
    string[] sections;
    static foreach (attribute; __traits(getAttributes, Annotated!T))
    {
        static if (is(typeof(attribute) == ConditionalOnConfig))
            sections ~= attribute.section;
    }
    return sections;
}

private bool yields(T)()
{
    static if (isDefault!T)
        return true;
    else
    {
        static foreach (attribute; __traits(getAttributes, Annotated!T))
        {
            static if (is(attribute == ConditionalOnMissingBean) || is(typeof(attribute) == ConditionalOnMissingBean))
                return true;
        }
        return false;
    }
}

/// Whether any entry needs condition resolution; plain lists keep the original flattening. One function, so a
/// context without conditions instantiates nothing per bean (ADR-019's template budget).
private bool conditional(Entries...)()
{
    static foreach (Entry; Entries)
    {
        {
            static if (is(Entry == AutoConfiguration!Nested, Nested...)
                    || is(Entry == ConfiguredSections!Names, Names...))
                return true;
            else static if (is(Entry == BeanRegistrar!Nested, Nested...))
            {
                if (conditional!Nested())
                    return true;
            }
            else
            {
                static if (is(Entry == Provided!Value, Value))
                    alias Target = Value;
                else static if (is(Entry == Bind!(Contract, Implementation), Contract, Implementation))
                    alias Target = Implementation;
                else
                    alias Target = Entry;
                static foreach (attribute; __traits(getAttributes, Target))
                {
                    static if (is(typeof(attribute) == ConditionalOnConfig)
                            || is(attribute == ConditionalOnMissingBean)
                            || is(typeof(attribute) == ConditionalOnMissingBean))
                        return true;
                }
            }
        }
    }
    return false;
}

/// Section names declared by a TOML document: tables, arrays of tables and dotted or inline top-level keys.
string[] tomlSections(string text) pure
{
    string[] sections;
    bool topLevel = true;
    size_t start;
    foreach (index; 0 .. text.length + 1)
    {
        if (index < text.length && text[index] != '\n')
            continue;
        const line = strip(text[start .. index]);
        start = index + 1;
        if (line.length == 0 || line[0] == '#')
            continue;
        if (line[0] == '[')
        {
            size_t open = 1;
            while (open < line.length && line[open] == '[')
                open++;
            size_t close = open;
            while (close < line.length && line[close] != ']')
                close++;
            sections ~= strip(line[open .. close]);
            topLevel = false;
        }
        else if (topLevel)
        {
            size_t equals;
            while (equals < line.length && line[equals] != '=')
                equals++;
            if (equals < line.length)
                sections ~= strip(line[0 .. equals]);
        }
    }
    return sections;
}

private string strip(string text) pure
{
    size_t begin;
    size_t end = text.length;
    while (begin < end && (text[begin] == ' ' || text[begin] == '\t' || text[begin] == '\r'))
        begin++;
    while (end > begin && (text[end - 1] == ' ' || text[end - 1] == '\t' || text[end - 1] == '\r'))
        end--;
    return text[begin .. end];
}

/// Whether `required` names one of `present` or a parent of one.
bool sectionPresent(scope const string[] present, string required) pure
{
    foreach (name; present)
    {
        if (name == required || (name.length > required.length
                && name[0 .. required.length] == required && name[required.length] == '.'))
            return true;
    }
    return false;
}

// The application's configuration, when flint made config/ a string import path.
private template applicationSections()
{
    static if (__traits(compiles, import("application.toml")))
        enum string[] applicationSections = tomlSections(import("application.toml"));
    else
        enum string[] applicationSections = null;
}

private string[] declaredSections(Flat...)()
{
    string[] sections;
    bool declared;
    static foreach (Entry; Flat)
    {
        static if (is(Entry == ConfiguredSections!Names, Names...))
        {
            declared = true;
            static foreach (name; Names)
                sections ~= name;
        }
    }
    return declared ? sections : applicationSections!();
}

/// The registrations of a context after expanding registrars and auto-configuration lists and applying their
/// conditions, in declaration order.
template Resolved(Entries...)
{
    static if (!conditional!Entries())
        alias Resolved = Registrations!Entries;
    else
    {
        alias Flat = staticMap!(expandExplicit, Entries);
        enum string[] present = declaredSections!Flat();
        enum bool beanEntry(T) = !isSections!T && !isLauncher!T;
        enum bool configured(T) = () {
            foreach (section; requiredSections!T())
            {
                if (!sectionPresent(present, section))
                    return false;
            }
            return true;
        }();
        alias Candidates = Filter!(configured, Filter!(beanEntry, Flat));

        // A yielding entry is dropped when a non-yielding candidate has its key, or an earlier yielding one does.
        enum bool kept(size_t position) = () {
            alias Entry = Candidates[position];
            if (!yields!Entry())
                return true;
            bool keep = true;
            static foreach (other, Other; Candidates)
            {
                static if (other != position && is(Key!(unwrap!Other) == Key!(unwrap!Entry)))
                {
                    if (!yields!Other() || other < position)
                        keep = false;
                }
            }
            return keep;
        }();

        template select(size_t position)
        {
            static if (position == Candidates.length)
                alias select = AliasSeq!();
            else static if (kept!position)
                alias select = AliasSeq!(unwrap!(Candidates[position]), select!(position + 1));
            else
                alias select = select!(position + 1);
        }

        alias Resolved = select!0;
    }
}

/// The enabled `Launcher!T` entries of a context, as their `T`, in declaration order.
template ResolvedLaunchers(Entries...)
{
    static if (!conditional!Entries())
        alias ResolvedLaunchers = AliasSeq!();
    else
    {
        alias Flat = staticMap!(expandExplicit, Entries);
        enum string[] present = declaredSections!Flat();
        enum bool enabled(T) = () {
            static if (!isLauncher!T)
                return false;
            else
            {
                foreach (section; requiredSections!T())
                {
                    if (!sectionPresent(present, section))
                        return false;
                }
                return true;
            }
        }();
        template target(T)
        {
            static if (is(T == Launcher!U, U))
                alias target = U;
        }

        alias ResolvedLaunchers = staticMap!(target, Filter!(enabled, Flat));
    }
}
