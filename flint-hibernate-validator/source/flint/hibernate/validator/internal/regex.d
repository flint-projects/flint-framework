/++
A clean-room `java.util.regex` engine for run-time Jakarta `@Pattern` expressions, written from the
`java.util.regex.Pattern` specification (its Javadoc) and checked against JDK 21's results (tests/golden/regex.tsv).
OpenJDK's source is not in the licence matrix, so none of it is used.

Syntax: literals and escapes (`\t \n \r \f \a \e \0ooo \xhh \x{h...} \uhhhh \cX \Q...\E`), `.`, character classes
with ranges, nesting, intersection (`&&`) and negation, the predefined classes (`\d \D \s \S \w \W \h \H \v \V`), the
POSIX classes (`\p{Lower}` ...), `\p{L}` and its aliases, `\R`, groups (capturing, named, non-capturing, atomic),
look-ahead and look-behind, back-references (`\n`, `\k<name>`), greedy, reluctant and possessive quantifiers,
anchors and boundaries (`^ $ \A \z \Z \G \b \B`), inline flags and the `Pattern` flags `UNIX_LINES`,
`CASE_INSENSITIVE` (US-ASCII), `COMMENTS`, `MULTILINE` and `DOTALL`.

Not yet (`RegexUnsupportedException`): `UNICODE_CASE` with `CASE_INSENSITIVE`, `UNICODE_CHARACTER_CLASS`, `CANON_EQ`,
`LITERAL`, Unicode properties other than letters, `\N{name}` and `\X`.

Matching is a backtracking program run with an explicit stack, so input length never deepens the call stack (request
threads run on fiber stacks), and with a step budget: Java has none, but a request thread must not hang on a
catastrophic pattern, so an exhausted budget throws `RegexBudgetException` (deviation D-VALIDATION-3).
+/
module flint.hibernate.validator.internal.regex;

import flint.validate.patterns : isUnicodeLetter;

@safe:

/// `java.util.regex.Pattern`'s flag bits.
enum RegexFlag : int
{
    UNIX_LINES = 0x01, ///
    CASE_INSENSITIVE = 0x02, ///
    COMMENTS = 0x04, ///
    MULTILINE = 0x08, ///
    LITERAL = 0x10, ///
    DOTALL = 0x20, ///
    UNICODE_CASE = 0x40, ///
    CANON_EQ = 0x80, ///
    UNICODE_CHARACTER_CLASS = 0x100, ///
}

/// A pattern `java.util.regex` rejects (`PatternSyntaxException`).
final class RegexSyntaxException : Exception
{
    /// The description, the pattern and the index of the problem, as `PatternSyntaxException` keeps them.
    string description;
    /// ditto
    string pattern;
    /// ditto
    ptrdiff_t index;

    ///
    this(string description, string pattern, ptrdiff_t index) pure nothrow
    {
        import flint.engine.aot.text : decimal;

        super(description ~ (index >= 0 ? " near index " ~ decimal(cast(long) index) : "") ~ "\n" ~ pattern);
        this.description = description;
        this.pattern = pattern;
        this.index = index;
    }
}

/// A valid `java.util.regex` pattern that uses a feature this engine does not have yet.
final class RegexUnsupportedException : Exception
{
    ///
    this(string message) pure nothrow @nogc
    {
        super(message);
    }
}

/// A match that ran out of steps (a catastrophic pattern on this input).
final class RegexBudgetException : Exception
{
    ///
    this(string message) pure nothrow @nogc
    {
        super(message);
    }
}

/// A compiled pattern.
struct Regex
{
    private Inst[] code;
    private CharSet[] sets;
    private int groups; // capturing groups, without group 0
    private int registers;

    /// `Pattern.matcher(input).matches()`: whether the whole input matches.
    bool matches(scope const(char)[] input) const
    {
        auto text = decode(input);
        auto vm = Matcher(code, sets, groups, registers, text);
        return vm.run(0, 0, cast(int) text.length) >= 0;
    }
}

/// `Pattern.compile(regex, flags)`.
Regex compileRegex(string regex, int flags = 0)
{
    enum unsupportedFlags = RegexFlag.CANON_EQ | RegexFlag.LITERAL | RegexFlag.UNICODE_CHARACTER_CLASS;
    if (flags & unsupportedFlags)
        throw new RegexUnsupportedException(
                "Flint's regular expressions do not support CANON_EQ, LITERAL or " ~ "UNICODE_CHARACTER_CLASS yet");
    auto parser = Parser(regex, decode(regex), flags);
    const root = parser.parseAll();
    Compiler compiler;
    compiler.nodes = parser.nodes;
    compiler.emit(root);
    compiler.add(Inst(I.match));
    Regex result;
    result.code = compiler.code;
    result.sets = parser.sets;
    result.groups = parser.groupCount;
    result.registers = compiler.registers;
    return result;
}

// ---------------------------------------------------------------------------------------------------------------
// Text

private dchar[] decode(scope const(char)[] text) pure nothrow
{
    import flint.engine.aot.text : decodeUtf8;

    dchar[] result;
    result.reserve(text.length);
    size_t i;
    while (i < text.length)
        result ~= decodeUtf8(text, i);
    return result;
}

private bool isLineTerminator(dchar c, bool unixLines) pure nothrow @nogc
{
    if (unixLines)
        return c == '\n';
    return c == '\n' || c == '\r' || c == 0x85 || c == 0x2028 || c == 0x2029;
}

private bool isAsciiWord(dchar c) pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

private dchar foldAscii(dchar c) pure nothrow @nogc
{
    return c >= 'A' && c <= 'Z' ? cast(dchar)(c + 32) : c;
}

// ---------------------------------------------------------------------------------------------------------------
// Character classes

// The predefined, POSIX and Unicode classes.
private enum Pred : ubyte
{
    digit, // \d, \p{Digit}: [0-9]
    space, // \s: [ \t\n\x0B\f\r]
    word, // \w: [a-zA-Z_0-9]
    horizontal, // \h
    vertical, // \v
    lower, // \p{Lower}: [a-z]
    upper, // \p{Upper}: [A-Z]
    ascii, // \p{ASCII}
    alpha, // \p{Alpha}
    alnum, // \p{Alnum}
    punct, // \p{Punct}
    graph, // \p{Graph}
    print, // \p{Print}
    blank, // \p{Blank}: [ \t]
    cntrl, // \p{Cntrl}
    xdigit, // \p{XDigit}
    posixSpace, // \p{Space}: [ \t\n\x0B\f\r]
    letter, // \p{L}
    any, // every code point
}

private bool test(Pred p, dchar c) pure nothrow @nogc
{
    if (c < 0x80)
        return (asciiMembers[p][c >> 6] & (1UL << (c & 63))) != 0;
    switch (p)
    {
    case Pred.horizontal:
        return wideHorizontal(c);
    case Pred.vertical:
        return c == 0x85 || c == 0x2028 || c == 0x2029;
    case Pred.letter:
        return isUnicodeLetter(c);
    case Pred.any:
        return true;
    default:
        return false; // the POSIX classes and \d \s \w are US-ASCII
    }
}

// \h beyond US-ASCII: U+00A0, U+1680, U+180E, U+2000 to U+200A, U+202F, U+205F and U+3000.
private bool wideHorizontal(dchar c) pure nothrow @nogc
{
    return c == 0xA0 || c == 0x1680 || c == 0x180E || (c >= 0x2000 && c <= 0x200A) || c == 0x202F
        || c == 0x205F || c == 0x3000;
}

// Each predicate's members below U+0080 as inclusive ranges, a pair of characters each, in `Pred` order.
private static immutable string[Pred.max + 1] asciiRanges = [
    "09", // digit
    "  \t\r", // space
    "azAZ09__", // word
    "  \t\t", // horizontal
    "\n\r", // vertical
    "az", // lower
    "AZ", // upper
    "\x00\x7F", // ascii
    "azAZ", // alpha
    "azAZ09", // alnum
    "!/:@[`{~", // punct
    "!~", // graph
    " ~", // print
    "  \t\t", // blank
    "\x00\x1F\x7F\x7F", // cntrl
    "09afAF", // xdigit
    "  \t\r", // posixSpace
    "azAZ", // letter
    "\x00\x7F", // any
];

// The same as two 64-bit masks per predicate, computed at compile time.
private static immutable ulong[2][Pred.max + 1] asciiMembers = () {
    ulong[2][Pred.max + 1] table;
    foreach (p, ranges; asciiRanges)
        for (size_t i = 0; i < ranges.length; i += 2)
            foreach (c; ranges[i] .. ranges[i + 1] + 1)
                table[p][c >> 6] |= 1UL << (c & 63);
    return table;
}();

// One alternative of a class: a range, a predicate (possibly inverted) or a nested class.
private struct SetTerm
{
    enum Kind : ubyte
    {
        range,
        pred,
        nested,
    }

    Kind kind;
    bool inverted;
    Pred pred;
    dchar low, high;
    int nested;
}

// A class: the intersection of unions (`[a-z&&[^aeiou]]` is two unions), negated as a whole.
private struct CharSet
{
    bool negated;
    bool caseInsensitive;
    SetTerm[][] unions;
}

private bool contains(scope const(CharSet)[] sets, int index, dchar c) pure nothrow @nogc
{
    const set = &sets[index];
    bool all = set.unions.length > 0;
    foreach (union_; set.unions)
    {
        bool any;
        foreach (ref term; union_)
        {
            if (termContains(sets, term, c, set.caseInsensitive))
            {
                any = true;
                break;
            }
        }
        if (!any)
        {
            all = false;
            break;
        }
    }
    return all != set.negated;
}

private bool termContains(scope const(CharSet)[] sets, ref const SetTerm term, dchar c, bool ci) pure nothrow @nogc
{
    final switch (term.kind)
    {
    case SetTerm.Kind.range:
        if (c >= term.low && c <= term.high)
            return true;
        if (!ci)
            return false;
        const lower = foldAscii(c);
        const upper = c >= 'a' && c <= 'z' ? cast(dchar)(c - 32) : c;
        return (lower >= term.low && lower <= term.high) || (upper >= term.low && upper <= term.high);
    case SetTerm.Kind.pred:
        return test(term.pred, c) != term.inverted;
    case SetTerm.Kind.nested:
        return contains(sets, term.nested, c);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Syntax tree

private enum Op : ubyte
{
    empty,
    char_, // c, caseInsensitive
    any, // `.`: dotAll, unixLines
    set, // index
    seq, // children
    alt, // children
    group, // index (-1 for non-capturing), child
    repeat, // min, max (-1 unbounded), lazy, possessive, child
    assert_, // anchor
    backref, // index, caseInsensitive
    look, // behind, negative, child
    atomic, // child
}

private enum Anchor : ubyte
{
    lineStart, // ^ in MULTILINE
    inputStart, // \A, ^, \G (matches starts at 0)
    lineEnd, // $ in MULTILINE
    inputEndOrTerminator, // $, \Z
    inputEnd, // \z
    wordBoundary,
    notWordBoundary,
    linebreak, // \R is compiled as an alternative, not an anchor; unused here
}

private struct Node
{
    Op op;
    bool caseInsensitive; // char_, backref
    bool dotAll, unixLines; // any, anchors
    bool lazy_, possessive; // repeat
    bool behind, negative; // look
    Anchor anchor;
    dchar c;
    int index = -1; // set, group, backref
    int min, max;
    int[] children;
}

// ---------------------------------------------------------------------------------------------------------------
// Parser

private struct Parser
{
    string source;
    const(dchar)[] p;
    size_t at;
    int flags;
    Node[] nodes;
    CharSet[] sets;
    int groupCount;
    int[string] names;

    this(string source, const(dchar)[] pattern, int flags) pure nothrow
    {
        this.source = source;
        this.p = pattern;
        this.flags = flags;
    }

    int parseAll()
    {
        const root = alternation();
        if (at < p.length)
            error(p[at] == ')' ? "Unmatched closing ')'" : "Unexpected internal error", at);
        return root;
    }

    private noreturn error(string description, size_t index)
    {
        throw new RegexSyntaxException(description, source, cast(ptrdiff_t) index);
    }

    private int add(Node n) pure nothrow
    {
        nodes ~= n;
        return cast(int) nodes.length - 1;
    }

    private bool has(int flag) const pure nothrow @nogc
    {
        return (flags & flag) != 0;
    }

    // COMMENTS: whitespace and `#` comments between tokens are ignored.
    private void skipComments() pure nothrow @nogc
    {
        if (!has(RegexFlag.COMMENTS))
            return;
        while (at < p.length)
        {
            const c = p[at];
            if (c == ' ' || (c >= '\t' && c <= '\r'))
                ++at;
            else if (c == '#')
            {
                while (at < p.length && !isLineTerminator(p[at], has(RegexFlag.UNIX_LINES)))
                    ++at;
            }
            else
                break;
        }
    }

    private dchar peek() pure nothrow @nogc
    {
        skipComments();
        return at < p.length ? p[at] : dchar.max;
    }

    private int alternation()
    {
        int[] branches = [sequence()];
        while (peek() == '|')
        {
            ++at;
            branches ~= sequence();
        }
        return branches.length == 1 ? branches[0] : add(Node(Op.alt, children: branches));
    }

    private int sequence()
    {
        int[] items;
        for (;;)
        {
            const c = peek();
            if (c == dchar.max || c == '|' || c == ')')
                break;
            if (c == '*' || c == '+' || c == '?')
                error("Dangling meta character '" ~ cast(char) c ~ "'", at);
            const atomStart = at;
            int item = atom();
            if (item == -2) // an inline flag group: no node
                continue;
            items ~= quantified(item, atomStart);
        }
        if (items.length == 1)
            return items[0];
        return add(Node(items.length ? Op.seq : Op.empty, children: items));
    }

    // A quantifier right after an atom: `?`, `*`, `+` or `{n,m}`, then `?` (reluctant) or `+` (possessive).
    private int quantified(int item, size_t atomStart)
    {
        const c = peek();
        int min, max;
        if (c == '?')
            max = 1;
        else if (c == '*')
            max = -1;
        else if (c == '+')
        {
            min = 1;
            max = -1;
        }
        else if (c == '{')
            interval(min, max);
        else
            return item;
        if (c != '{')
            ++at;
        Node r = Node(Op.repeat, min: min, max: max, children: [item]);
        if (at < p.length && p[at] == '?')
        {
            r.lazy_ = true;
            ++at;
        }
        else if (at < p.length && p[at] == '+')
        {
            r.possessive = true;
            ++at;
        }
        return add(r);
    }

    private void interval(out int min, out int max)
    {
        const start = at++;
        min = count(start);
        max = min;
        if (at < p.length && p[at] == ',')
        {
            ++at;
            max = at < p.length && p[at] == '}' ? -1 : count(start);
        }
        if (at >= p.length || p[at] != '}')
            error("Unclosed counted closure", at);
        ++at;
        if (max >= 0 && max < min)
            error("Illegal repetition range", start);
    }

    private int count(size_t start)
    {
        if (at >= p.length || p[at] < '0' || p[at] > '9')
            error("Illegal repetition", start);
        long n;
        while (at < p.length && p[at] >= '0' && p[at] <= '9')
        {
            n = n * 10 + (p[at] - '0');
            if (n > int.max)
                error("Illegal repetition range", start);
            ++at;
        }
        return cast(int) n;
    }

    private int atom()
    {
        const c = p[at];
        switch (c)
        {
        case '(':
            return group();
        case '[':
            ++at;
            return add(Node(Op.set, index: characterClass()));
        case '.':
            ++at;
            return add(Node(Op.any, dotAll: has(RegexFlag.DOTALL), unixLines: has(RegexFlag.UNIX_LINES)));
        case '^':
            ++at;
            return anchor(has(RegexFlag.MULTILINE) ? Anchor.lineStart : Anchor.inputStart);
        case '$':
            ++at;
            return anchor(has(RegexFlag.MULTILINE) ? Anchor.lineEnd : Anchor.inputEndOrTerminator);
        case '\\':
            return escapeAtom();
        default:
            ++at;
            return literal(c);
        }
    }

    private int anchor(Anchor a) pure nothrow
    {
        return add(Node(Op.assert_, anchor: a, unixLines: has(RegexFlag.UNIX_LINES)));
    }

    private int literal(dchar c)
    {
        const ci = has(RegexFlag.CASE_INSENSITIVE);
        if (ci && has(RegexFlag.UNICODE_CASE))
            throw new RegexUnsupportedException(
                    "Flint's regular expressions do not support UNICODE_CASE case-insensitive matching yet");
        return add(Node(Op.char_, caseInsensitive: ci, c: c));
    }

    private int group()
    {
        ++at;
        const saved = flags;
        int result;
        if (at < p.length && p[at] == '?')
        {
            ++at;
            if (at >= p.length)
                error("Unknown inline modifier", at);
            const kind = p[at];
            if (kind == ':')
            {
                ++at;
                result = add(Node(Op.group, index: -1, children: [alternation()]));
            }
            else if (kind == '=' || kind == '!')
            {
                ++at;
                result = add(Node(Op.look, negative: kind == '!', children: [alternation()]));
            }
            else if (kind == '>')
            {
                ++at;
                result = add(Node(Op.atomic, children: [alternation()]));
            }
            else if (kind == '<' && at + 1 < p.length && (p[at + 1] == '=' || p[at + 1] == '!'))
            {
                const negative = p[at + 1] == '!';
                at += 2;
                result = add(Node(Op.look, behind: true, negative: negative, children: [
                    alternation()
                ]));
            }
            else if (kind == '<')
            {
                ++at;
                const name = groupName();
                if (name in names)
                    error("Named capturing group <" ~ name ~ "> is already defined", at);
                const index = ++groupCount;
                names[name] = index;
                result = add(Node(Op.group, index: index, children: [alternation()]));
            }
            else
            {
                if (inlineFlags())
                    return -2; // (?i): applies to the rest of the enclosing group
                result = add(Node(Op.group, index: -1, children: [alternation()]));
            }
        }
        else
        {
            const index = ++groupCount;
            result = add(Node(Op.group, index: index, children: [alternation()]));
        }
        if (peek() != ')')
            error("Unclosed group", p.length);
        ++at;
        flags = saved;
        return result;
    }

    // `(?idmsuxU-idmsuxU)` or `(?idmsuxU-idmsuxU:`; true for the former, which changes the enclosing group's flags.
    private bool inlineFlags()
    {
        bool on = true;
        while (at < p.length)
        {
            const c = p[at++];
            int bit;
            switch (c)
            {
            case 'i':
                bit = RegexFlag.CASE_INSENSITIVE;
                break;
            case 'd':
                bit = RegexFlag.UNIX_LINES;
                break;
            case 'm':
                bit = RegexFlag.MULTILINE;
                break;
            case 's':
                bit = RegexFlag.DOTALL;
                break;
            case 'u':
                bit = RegexFlag.UNICODE_CASE;
                break;
            case 'x':
                bit = RegexFlag.COMMENTS;
                break;
            case 'U':
                throw new RegexUnsupportedException(
                        "Flint's regular expressions do not support UNICODE_CHARACTER_CLASS yet");
            case '-':
                if (!on)
                    error("Unknown inline modifier", at - 1);
                on = false;
                continue;
            case ')':
                return true;
            case ':':
                return false;
            default:
                error("Unknown inline modifier", at - 1);
            }
            flags = on ? flags | bit : flags & ~bit;
        }
        error("Unknown inline modifier", at);
    }

    private string groupName()
    {
        const start = at;
        string name;
        while (at < p.length && p[at] != '>')
        {
            const c = p[at];
            const letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
            if (!letter && !(at > start && c >= '0' && c <= '9'))
                error("named capturing group is missing trailing '>'", at);
            name ~= cast(char) c;
            ++at;
        }
        if (at >= p.length || name.length == 0)
            error("named capturing group is missing trailing '>'", at);
        ++at;
        return name;
    }

    // `\` outside a class: an anchor, a class, a back-reference, `\Q...\E`, `\R` or a literal.
    private int escapeAtom()
    {
        const start = at++;
        if (at >= p.length)
            error("Unexpected internal error", at);
        const special = specialEscape(p[at]);
        if (special >= 0)
            return special;
        SetTerm term;
        if (classEscape(term))
        {
            CharSet set;
            set.unions = [[term]];
            sets ~= set;
            return add(Node(Op.set, index: cast(int) sets.length - 1));
        }
        return literal(escapedChar(start));
    }

    // The escapes that are not characters or classes: anchors, \R, \Q...\E and back-references; -1 for others.
    private int specialEscape(dchar c)
    {
        static immutable string anchorLetters = "AGzZB";
        static immutable Anchor[5] anchors = [
            Anchor.inputStart, Anchor.inputStart, Anchor.inputEnd, Anchor.inputEndOrTerminator,
            Anchor.notWordBoundary
        ];
        foreach (i, letter; anchorLetters)
            if (c == letter)
            {
                ++at;
                return anchor(anchors[i]);
            }
        switch (c)
        {
        case 'b':
            ++at;
            if (at < p.length && p[at] == '{')
                throw new RegexUnsupportedException("Flint's regular expressions do not support \\b{g} yet");
            return anchor(Anchor.wordBoundary);
        case 'R':
            ++at;
            return linebreak();
        case 'X':
            throw new RegexUnsupportedException("Flint's regular expressions do not support \\X yet");
        case 'Q':
            return quoted();
        case 'k':
            ++at;
            return namedBackref();
        case '1': .. case '9':
            return backref();
        default:
            return -1;
        }
    }

    // \R: `\u000D\u000A|[\u000A\u000B\u000C\u000D\u0085\u2028\u2029]`, the pair taken atomically.
    private int linebreak() pure nothrow
    {
        const cr = add(Node(Op.char_, c: '\r'));
        const lf = add(Node(Op.char_, c: '\n'));
        const pair = add(Node(Op.seq, children: [cr, lf]));
        CharSet set;
        set.unions = [[SetTerm(SetTerm.Kind.pred, pred: Pred.vertical)]];
        sets ~= set;
        const single = add(Node(Op.set, index: cast(int) sets.length - 1));
        return add(Node(Op.atomic, children: [add(Node(Op.alt, children: [pair, single]))]));
    }

    private int quoted()
    {
        ++at;
        int[] chars;
        while (at < p.length && !(p[at] == '\\' && at + 1 < p.length && p[at + 1] == 'E'))
            chars ~= literal(p[at++]);
        if (at < p.length)
            at += 2;
        if (chars.length == 0)
            return add(Node(Op.empty));
        // A quantifier after \E applies to the last quoted character.
        if (chars.length == 1)
            return chars[0];
        const last = chars[$ - 1];
        const head = add(Node(Op.seq, children: chars[0 .. $ - 1]));
        const tail = quantified(last, at);
        return add(Node(Op.seq, children: [head, tail]));
    }

    private int namedBackref()
    {
        if (at >= p.length || p[at] != '<')
            error("\\k is not followed by '<' for named capturing group", at);
        ++at;
        const name = groupName();
        auto found = name in names;
        if (found is null)
            error("named capturing group <" ~ name ~ "> does not exist", at);
        return add(Node(Op.backref, index: *found, caseInsensitive: has(RegexFlag.CASE_INSENSITIVE)));
    }

    // `\n`: the first digit always refers to a group; more digits are taken while the number names a group opened so far.
    private int backref()
    {
        int index = p[at++] - '0';
        while (at < p.length && p[at] >= '0' && p[at] <= '9')
        {
            const next = index * 10 + (p[at] - '0');
            if (next > groupCount)
                break;
            index = next;
            ++at;
        }
        return add(Node(Op.backref, index: index, caseInsensitive: has(RegexFlag.CASE_INSENSITIVE)));
    }

    // A class escape at `at` (just past the backslash): \d \D \s \S \w \W \h \H \v \V \p{..} \P{..}.
    private bool classEscape(ref SetTerm term)
    {
        const c = p[at];
        Pred pred;
        switch (c)
        {
        case 'd', 'D':
            pred = Pred.digit;
            break;
        case 's', 'S':
            pred = Pred.space;
            break;
        case 'w', 'W':
            pred = Pred.word;
            break;
        case 'h', 'H':
            pred = Pred.horizontal;
            break;
        case 'v', 'V':
            pred = Pred.vertical;
            break;
        case 'p', 'P':
            ++at;
            term = SetTerm(SetTerm.Kind.pred, inverted: c == 'P', pred: property());
            return true;
        default:
            return false;
        }
        ++at;
        term = SetTerm(SetTerm.Kind.pred, inverted: c >= 'A' && c <= 'Z', pred: pred);
        return true;
    }

    // `\p{Name}` or `\pL`, at the character after `p`.
    private Pred property()
    {
        const start = at;
        string name;
        if (at < p.length && p[at] == '{')
        {
            ++at;
            while (at < p.length && p[at] != '}')
                name ~= cast(char) p[at++];
            if (at >= p.length)
                error("Unclosed character family", at);
            ++at;
        }
        else if (at < p.length)
            name ~= cast(char) p[at++];
        else
            error("Illegal/unsupported escape sequence", start);
        return propertyNamed(name, start);
    }

    private Pred propertyNamed(string name, size_t start)
    {
        static immutable string[16] posixNames = [
            "Lower", "Upper", "ASCII", "Alpha", "Digit", "Alnum", "Punct", "Graph", "Print",
            "Blank", "Cntrl", "XDigit", "Space", "L", "IsL", "IsLetter"
        ];
        static immutable Pred[16] posixPreds = [
            Pred.lower, Pred.upper, Pred.ascii, Pred.alpha, Pred.digit, Pred.alnum, Pred.punct,
            Pred.graph, Pred.print, Pred.blank, Pred.cntrl, Pred.xdigit, Pred.posixSpace,
            Pred.letter, Pred.letter, Pred.letter
        ];
        foreach (i, known; posixNames)
            if (name == known)
            {
                if (has(RegexFlag.CASE_INSENSITIVE) && (posixPreds[i] == Pred.lower || posixPreds[i] == Pred.upper))
                    return Pred.alpha; // Java folds \p{Lower} and \p{Upper} under CASE_INSENSITIVE
                return posixPreds[i];
            }
        if (javaKnows(name))
            throw new RegexUnsupportedException("Flint's regular expressions do not support \\p{" ~ name ~ "} yet");
        error("Unknown character property name {" ~ name ~ "}", start);
    }

    // Property names java.util.regex accepts that this engine does not have tables for yet.
    private static bool javaKnows(string name) pure nothrow @nogc
    {
        static immutable string[] categories = [
            "Lu", "Ll", "Lt", "Lm", "Lo", "LC", "LD", "M", "Mn", "Mc", "Me", "N", "Nd", "Nl", "No",
            "P", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po", "S", "Sm", "Sc", "Sk", "So", "Z", "Zs",
            "Zl", "Zp", "C", "Cc", "Cf", "Co", "Cs", "Cn"
        ];
        foreach (known; categories)
            if (name == known || (name.length == known.length + 2 && name[0 .. 2] == "Is" && name[2 .. $] == known))
                return true;
        static immutable string[] prefixes = [
            "Is", "In", "java", "script=", "sc=", "block=", "blk=", "general_category=", "gc="
        ];
        foreach (prefix; prefixes)
            if (name.length > prefix.length && name[0 .. prefix.length] == prefix)
                return true;
        return false;
    }

    // A literal escape, at the character after the backslash: \t \n \r \f \a \e \0ooo \xhh \x{..} \uhhhh \cX, or an
    // escaped non-alphabetic character.
    private dchar escapedChar(size_t start)
    {
        static immutable string simple = "tnrfae";
        static immutable dchar[6] simpleValues = ['\t', '\n', '\r', '\f', '\a', '\x1B'];
        const c = p[at++];
        foreach (i, letter; simple)
            if (c == letter)
                return simpleValues[i];
        switch (c)
        {
        case '0':
            return octal();
        case 'x':
            return hexEscape();
        case 'u':
            return hexDigits(4);
        case 'c':
            if (at >= p.length)
                error("Illegal control escape sequence", at);
            return p[at++] ^ 64;
        case 'N':
            throw new RegexUnsupportedException("Flint's regular expressions do not support \\N{name} yet");
        default:
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
                error("Illegal/unsupported escape sequence", at - 1);
            return c;
        }
    }

    private dchar octal()
    {
        int value;
        int digits;
        while (digits < 3 && at < p.length && p[at] >= '0' && p[at] <= '7')
        {
            const next = value * 8 + (p[at] - '0');
            if (next > 0xFF)
                break;
            value = next;
            ++at;
            ++digits;
        }
        if (digits == 0)
            error("Illegal octal escape sequence", at);
        return cast(dchar) value;
    }

    private dchar hexEscape()
    {
        if (at < p.length && p[at] == '{')
        {
            ++at;
            uint value;
            size_t digits;
            while (at < p.length && p[at] != '}')
            {
                value = value * 16 + hexValue(p[at++]);
                if (value > 0x10FFFF)
                    error("Hexadecimal codepoint is too big", at);
                ++digits;
            }
            if (at >= p.length || digits == 0)
                error("Unclosed hexadecimal escape sequence", at);
            ++at;
            return cast(dchar) value;
        }
        return hexDigits(2);
    }

    private dchar hexDigits(int n)
    {
        uint value;
        foreach (_; 0 .. n)
        {
            if (at >= p.length)
                error("Illegal hexadecimal escape sequence", at);
            value = value * 16 + hexValue(p[at++]);
        }
        return cast(dchar) value;
    }

    private uint hexValue(dchar c)
    {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        error("Illegal hexadecimal escape sequence", at - 1);
    }

    // A class, after its `[`: unions separated by `&&`, negated as a whole by a leading `^`.
    private int characterClass()
    {
        CharSet set;
        set.caseInsensitive = has(RegexFlag.CASE_INSENSITIVE);
        if (set.caseInsensitive && has(RegexFlag.UNICODE_CASE))
            throw new RegexUnsupportedException(
                    "Flint's regular expressions do not support UNICODE_CASE case-insensitive matching yet");
        if (at < p.length && p[at] == '^')
        {
            set.negated = true;
            ++at;
        }
        SetTerm[] current;
        for (bool first = true; classContinues(first); first = false)
        {
            if (p[at] == '&' && at + 1 < p.length && p[at + 1] == '&')
            {
                at += 2;
                set.unions ~= current;
                current = null;
            }
            else if (p[at] == '[')
            {
                ++at;
                current ~= SetTerm(SetTerm.Kind.nested, nested: characterClass());
            }
            else
                current ~= classItem();
        }
        if (current.length || set.unions.length == 0)
            set.unions ~= current;
        sets ~= set;
        return cast(int) sets.length - 1;
    }

    // Whether the class goes on at `at`; consumes its closing `]` (which is a member when it comes first).
    private bool classContinues(bool first)
    {
        classComments();
        if (at >= p.length)
            error("Unclosed character class", at);
        if (p[at] != ']' || first)
            return true;
        ++at;
        return false;
    }

    private void classComments() pure nothrow @nogc
    {
        if (!has(RegexFlag.COMMENTS))
            return;
        while (at < p.length && (p[at] == ' ' || (p[at] >= '\t' && p[at] <= '\r')))
            ++at;
    }

    // A single character, a range or a class escape inside a class.
    private SetTerm classItem()
    {
        const start = at;
        if (p[at] == '\\')
        {
            ++at;
            if (at >= p.length)
                error("Unclosed character class", at);
            SetTerm term;
            if (classEscape(term))
                return term;
            if (p[at] == 'Q')
                throw new RegexUnsupportedException("Flint's regular expressions do not support \\Q in a class yet");
            const low = escapedChar(start);
            return range(low, start);
        }
        return range(p[at++], start);
    }

    private SetTerm range(dchar low, size_t start)
    {
        classComments();
        if (at + 1 < p.length && p[at] == '-' && p[at + 1] != ']' && p[at + 1] != '[')
        {
            ++at;
            classComments();
            dchar high;
            if (p[at] == '\\')
            {
                const escape = at++;
                SetTerm ignored;
                if (classEscape(ignored))
                    error("Illegal character range", escape);
                high = escapedChar(escape);
            }
            else
                high = p[at++];
            if (high < low)
                error("Illegal character range", at - 1);
            return SetTerm(SetTerm.Kind.range, low: low, high: high);
        }
        return SetTerm(SetTerm.Kind.range, low: low, high: low);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Program

private enum I : ubyte
{
    char_, // c
    charCI, // c (lower case)
    any, // x: 1 dotAll, 2 unixLines
    set, // x: set index
    split, // try x, then y
    jmp, // x
    save, // x: slot
    match, // end of the program or of a sub-program
    assert_, // x: anchor, y: unixLines
    backref, // x: group, y: case-insensitive
    look, // x: body start, y: continuation; c: 1 behind, 2 negative; min/max lengths
    atomic, // x: body start, y: continuation
    mark, // x: register: position at a loop iteration's start
    check, // x: register: fail an iteration that consumed nothing
}

private struct Inst
{
    I op;
    dchar c;
    int x, y;
    int min, max;
}

// The longest program a pattern may unroll to (counted repetitions copy their body).
private enum programLimit = 100_000;

private struct Compiler
{
    Node[] nodes;
    Inst[] code;
    int registers;

    int add(Inst inst)
    {
        if (code.length >= programLimit)
            throw new RegexUnsupportedException("Flint's regular expressions do not support a pattern this large "
                    ~ "yet (its counted repetitions unroll past 100,000 instructions)");
        code ~= inst;
        return cast(int) code.length - 1;
    }

    int here() const pure nothrow @nogc
    {
        return cast(int) code.length;
    }

    void emit(int index)
    {
        auto n = nodes[index];
        switch (n.op)
        {
        case Op.empty:
            return;
        case Op.seq:
            foreach (child; n.children)
                emit(child);
            return;
        case Op.alt:
            return alternatives(n.children);
        case Op.group:
            if (n.index >= 0)
                add(Inst(I.save, x: 2 * n.index));
            emit(n.children[0]);
            if (n.index >= 0)
                add(Inst(I.save, x: 2 * n.index + 1));
            return;
        case Op.repeat:
            return n.possessive ? possessive(n) : repetition(n);
        case Op.look:
            return look(n);
        case Op.atomic:
            return sub(I.atomic, n.children[0], 0, 0, 0);
        default:
            return emitSimple(n);
        }
    }

    // The single-instruction nodes: a character, `.`, a class, an anchor or a back-reference.
    private void emitSimple(ref const Node n)
    {
        switch (n.op)
        {
        case Op.char_:
            add(n.caseInsensitive && n.c < 0x80 ? Inst(I.charCI, foldAscii(n.c)) : Inst(I.char_, n.c));
            return;
        case Op.any:
            add(Inst(I.any, x: (n.dotAll ? 1 : 0) | (n.unixLines ? 2 : 0)));
            return;
        case Op.set:
            add(Inst(I.set, x: n.index));
            return;
        case Op.assert_:
            add(Inst(I.assert_, x: n.anchor, y: n.unixLines ? 1 : 0));
            return;
        default:
            add(Inst(I.backref, x: n.index, y: n.caseInsensitive ? 1 : 0));
            return;
        }
    }

    private void alternatives(const int[] children)
    {
        int[] exits;
        foreach (i, child; children)
        {
            if (i + 1 < children.length)
            {
                const split = add(Inst(I.split));
                code[split].x = here();
                emit(child);
                exits ~= add(Inst(I.jmp));
                code[split].y = here();
            }
            else
                emit(child);
        }
        foreach (exit; exits)
            code[exit].x = here();
    }

    // x{min,max}: `min` copies, then optional copies (max - min) or a loop; a reluctant quantifier tries the
    // shorter way first.
    private void repetition(ref const Node n)
    {
        const body_ = n.children[0];
        foreach (_; 0 .. n.min)
            emit(body_);
        if (n.max < 0)
            return loop(body_, n.lazy_);
        int[] exits;
        foreach (_; n.min .. n.max)
        {
            const split = add(Inst(I.split));
            const enter = here();
            emit(body_);
            if (n.lazy_)
            {
                code[split].y = enter;
                exits ~= split; // x: skip
            }
            else
            {
                code[split].x = enter;
                exits ~= -split - 1; // y: skip
            }
        }
        foreach (e; exits)
        {
            if (e >= 0)
                code[e].x = here();
            else
                code[-e - 1].y = here();
        }
    }

    private void loop(int body_, bool lazy_)
    {
        const register = registers++;
        const top = add(Inst(I.split));
        const enter = here();
        add(Inst(I.mark, x: register));
        emit(body_);
        add(Inst(I.check, x: register));
        add(Inst(I.jmp, x: top));
        if (lazy_)
        {
            code[top].x = here();
            code[top].y = enter;
        }
        else
        {
            code[top].x = enter;
            code[top].y = here();
        }
    }

    // x*+ is (?>x*).
    private void possessive(ref const Node n)
    {
        nodes ~= Node(Op.repeat, min: n.min, max: n.max, children: n.children.dup);
        sub(I.atomic, cast(int) nodes.length - 1, 0, 0, 0);
    }

    private void look(ref const Node n)
    {
        int min, max;
        if (n.behind)
            lengths(n.children[0], min, max);
        sub(I.look, n.children[0], (n.behind ? 1 : 0) | (n.negative ? 2 : 0), min, max);
    }

    private void sub(I op, int body_, dchar kind, int min, int max)
    {
        const head = add(Inst(op, kind, min: min, max: max));
        code[head].x = here();
        emit(body_);
        add(Inst(I.match));
        code[head].y = here();
    }

    // The fewest and most code points a node matches; max -1 when unbounded.
    private void lengths(int index, out int min, out int max)
    {
        auto n = nodes[index];
        switch (n.op)
        {
        case Op.char_:
        case Op.any:
        case Op.set:
            min = max = 1;
            return;
        case Op.backref:
            max = -1;
            return;
        case Op.group:
        case Op.atomic:
            return lengths(n.children[0], min, max);
        case Op.seq:
            return sequenceLengths(n.children, min, max);
        case Op.alt:
            return alternativeLengths(n.children, min, max);
        case Op.repeat:
            int a, b;
            lengths(n.children[0], a, b);
            min = a * n.min;
            max = n.max < 0 || b < 0 ? (b == 0 ? 0 : -1) : b * n.max;
            return;
        default:
            return; // empty, anchors and look-around match no characters
        }
    }

    private void sequenceLengths(const int[] children, out int min, out int max)
    {
        foreach (child; children)
        {
            int a, b;
            lengths(child, a, b);
            min += a;
            max = max < 0 || b < 0 ? -1 : max + b;
        }
    }

    private void alternativeLengths(const int[] children, out int min, out int max)
    {
        foreach (i, child; children)
        {
            int a, b;
            lengths(child, a, b);
            min = i == 0 || a < min ? a : min;
            max = (i > 0 && max < 0) || b < 0 ? -1 : (b > max ? b : max);
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Matching

// Steps one match may take before it gives up (about a tenth of a second).
private enum stepBudget = 20_000_000;

private struct Frame
{
    int pc; // resume at pc, or -1 for an undo entry
    int pos;
    int slot; // undo: captures (>= 0) or registers (-slot - 1)
    int old;
}

private struct Matcher
{
    const(Inst)[] code;
    const(CharSet)[] sets;
    const(dchar)[] text;
    int[] captures;
    int[] registers;
    long steps;

    this(const(Inst)[] code, const(CharSet)[] sets, int groups, int registerCount, const(dchar)[] text) pure nothrow
    {
        this.code = code;
        this.sets = sets;
        this.text = text;
        captures = new int[2 * (groups + 1)];
        captures[] = -1;
        registers = new int[registerCount];
        registers[] = -1;
    }

    // Runs from `pc` at `pos`; returns the end position of the first match the program reaches, -1 when none. With
    // `end` >= 0 only a match ending there counts. Captures a match sets stay set; the caller undoes them if it must.
    int run(int pc, int pos, int end)
    {
        Frame[] stack;
        for (;;)
        {
            if (++steps > stepBudget)
                throw new RegexBudgetException("A regular expression ran out of steps on this input: Flint stops "
                        ~ "a match after 20,000,000 steps, where Java's backtracking would keep going");
            const inst = code[pc];
            if (inst.op == I.match)
            {
                if (end < 0 || pos == end)
                    return pos;
            }
            else if (execute(inst, pc, pos, stack))
                continue;
            if (!backtrack(stack, pc, pos))
                return -1;
        }
    }

    // One instruction other than `match`: moves `pc` (and `pos`); false when it fails.
    private bool execute(ref const Inst inst, ref int pc, ref int pos, ref Frame[] stack)
    {
        switch (inst.op)
        {
        case I.split:
            stack ~= Frame(inst.y, pos);
            pc = inst.x;
            return true;
        case I.jmp:
            pc = inst.x;
            return true;
        case I.save:
        case I.mark:
            record(inst, pos, stack);
            ++pc;
            return true;
        case I.check:
            ++pc;
            return registers[inst.x] != pos;
        case I.assert_:
            ++pc;
            return anchorHolds(cast(Anchor) inst.x, pos, inst.y != 0);
        case I.backref:
            ++pc;
            return backrefAt(inst.x, inst.y != 0, pos);
        case I.look:
            pc = inst.y;
            return lookAround(inst, pos, stack);
        case I.atomic:
            pc = inst.y;
            return atomic(inst, pos, stack);
        default:
            ++pc;
            return consume(inst, pos);
        }
    }

    // char_, charCI, any and set: one code point.
    private bool consume(ref const Inst inst, ref int pos) const pure nothrow @nogc
    {
        if (pos >= text.length)
            return false;
        const c = text[pos++];
        if (inst.op == I.char_)
            return c == inst.c;
        if (inst.op == I.charCI)
            return foldAscii(c) == inst.c;
        if (inst.op == I.any)
            return (inst.x & 1) || !isLineTerminator(c, (inst.x & 2) != 0);
        return contains(sets, inst.x, c);
    }

    // save and mark: set a capture slot or a loop register, with an undo entry.
    private void record(ref const Inst inst, int pos, ref Frame[] stack) pure nothrow
    {
        if (inst.op == I.save)
        {
            stack ~= Frame(-1, 0, inst.x, captures[inst.x]);
            captures[inst.x] = pos;
        }
        else
        {
            stack ~= Frame(-1, 0, -inst.x - 1, registers[inst.x]);
            registers[inst.x] = pos;
        }
    }

    // (?>X): the body's first match, kept without backtracking into it.
    private bool atomic(ref const Inst inst, ref int pos, ref Frame[] stack)
    {
        const before = captures.dup;
        const reached = run(inst.x, pos, -1);
        if (reached < 0)
            return false;
        keepCaptures(before, stack);
        pos = reached;
        return true;
    }

    // Pops undo entries until a resume point; false when none is left.
    private bool backtrack(ref Frame[] stack, ref int pc, ref int pos) pure nothrow
    {
        while (stack.length)
        {
            const top = stack[$ - 1];
            stack = stack[0 .. $ - 1];
            if (top.pc >= 0)
            {
                pc = top.pc;
                pos = top.pos;
                return true;
            }
            if (top.slot >= 0)
                captures[top.slot] = top.old;
            else
                registers[-top.slot - 1] = top.old;
        }
        return false;
    }

    // Captures a nested run set are kept, with undo entries so that backtracking past it restores them.
    private void keepCaptures(scope const(int)[] before, ref Frame[] stack) pure nothrow
    {
        foreach (slot, old; before)
            if (captures[slot] != old)
                stack ~= Frame(-1, 0, cast(int) slot, old);
    }

    private bool lookAround(ref const Inst inst, int pos, ref Frame[] stack)
    {
        const behind = (inst.c & 1) != 0;
        const negative = (inst.c & 2) != 0;
        const before = captures.dup;
        bool found;
        if (!behind)
            found = run(inst.x, pos, -1) >= 0;
        else
        {
            const earliest = inst.max < 0 ? 0 : pos - inst.max;
            for (int start = pos - inst.min; start >= earliest && start >= 0 && !found; --start)
                found = run(inst.x, start, pos) >= 0;
        }
        if (found && !negative)
            keepCaptures(before, stack);
        else
            captures[] = before[];
        return found != negative;
    }

    private bool backrefAt(int group, bool caseInsensitive, ref int pos) const pure nothrow @nogc
    {
        if (2 * group + 1 >= captures.length || captures[2 * group] < 0 || captures[2 * group + 1] < 0)
            return false;
        const from = captures[2 * group], to = captures[2 * group + 1];
        const length = to - from;
        if (pos + length > text.length)
            return false;
        foreach (i; 0 .. length)
        {
            const a = text[from + i], b = text[pos + i];
            if (a != b && !(caseInsensitive && foldAscii(a) == foldAscii(b)))
                return false;
        }
        pos += length;
        return true;
    }

    private bool anchorHolds(Anchor anchor, int pos, bool unixLines) const pure nothrow @nogc
    {
        const n = cast(int) text.length;
        final switch (anchor)
        {
        case Anchor.inputStart:
            return pos == 0;
        case Anchor.inputEnd:
            return pos == n;
        case Anchor.inputEndOrTerminator:
            return pos == n || finalTerminatorAt(pos, unixLines);
        case Anchor.lineStart:
            return lineStartAt(pos, unixLines);
        case Anchor.lineEnd:
            return lineEndAt(pos, unixLines);
        case Anchor.wordBoundary:
        case Anchor.notWordBoundary:
            const left = pos > 0 && isAsciiWord(text[pos - 1]);
            const right = pos < n && isAsciiWord(text[pos]);
            return (left != right) == (anchor == Anchor.wordBoundary);
        case Anchor.linebreak:
            return false;
        }
    }

    // MULTILINE `^`: the start, or after a line terminator that is not the input's last character (never between
    // \r and \n).
    private bool lineStartAt(int pos, bool unixLines) const pure nothrow @nogc
    {
        if (pos == 0)
            return true;
        if (pos == text.length || !isLineTerminator(text[pos - 1], unixLines))
            return false;
        return !(text[pos - 1] == '\r' && text[pos] == '\n');
    }

    // MULTILINE `$`: the end, or before a line terminator (never between \r and \n).
    private bool lineEndAt(int pos, bool unixLines) const pure nothrow @nogc
    {
        if (pos == text.length)
            return true;
        if (!isLineTerminator(text[pos], unixLines))
            return false;
        return unixLines || !(text[pos] == '\n' && pos > 0 && text[pos - 1] == '\r');
    }

    // Whether only a final line terminator (\n, \r\n, ...) follows `pos`.
    private bool finalTerminatorAt(int pos, bool unixLines) const pure nothrow @nogc
    {
        const n = cast(int) text.length;
        if (pos == n - 1)
            return isLineTerminator(text[pos], unixLines);
        return !unixLines && pos == n - 2 && text[pos] == '\r' && text[pos + 1] == '\n';
    }
}
