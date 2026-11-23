/*
 * Ported from Hibernate Validator 9.1.6.Final, https://github.com/hibernate/hibernate-validator,
 * tag 9.1.6.Final: engine/src/main/java/org/hibernate/validator/internal/engine/
 * messageinterpolation/ElTermResolver.java (behaviour), with the Jakarta Expression
 * Language operators that message templates use.
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright Red Hat Inc. and Hibernate Authors
 *
 * Modified by the Flint authors: Hibernate evaluates `${...}` terms with a Jakarta EL
 * implementation; Flint evaluates the expression subset message templates use
 * (literals, variables, `? :`, `||`, `&&`, `!`/`not`, `empty`, comparisons and the
 * `+=` concatenation) with EL's coercion rules, over the constraint's attributes and
 * `validatedValue`. Method calls such as `formatter.format(...)` are not evaluated.
 */

/// The expression subset of message templates: `${inclusive == true ? 'or equal to ' : ''}`.
module flint.hibernate.validator.internal.el;

import flint.serde.java_number : javaDoubleString;

@safe:

/// A value of an expression: null, a boolean, a number, or a String.
struct ElValue
{
    /// The kinds of value.
    enum Kind
    {
        ///
        null_,
        ///
        boolean,
        ///
        number,
        ///
        string_,
    }

    /// The kind.
    Kind kind;
    /// The boolean value.
    bool boolean;
    /// The numeric value.
    double number;
    /// Whether the number is integral (prints without a fraction).
    bool integral;
    /// The String value.
    string text;

    /// A String value.
    static ElValue of(string s) pure nothrow @nogc
    {
        ElValue v;
        v.kind = s is null ? Kind.null_ : Kind.string_;
        v.text = s;
        return v;
    }

    /// A boolean value.
    static ElValue of(bool b) pure nothrow @nogc
    {
        ElValue v;
        v.kind = Kind.boolean;
        v.boolean = b;
        return v;
    }

    /// An integral value.
    static ElValue of(long n) pure nothrow @nogc
    {
        ElValue v;
        v.kind = Kind.number;
        v.number = n;
        v.integral = true;
        return v;
    }

    /// A floating-point value.
    static ElValue ofDouble(double n) pure nothrow @nogc
    {
        ElValue v;
        v.kind = Kind.number;
        v.number = n;
        return v;
    }

    /// EL's coercion to String: "" for null, Java's text for numbers and booleans.
    string coerceToString() const pure nothrow
    {
        import std.conv : to;

        final switch (kind)
        {
        case Kind.null_:
            return "";
        case Kind.boolean:
            return boolean ? "true" : "false";
        case Kind.number:
            if (integral)
            {
                try
                    return (cast(long) number).to!string;
                catch (Exception)
                    return javaDoubleString(number);
            }
            return javaDoubleString(number);
        case Kind.string_:
            return text;
        }
    }

    /// EL's coercion to boolean: null and "" are false, "true" (any case) is true.
    bool coerceToBoolean() const pure nothrow @nogc
    {
        final switch (kind)
        {
        case Kind.null_:
            return false;
        case Kind.boolean:
            return boolean;
        case Kind.number:
            return number != 0;
        case Kind.string_:
            return text.length == 4 && (text[0] | 0x20) == 't' && (text[1] | 0x20) == 'r'
                && (text[2] | 0x20) == 'u' && (text[3] | 0x20) == 'e';
        }
    }
}

/// Resolves an identifier to a value: a constraint attribute or `validatedValue`; null when unknown.
alias ElVariables = ElValue delegate(string name) @safe;

/// Thrown when an expression cannot be parsed; Hibernate then leaves the term as it is.
class ElException : Exception
{
    ///
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, file, line);
    }
}

/// Evaluate the expression inside `${...}` and return EL's String coercion of the result.
string evaluate(string expression, ElVariables variables)
{
    auto parser = Parser(expression, variables);
    const value = parser.ternary();
    parser.skip();
    if (parser.position != expression.length)
        throw new ElException("unexpected input in expression: " ~ expression[parser.position .. $]);
    return value.coerceToString();
}

private struct Parser
{
    string source;
    ElVariables variables;
    size_t position;

    this(string source, ElVariables variables) pure nothrow @nogc
    {
        this.source = source;
        this.variables = variables;
    }

    void skip() pure nothrow @nogc
    {
        while (position < source.length && (source[position] == ' ' || source[position] == '\t'))
            ++position;
    }

    bool take(string token) pure nothrow @nogc
    {
        skip();
        if (source.length - position < token.length || source[position .. position + token.length] != token)
            return false;
        // A word operator must not run into an identifier.
        const isWord = token[0] >= 'a' && token[0] <= 'z';
        const end = position + token.length;
        if (isWord && end < source.length && identifierChar(source[end]))
            return false;
        position = end;
        return true;
    }

    static bool identifierChar(char c) pure nothrow @nogc
    {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$';
    }

    ElValue ternary()
    {
        auto condition = or();
        if (!take("?"))
            return condition;
        auto whenTrue = ternary();
        if (!take(":"))
            throw new ElException("expected ':' in conditional expression");
        auto whenFalse = ternary();
        return condition.coerceToBoolean() ? whenTrue : whenFalse;
    }

    ElValue or()
    {
        auto left = and();
        while (take("||") || take("or"))
        {
            auto right = and();
            left = ElValue.of(left.coerceToBoolean() || right.coerceToBoolean());
        }
        return left;
    }

    ElValue and()
    {
        auto left = equality();
        while (take("&&") || take("and"))
        {
            auto right = equality();
            left = ElValue.of(left.coerceToBoolean() && right.coerceToBoolean());
        }
        return left;
    }

    ElValue equality()
    {
        auto left = relational();
        for (;;)
        {
            if (take("==") || take("eq"))
                left = ElValue.of(equal(left, relational()));
            else if (take("!=") || take("ne"))
                left = ElValue.of(!equal(left, relational()));
            else
                return left;
        }
    }

    ElValue relational()
    {
        auto left = concatenation();
        for (;;)
        {
            if (take("<=") || take("le"))
                left = ElValue.of(compare(left, concatenation()) <= 0);
            else if (take(">=") || take("ge"))
                left = ElValue.of(compare(left, concatenation()) >= 0);
            else if (take("<") || take("lt"))
                left = ElValue.of(compare(left, concatenation()) < 0);
            else if (take(">") || take("gt"))
                left = ElValue.of(compare(left, concatenation()) > 0);
            else
                return left;
        }
    }

    ElValue concatenation()
    {
        auto left = unary();
        while (take("+="))
            left = ElValue.of(left.coerceToString() ~ unary().coerceToString());
        return left;
    }

    ElValue unary()
    {
        if (take("!") || take("not"))
            return ElValue.of(!unary().coerceToBoolean());
        if (take("empty"))
        {
            const v = unary();
            return ElValue.of(v.kind == ElValue.Kind.null_ || (v.kind == ElValue.Kind.string_ && v.text.length == 0));
        }
        if (take("-"))
        {
            auto v = unary();
            return v.integral ? ElValue.of(-cast(long) v.number) : ElValue.ofDouble(-v.number);
        }
        return primary();
    }

    ElValue primary()
    {
        skip();
        if (position == source.length)
            throw new ElException("unexpected end of expression");
        const c = source[position];
        if (take("("))
        {
            auto v = ternary();
            if (!take(")"))
                throw new ElException("expected ')'");
            return v;
        }
        if (c == '\'' || c == '"')
            return stringLiteral(c);
        if (c >= '0' && c <= '9')
            return numberLiteral();
        if (identifierChar(c))
            return identifier();
        throw new ElException("unexpected character in expression");
    }

    ElValue stringLiteral(char quote)
    {
        ++position;
        string text;
        while (position < source.length && source[position] != quote)
        {
            if (source[position] == '\\' && position + 1 < source.length)
                ++position;
            text ~= source[position++];
        }
        if (position == source.length)
            throw new ElException("unterminated String literal");
        ++position;
        return ElValue.of(text is null ? "" : text);
    }

    ElValue numberLiteral()
    {
        import std.conv : to;

        const start = position;
        bool fraction;
        while (position < source.length && ((source[position] >= '0' && source[position] <= '9')
                || source[position] == '.'))
        {
            fraction = fraction || source[position] == '.';
            ++position;
        }
        const text = source[start .. position];
        return fraction ? ElValue.ofDouble(text.to!double) : ElValue.of(text.to!long);
    }

    ElValue identifier()
    {
        const start = position;
        while (position < source.length && identifierChar(source[position]))
            ++position;
        const name = source[start .. position];
        switch (name)
        {
        case "true":
            return ElValue.of(true);
        case "false":
            return ElValue.of(false);
        case "null":
            return ElValue.init;
        default:
            return variables(name);
        }
    }

    // EL's == : null only equals null; with a boolean, both as booleans; with a number, both as numbers;
    // otherwise both as Strings.
    static bool equal(ElValue a, ElValue b) pure nothrow
    {
        if (a.kind == ElValue.Kind.null_ || b.kind == ElValue.Kind.null_)
            return a.kind == b.kind;
        if (a.kind == ElValue.Kind.boolean || b.kind == ElValue.Kind.boolean)
            return a.coerceToBoolean() == b.coerceToBoolean();
        if (a.kind == ElValue.Kind.number || b.kind == ElValue.Kind.number)
            return toNumber(a) == toNumber(b);
        return a.text == b.text;
    }

    static int compare(ElValue a, ElValue b) pure nothrow
    {
        if (a.kind == ElValue.Kind.number || b.kind == ElValue.Kind.number)
        {
            const x = toNumber(a), y = toNumber(b);
            return x < y ? -1 : x > y ? 1 : 0;
        }
        const s = a.coerceToString(), t = b.coerceToString();
        return s < t ? -1 : s > t ? 1 : 0;
    }

    static double toNumber(ElValue v) pure nothrow
    {
        import std.conv : to;

        final switch (v.kind)
        {
        case ElValue.Kind.null_:
            return 0;
        case ElValue.Kind.boolean:
            return v.boolean ? 1 : 0;
        case ElValue.Kind.number:
            return v.number;
        case ElValue.Kind.string_:
            try
                return v.text.to!double;
            catch (Exception)
                return double.nan;
        }
    }
}

@("EL: the ternaries, comparisons and concatenation Hibernate's default messages use")
unittest
{
    ElValue lookup(string name)
    {
        switch (name)
        {
        case "inclusive":
            return ElValue.of(true);
        case "days":
            return ElValue.of(2L);
        case "validatedValue":
            return ElValue.of("4111");
        default:
            return ElValue.init;
        }
    }

    assert(evaluate("inclusive == true ? 'or equal to ' : ''", &lookup) == "or equal to ");
    assert(evaluate("days == 0 ? '' : days == 1 ? ' 1 day' : ' ' += days += ' days'", &lookup) == " 2 days");
    assert(evaluate("validatedValue", &lookup) == "4111");
    assert(evaluate("empty missing and not false", &lookup) == "true");
    assert(evaluate("1 < 2 && 'a' != 'b'", &lookup) == "true");
}
