/++
Canonical type names: the strings Flint AOT writes into generated tables and the runtime compares.

A type's name is `__traits(fullyQualifiedName, T)` as DMD prints it. LDC prints a template instance with its
eponymous member repeated (`app.Opt!(Owner).Opt` for DMD's `app.Opt!(Owner)`), so `typeNameOf` removes that
suffix and both compilers agree with the generator.
+/
module flint.engine.aot.name;

@safe:

/// The canonical fully qualified name of `T`, as generated tables spell it.
template typeNameOf(T)
{
    enum string typeNameOf = canonicalTypeName(__traits(fullyQualifiedName, T));
}

/// Remove LDC's repeated eponymous members from template instance names, at any depth:
/// `a.B!(C).B` becomes `a.B!(C)`, and `a.M!(string, a.O!(int).O).M` becomes `a.M!(string, a.O!(int))`.
string canonicalTypeName(string name) pure nothrow
{
    string result;
    string[] templates; // the identifier owning each open '!(' (empty for a plain parenthesis)
    size_t i;
    while (i < name.length)
    {
        const c = name[i];
        if (c == '(')
        {
            string owner;
            if (i > 0 && name[i - 1] == '!')
            {
                size_t s = i - 1;
                while (s > 0 && isIdentifierChar(name[s - 1]))
                    s--;
                owner = name[s .. i - 1];
            }
            templates ~= owner;
            result ~= c;
            i++;
            continue;
        }
        if (c == ')' && templates.length)
        {
            const owner = templates[$ - 1];
            templates = templates[0 .. $ - 1];
            result ~= c;
            i++;
            if (owner.length && i + 1 + owner.length <= name.length && name[i] == '.'
                    && name[i + 1 .. i + 1 + owner.length] == owner
                    && (i + 1 + owner.length == name.length || !isIdentifierChar(name[i + 1 + owner.length])))
                i += 1 + owner.length;
            continue;
        }
        result ~= c;
        i++;
    }
    return result;
}

private bool isIdentifierChar(char c) pure nothrow @nogc
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c >= 0x80;
}

/// The last component of a qualified name, ignoring template arguments: `a.b.Owner` gives `Owner`.
string simpleTypeName(string name) pure nothrow @nogc
{
    size_t depth, start;
    foreach (i, c; name)
    {
        if (c == '(')
            depth++;
        else if (c == ')')
        {
            if (depth)
                depth--;
        }
        else if (c == '.' && depth == 0)
            start = i + 1;
        else if (c == '!' && depth == 0)
            return name[start .. i];
    }
    return name[start .. $];
}

unittest
{
    assert(canonicalTypeName("app.t.Opt!(Owner).Opt") == "app.t.Opt!(Owner)");
    assert(canonicalTypeName("app.t.Opt!(Owner)") == "app.t.Opt!(Owner)");
    assert(canonicalTypeName("app.t.Map!(string, app.t.Opt!(int).Opt).Map") == "app.t.Map!(string, app.t.Opt!(int))");
    assert(canonicalTypeName("app.t.Opt!(Owner).Optional") == "app.t.Opt!(Owner).Optional");
    assert(canonicalTypeName("app.t.Opt!(Owner).Inner") == "app.t.Opt!(Owner).Inner");
    assert(canonicalTypeName("int") == "int" && canonicalTypeName("app.Owner[]") == "app.Owner[]");
    assert(simpleTypeName("app.t.Owner") == "Owner" && simpleTypeName("app.t.Opt!(a.B)") == "Opt");
    assert(typeNameOf!int == "int" && typeNameOf!string == "string");
}
