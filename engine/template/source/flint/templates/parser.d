/// CTFE template grammar and source diagnostics.
module flint.templates.parser;

import flint.templates.context : Context, EscapeKind, letter, space, starts;
import std.conv : to;
import std.utf : UTFException, validate;

@safe:
package(flint.templates):

enum maxSourceBytes = 1_048_576;
enum maxNodes = 16_384;
enum maxInclude = 16;
private enum maxBlocks = 64;

enum Kind : ubyte
{
    literal,
    interpolation,
    condition,
    alternative,
    loop,
    end,
    includeFile
}

struct Node
{
    Kind kind;
    string value;
    string binding;
    size_t offset;
    EscapeKind escape;
}

struct Parsed
{
    Node[] nodes;
    string error;
}

private struct Block
{
    Kind kind;
    bool alternative;
    string binding;
}

Parsed parse(string filename, string source)
{
    if (source.length > maxSourceBytes)
        return Parsed(null, diagnosis(filename, source, 0, "template source exceeds 1 MiB"));
    if (!validSource(source))
        return Parsed(null, diagnosis(filename, source, 0, "template source must be UTF-8 without NUL"));
    Parser state = Parser(filename, source);
    return state.run();
}

private bool validSource(string source)
{
    foreach (ch; source)
    {
        if (ch == '\0')
            return false;
    }
    try
        validate(source);
    catch (UTFException)
        return false;
    return true;
}

private struct Parser
{
    string filename;
    string source;
    Context context;
    Node[] nodes;
    Block[] blocks;
    size_t cursor;

    Parsed run()
    {
        size_t literal;
        while (cursor < source.length)
        {
            const interpolation = starts(source, cursor, "{{");
            const statement = starts(source, cursor, "{%");
            if (!interpolation && !statement)
            {
                const status = context.step(source, cursor);
                if (status.length != 0)
                    return fail(cursor, status);
                continue;
            }
            if (literal != cursor)
                nodes ~= Node(Kind.literal, source[literal .. cursor], null, literal);
            const begin = cursor;
            const status = parseDirective(interpolation);
            if (status.length != 0)
                return fail(begin, status);
            if (nodes.length >= maxNodes)
                return fail(begin, "template has too many operations");
            literal = cursor;
        }
        if (blocks.length != 0 || !context.neutral())
            return fail(cursor, "unclosed template block or HTML context");
        if (literal != cursor)
            nodes ~= Node(Kind.literal, source[literal .. cursor], null, literal);
        return Parsed(nodes);
    }

    private Parsed fail(size_t at, string message)
    {
        return Parsed(null, diagnosis(filename, source, at, message));
    }

    private string parseDirective(bool interpolation)
    {
        const at = cursor;
        const closing = interpolation ? "}}" : "%}";
        cursor += 2;
        const first = cursor;
        while (cursor < source.length && !starts(source, cursor, closing))
            ++cursor;
        if (cursor == source.length)
            return "unclosed template directive";
        const expression = strip(source[first .. cursor]);
        cursor += 2;
        if (interpolation)
        {
            const which = context.interpolate();
            if (which == EscapeKind.disallowed)
                return "interpolation is forbidden in this HTML context";
            if (!path(expression))
                return "expected a typed field path";
            if (!rooted(expression))
                return "template field path must start with model or a loop binding";
            nodes ~= Node(Kind.interpolation, expression, null, at, which);
            return null;
        }
        if (!context.neutral())
            return "block or include must occur in HTML text";
        const keyword = word(expression);
        return statement(keyword, strip(expression[keyword.length .. $]), at);
    }

    private string statement(string keyword, string rest, size_t at)
    {
        switch (keyword)
        {
        case "if":
            if (!path(rest))
                return "expected a boolean field path";
            if (!rooted(rest))
                return "template field path must start with model or a loop binding";
            return begin(Node(Kind.condition, rest, null, at));
        case "for":
            return loop(rest, at);
        case "else":
            return alternative(rest, at);
        case "end":
            if (rest.length || !blocks.length)
                return "unexpected end block";
            blocks = blocks[0 .. $ - 1];
            nodes ~= Node(Kind.end, null, null, at);
            return null;
        case "include":
            return include_(rest, at);
        default:
            return "unsupported template directive";
        }
    }

    private string alternative(string rest, size_t at)
    {
        if (rest.length || !blocks.length || blocks[$ - 1].kind != Kind.condition || blocks[$ - 1].alternative)
            return "unexpected else block";
        blocks[$ - 1].alternative = true;
        nodes ~= Node(Kind.alternative, null, null, at);
        return null;
    }

    private string begin(Node node)
    {
        if (blocks.length == maxBlocks)
            return "template block nesting exceeds 64";
        blocks ~= Block(node.kind, false, node.binding);
        nodes ~= node;
        return null;
    }

    private string loop(string rest, size_t at)
    {
        const name = word(rest);
        if (!identifier(name) || name == "model" || starts(name, 0, "__flint") || bound(name))
            return "invalid template loop binding";
        const tail = strip(rest[name.length .. $]);
        if (word(tail) != "in")
            return "expected 'in' before loop field path";
        const source = strip(tail[2 .. $]);
        if (!path(source))
            return "expected an array field path";
        if (!rooted(source))
            return "template field path must start with model or a loop binding";
        return begin(Node(Kind.loop, source, name, at));
    }

    /// Whether a name is bound by an enclosing loop block.
    private bool bound(scope const(char)[] name) const pure nothrow @nogc
    {
        foreach (block; blocks)
        {
            if (block.kind == Kind.loop && block.binding == name)
                return true;
        }
        return false;
    }

    /// Paths address the model or an enclosing loop binding, never renderer locals or module symbols.
    private bool rooted(string expression) const pure nothrow @nogc
    {
        const root = word(expression);
        size_t end;
        while (end < root.length && root[end] != '.')
            ++end;
        return root[0 .. end] == "model" || bound(root[0 .. end]);
    }

    private string include_(string rest, size_t at)
    {
        if (rest.length < 3 || rest[0] != '"' || rest[$ - 1] != '"')
            return "include requires a quoted relative resource name";
        const filename = canonical(rest[1 .. $ - 1]);
        if (filename.length == 0)
            return "invalid include resource path";
        nodes ~= Node(Kind.includeFile, filename, null, at);
        return null;
    }
}

private bool identifier(string value) pure nothrow @nogc
{
    if (value.length == 0 || (!letter(value[0]) && value[0] != '_'))
        return false;
    foreach (ch; value[1 .. $])
    {
        if (!letter(ch) && ch != '_' && !(ch >= '0' && ch <= '9'))
            return false;
    }
    return !reserved(value);
}

private bool reserved(string value) pure nothrow @nogc
{
    foreach (token; keywords)
    {
        if (token == value)
            return true;
    }
    return false;
}

private static immutable string[] keywords = [
    "abstract", "alias", "align", "asm", "assert", "auto", "bool", "break", "byte", "case", "cast",
    "catch", "cdouble", "cent", "cfloat", "char", "class", "const", "continue", "creal", "dchar",
    "debug", "default", "delegate", "delete", "deprecated", "do", "double", "else", "enum",
    "export", "extern", "false", "final", "finally", "float", "for", "foreach", "foreach_reverse",
    "function", "goto", "idouble", "if", "ifloat", "immutable", "import", "in", "inout", "int",
    "interface", "invariant", "ireal", "is", "lazy", "long", "mixin", "module", "new", "nothrow",
    "null", "out", "override", "package", "pragma", "private", "protected", "public", "pure",
    "real", "ref", "return", "scope", "shared", "short", "static", "struct", "super", "switch",
    "synchronized", "template", "this", "throw", "true", "try", "typedef", "typeid", "typeof",
    "ubyte", "ucent", "uint", "ulong", "union", "unittest", "ushort", "version", "void", "wchar",
    "while", "with", "__gshared", "__traits", "__vector", "__parameters"
];

private bool path(string expression) pure nothrow @nogc
{
    size_t start;
    foreach (index, ch; expression)
    {
        if (ch == '.')
        {
            if (!identifier(expression[start .. index]))
                return false;
            start = index + 1;
        }
    }
    return identifier(expression[start .. $]);
}

private string strip(string input) pure nothrow @nogc
{
    size_t begin;
    size_t end = input.length;
    while (begin < end && space(input[begin]))
        ++begin;
    while (end > begin && space(input[end - 1]))
        --end;
    return input[begin .. end];
}

private string word(string input) pure nothrow @nogc
{
    size_t end;
    while (end < input.length && !space(input[end]))
        ++end;
    return input[0 .. end];
}

private bool resourceByte(char ch) pure nothrow @nogc
{
    return letter(ch) || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.';
}

string canonical(string input)
{
    if (input.length == 0 || input.length > 256 || input[0] == '/' || input[$ - 1] == '/')
        return null;
    string result;
    size_t start;
    foreach (index; 0 .. input.length + 1)
    {
        if (index != input.length && input[index] != '/')
        {
            if (!resourceByte(input[index]))
                return null;
            continue;
        }
        const part = input[start .. index];
        if (part == "..")
            return null;
        if (part.length && part != ".")
        {
            if (result.length)
                result ~= '/';
            result ~= part;
        }
        start = index + 1;
    }
    return result;
}

string diagnosis(string filename, string source, size_t offset, string message)
{
    uint line = 1;
    uint column = 1;
    foreach (ch; source[0 .. offset])
    {
        if (ch == '\n')
        {
            ++line;
            column = 1;
        }
        else
            ++column;
    }
    return filename ~ ":" ~ line.to!string ~ ":" ~ column.to!string ~ ": " ~ message;
}
