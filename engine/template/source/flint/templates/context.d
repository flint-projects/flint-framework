/// Lexical context for the supported HTML template subset.
module flint.templates.context;

@safe:
package(flint.templates):

enum EscapeKind : ubyte
{
    text,
    attribute,
    url,
    disallowed
}

private enum State : ubyte
{
    text,
    name,
    attributes,
    attributeTail,
    beforeValue,
    quoted,
    unquoted,
    comment,
    declaration,
    raw
}

bool space(char ch) pure nothrow @nogc
{
    return ch == ' ' || (ch >= '\t' && ch <= '\r');
}

bool letter(char ch) pure nothrow @nogc
{
    return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
}

private bool nameChar(char ch) pure nothrow @nogc
{
    return letter(ch) || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == ':' || ch == '.';
}

char lower(char ch) pure nothrow @nogc
{
    return ch >= 'A' && ch <= 'Z' ? cast(char)(ch + 'a' - 'A') : ch;
}

bool starts(scope const(char)[] text, size_t at, scope const(char)[] match, bool fold = false) pure nothrow @nogc
{
    if (at > text.length || match.length > text.length - at)
        return false;
    foreach (i, ch; match)
    {
        if ((fold ? lower(text[at + i]) : text[at + i]) != ch)
            return false;
    }
    return true;
}

private string lowercase(string input)
{
    auto chars = input.dup;
    foreach (ref value; chars)
        value = lower(value);
    return chars.idup;
}

struct Context
{
    private State state;
    private bool closing;
    private string tag;
    private string attribute;
    private char quote;
    private string raw;
    private bool literalValue;
    private bool wholeUrl;

    bool neutral() const pure nothrow @nogc
    {
        return state == State.text;
    }

    EscapeKind interpolate()
    {
        if (state == State.text)
            return EscapeKind.text;
        if (state != State.quoted || forbidden(attribute))
            return EscapeKind.disallowed;
        if (!urlAttribute(attribute))
            return EscapeKind.attribute;
        if (literalValue || wholeUrl)
            return EscapeKind.disallowed;
        wholeUrl = true;
        return EscapeKind.url;
    }

    string step(string text, ref size_t cursor)
    {
        switch (state)
        {
        case State.text:
            return open(text, cursor);
        case State.name:
            return readName(text, cursor);
        case State.attributes:
            return readAttribute(text, cursor);
        case State.attributeTail:
            tail(text[cursor], cursor);
            return null;
        case State.beforeValue:
            value(text[cursor], cursor);
            return null;
        case State.quoted:
            return quoted(text[cursor++]);
        case State.unquoted:
            unquoted(text[cursor++]);
            return null;
        default:
            return markup(text, cursor);
        }
    }

    private string markup(string text, ref size_t cursor)
    {
        switch (state)
        {
        case State.comment:
            return scanComment(text, cursor);
        case State.declaration:
            declaration(text[cursor++]);
            return null;
        case State.raw:
            return rawText(text, cursor);
        default:
            assert(0, "expected markup state");
        }
    }

    private string scanComment(string text, ref size_t cursor)
    {
        if (starts(text, cursor, "--!>") || starts(text, cursor, "<!--"))
            return "ambiguous HTML comment is outside the template subset";
        if (starts(text, cursor, "-->"))
        {
            cursor += 3;
            state = State.text;
        }
        else
            ++cursor;
        return null;
    }

    private string open(string text, ref size_t cursor)
    {
        if (text[cursor++] != '<')
            return null;
        // A resource that ends in `<` would let the including resource complete a tag the tracker never saw.
        if (cursor == text.length)
            return "incomplete HTML markup at end of template resource";
        if (starts(text, cursor, "!--"))
        {
            cursor += 3;
            if (starts(text, cursor, ">") || starts(text, cursor, "->"))
                return "abrupt HTML comment is outside the template subset";
            state = State.comment;
        }
        else if (starts(text, cursor, "![CDATA["))
            return "CDATA markup is outside the HTML template subset";
        else if (text[cursor] == '!' || text[cursor] == '?')
        {
            state = State.declaration;
            quote = '\0';
        }
        else if (letter(text[cursor]) || text[cursor] == '/' || text[cursor] == '{')
        {
            closing = text[cursor] == '/';
            cursor += closing;
            state = State.name;
        }
        return null;
    }

    private string readName(string text, ref size_t cursor)
    {
        const first = cursor;
        if (!letter(text[cursor]))
            return "invalid HTML tag name";
        while (cursor < text.length && nameChar(text[cursor]))
            ++cursor;
        tag = lowercase(text[first .. cursor]);
        if (tag == "svg" || tag == "math")
            return "foreign graphics markup is outside the HTML template subset";
        state = State.attributes;
        return null;
    }

    private string readAttribute(string text, ref size_t cursor)
    {
        const next = text[cursor];
        if (next == '>')
        {
            finishTag();
            ++cursor;
            return null;
        }
        if (space(next) || next == '/')
        {
            ++cursor;
            return null;
        }
        const first = cursor;
        while (cursor < text.length && nameChar(text[cursor]))
            ++cursor;
        if (first == cursor)
            return "invalid HTML attribute name";
        attribute = lowercase(text[first .. cursor]);
        state = State.attributeTail;
        return null;
    }

    private void tail(char next, ref size_t cursor)
    {
        if (space(next))
            ++cursor;
        else if (next == '=')
        {
            ++cursor;
            state = State.beforeValue;
        }
        else
            state = State.attributes;
    }

    private void value(char next, ref size_t cursor)
    {
        if (space(next))
        {
            ++cursor;
            return;
        }
        if (next == '"' || next == '\'')
        {
            quote = next;
            wholeUrl = false;
            literalValue = false;
            state = State.quoted;
            ++cursor;
        }
        else
            state = State.unquoted;
    }

    private string quoted(char next)
    {
        if (next == quote)
        {
            state = State.attributes;
            return null;
        }
        if (wholeUrl)
            return "dynamic URL must occupy the complete quoted attribute value";
        literalValue = true;
        return null;
    }

    private void unquoted(char next)
    {
        if (space(next))
            state = State.attributes;
        else if (next == '>')
            finishTag();
    }

    private void declaration(char next)
    {
        if (next == '>')
            state = State.text;
    }

    private void finishTag()
    {
        if (!closing && rawElement(tag))
        {
            state = State.raw;
            raw = tag;
        }
        else
            state = State.text;
    }

    private string rawText(string text, ref size_t cursor)
    {
        if (raw == "script" && starts(text, cursor, "<!--"))
            return "HTML script comment escapes are outside the static template subset";
        if (raw == "plaintext" || !starts(text, cursor, "</") || !starts(text, cursor + 2, raw, true))
        {
            ++cursor;
            return null;
        }
        size_t end = cursor + 2 + raw.length;
        while (end < text.length && space(text[end]))
            ++end;
        if (end < text.length && text[end] == '>')
        {
            cursor = end + 1;
            state = State.text;
        }
        else
            ++cursor;
        return null;
    }
}

private bool rawElement(string tag) pure nothrow @nogc
{
    switch (tag)
    {
    case "script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes",
            "plaintext", "noscript":
            return true;
    default:
        return false;
    }
}

private bool forbidden(string name) pure nothrow @nogc
{
    if (starts(name, 0, "on"))
        return true;
    switch (name)
    {
    case "style", "srcdoc", "srcset", "imagesrcset", "content", "http-equiv", "xmlns", "ping":
        return true;
    default:
        return false;
    }
}

private bool urlAttribute(string name) pure nothrow @nogc
{
    switch (name)
    {
    case "href", "src", "action", "formaction", "cite", "poster", "background", "data",
            "xlink:href", "longdesc", "manifest", "codebase", "usemap", "profile", "itemid":
            return true;
    default:
        return false;
    }
}
