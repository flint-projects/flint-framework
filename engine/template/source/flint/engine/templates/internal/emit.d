/// Compile one resource graph to direct typed D statements.
module flint.engine.templates.internal.emit;

import flint.arena : __flintError = Error, RequestArena, __flintStatus = Status;
import flint.engine.templates.context : __flintEscape = EscapeKind;
import flint.engine.templates.output : Writer;
import flint.engine.templates.parser : Kind, Node, canonical, diagnosis, maxInclude, maxNodes, maxSourceBytes, parse;
import flint.engine.templates.types : __flintTrusted = TrustedHtml;
import std.conv : to;
import std.traits : __flintUnqual = Unqual, __flintArray = isArray;

@safe:
package(flint.engine.templates):

private struct Generated
{
    string body;
    size_t bytes;
    size_t nodes;
}

private template __flintDocument(string filename)
{
    enum source = import(filename);
    enum parsed = parse(filename, source);
    static assert(parsed.error.length == 0, parsed.error);
}

private bool includes(string[] parents, string path) pure nothrow @nogc
{
    foreach (parent; parents)
    {
        if (parent == path)
            return true;
    }
    return false;
}

private template Expansion(string filename, string[] parents, string origin)
{
    static assert(!includes(parents, filename), origin ~ ": template include cycle at " ~ filename);
    static assert(parents.length <= maxInclude, origin ~ ": template include depth exceeds 16");
    static if (parents.length <= maxInclude && !includes(parents, filename))
    {
        alias content = __flintDocument!filename;
        enum Generated expanded = build();

        private Generated build()
        {
            Generated result = Generated(null, content.source.length, content.parsed.nodes.length);
            static foreach (entry; content.parsed.nodes)
            {
                {
                    static if (entry.kind == Kind.includeFile)
                    {
                        enum location = diagnosis(filename, content.source, entry.offset, "include");
                        alias child = Expansion!(entry.value, parents ~ filename, location);
                        enum nested = child.expanded;
                        if (nested.bytes > maxSourceBytes - result.bytes || nested.nodes > maxNodes - result.nodes)
                            return Generated(null, maxSourceBytes + 1, 0);
                        result.bytes += nested.bytes;
                        result.nodes += nested.nodes;
                        result.body ~= nested.body;
                    }
                    else
                        result.body ~= spell(entry, filename, content.source);
                }
            }
            return result;
        }

        static assert(expanded.bytes <= maxSourceBytes,
                filename ~ ": expanded template exceeds bytes or operation limit");
    }
}

private string quote(string bytes)
{
    string escaped = "\"";
    enum hex = "0123456789abcdef";
    foreach (value; bytes)
    {
        if (value == '"' || value == '\\' || value < ' ')
        {
            escaped ~= "\\x";
            escaped ~= hex[(cast(ubyte) value) >> 4];
            escaped ~= hex[value & 15];
        }
        else
            escaped ~= value;
    }
    return escaped ~ "\"";
}

private string assert_(string predicate, string diagnostic)
{
    return "static assert(" ~ predicate ~ ", " ~ quote(diagnostic) ~ ");\n";
}

private string guards(Node node, string location)
{
    string checks;
    foreach (index, ch; node.value)
    {
        if (ch != '.')
            continue;
        const owner = node.value[0 .. index];
        checks ~= nullCheck(owner);
        size_t end = index + 1;
        while (end < node.value.length && node.value[end] != '.')
            ++end;
        const field = node.value[0 .. end];
        checks ~= assert_("__traits(compiles, " ~ field ~ ".offsetof)",
                location ~ " unknown or non-field model member " ~ field);
    }
    return checks;
}

private string nullCheck(string owner)
{
    enum detail = "__flintError(__flintStatus.invalidArgument, \"null model object\");";
    return "static if (is(typeof(" ~ owner ~ ") == class)) if (" ~ owner
        ~ " is null) { __flintOutput.failure = " ~ detail ~ " return; }\n";
}

private string spell(Node node, string filename, string source)
{
    final switch (node.kind)
    {
    case Kind.literal:
        return "__flintOutput.append(__flintDocument!(" ~ quote(
                filename) ~ ").source[" ~ node.offset.to!string ~ " .. " ~ (node.offset + node.value.length)
            .to!string ~ "]);\n";
    case Kind.alternative:
        return "} else {\n";
    case Kind.end:
        return "}\n";
    case Kind.interpolation:
    case Kind.condition:
    case Kind.loop:
        enum suffix = "template field";
        return emitField(node, diagnosis(filename, source, node.offset, suffix));
    case Kind.includeFile:
        assert(0, "includes are already expanded");
    }
}

private string emitField(Node node, string site)
{
    const expression = node.value;
    const before = guards(node, site);
    const after = "if (__flintOutput.failure.code != __flintStatus.ok) return;\n";
    if (node.kind == Kind.condition)
        return before ~ assert_("is(__flintUnqual!(typeof(" ~ expression ~ ")) == bool)",
                site ~ " expected a boolean field") ~ "if (" ~ expression ~ ") {\n";
    if (node.kind == Kind.loop)
        return before ~ assert_("__flintArray!(typeof(" ~ expression ~ "))", site ~ " expected a model array")
            ~ "foreach (ref const " ~ node.binding ~ "; " ~ expression
            ~ ") {\nif (!__flintOutput.iteration()) return;\n";
    return before ~ interpolate(node, site) ~ after;
}

private string interpolate(Node node, string site)
{
    const value = node.value;
    const mode = "cast(__flintEscape)" ~ (cast(int) node.escape).to!string;
    const call = "__flintOutput.field(" ~ value ~ ", " ~ mode ~ ", __flintArena)";
    string checks;
    if (node.escape != __flintEscape.text)
        checks ~= assert_("!is(typeof(" ~ value ~ ") : __flintTrusted)", site ~ " expected escaped attribute value");
    const valid = assert_("__traits(compiles, " ~ call ~ ")", site ~ " unsupported interpolation type");
    return checks ~ valid ~ call ~ ";\n";
}

void draw(string fileName, Model)(scope const ref Model model, ref scope Writer __flintOutput,
        ref scope RequestArena __flintArena) nothrow @nogc
{
    enum canonicalName = canonical(fileName);
    static assert(canonicalName.length != 0, "invalid template resource path: " ~ fileName);
    static if (canonicalName.length != 0)
    {
        alias installed = Expansion!(canonicalName, [], canonicalName);
        mixin(installed.expanded.body);
    }
}
