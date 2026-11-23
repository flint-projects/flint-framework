/*
 * Ported from Hibernate Validator 9.1.6.Final, https://github.com/hibernate/hibernate-validator,
 * tag 9.1.6.Final: engine/src/main/java/org/hibernate/validator/messageinterpolation/
 * {AbstractMessageInterpolator,ResourceBundleMessageInterpolator,ParameterMessageInterpolator}.java
 * and internal/engine/messageinterpolation/{InterpolationTerm,ParameterTermResolver,
 * util/InterpolationHelper,parser/{TokenCollector,TokenIterator,Token,MessageState,
 * InterpolationTermState,ELState,EscapedState}}.java
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright Red Hat Inc. and Hibernate Authors
 *
 * Modified by the Flint authors: the bundle is Hibernate's English default bundle;
 * `${...}` terms run on the expression subset of internal/el.d.
 */

/// Message interpolation: bundle keys, `{attribute}` parameters and `${expression}` terms.
module flint.hibernate.validator.messageinterpolation;

import flint.engine.aot.any : Any;
import flint.hibernate.validator.internal.el : ElException, ElValue, evaluate;
import flint.hibernate.validator.internal.engine : ConstraintDescriptorImpl;
import flint.hibernate.validator.internal.messages : defaultMessage;
import flint.jakarta.validation : MessageInterpolator;

@safe:

/**
 * Resource bundle backed message interpolator: the message's `{key}` terms are
 * looked up in the bundles, then `{attribute}` terms are replaced with the
 * constraint's elements and `${...}` terms are evaluated, then escapes are
 * removed.
 */
class ResourceBundleMessageInterpolator : MessageInterpolator
{
    /// Whether `${...}` terms are evaluated.
    protected bool evaluateExpressions = true;
    private string[string] userBundle;

    /// The interpolator over Hibernate's default bundle.
    this() pure nothrow @nogc
    {
    }

    /// The interpolator over `userBundle` (an application's `ValidationMessages`) before the default bundle.
    this(string[string] userBundle) pure nothrow @nogc
    {
        this.userBundle = userBundle;
    }

    /// Interpolates the message template based on the constraint validation context. A template the tokenizer
    /// rejects (an unbalanced or nested brace) is returned unchanged, as Hibernate logs and returns it.
    string interpolate(string messageTemplate, Context context)
    {
        if (messageTemplate is null)
            return null;
        if (!contains(messageTemplate, '{'))
            return unescapeMessageParameter(messageTemplate);
        try
        {
            auto resolved = resolveMessage(messageTemplate);
            if (contains(resolved, '{'))
            {
                resolved = interpolateTerms(resolved, false, (string term) => parameter(term, context));
                resolved = interpolateTerms(resolved, true, (string term) => evaluateExpressions
                        ? expression(term, context) : term);
            }
            return unescapeMessageParameter(resolved);
        }
        catch (MessageDescriptorFormatException)
            return messageTemplate;
    }

    // AbstractMessageInterpolator.resolveMessage: the user bundle (recursively), then the default bundle once,
    // until the user bundle replaces nothing more.
    private string resolveMessage(string message)
    {
        string resolved = message;
        bool evaluatedDefaultBundleOnce;
        for (int round; round < maxBundleDepth; ++round)
        {
            const user = interpolateBundleMessage(resolved, true, 0);
            if (evaluatedDefaultBundleOnce && user == resolved)
                break;
            resolved = interpolateBundleMessage(user, false, 0);
            evaluatedDefaultBundleOnce = true;
        }
        return resolved;
    }

    // interpolateBundleMessage and resolveParameter: each `{key}` the bundle has becomes its value, itself
    // interpolated with the user bundle when `user` (the recursive case).
    private string interpolateBundleMessage(string message, bool user, int depth)
    {
        return interpolateTerms(message, false, (string term) {
            const key = term[1 .. $ - 1];
            if (!user)
            {
                const value = defaultMessage(key);
                return value is null ? term : value;
            }
            auto found = key in userBundle;
            if (found is null || depth >= maxBundleDepth)
                return found is null ? term : *found;
            return interpolateBundleMessage(*found, true, depth + 1);
        });
    }

    // A bound on bundle recursion, where Java would overflow its stack on a key that refers to itself.
    private enum maxBundleDepth = 32;

    // ParameterTermResolver: an element of the constraint, escaped; the term itself when there is none.
    private string parameter(string term, Context context)
    {
        auto descriptor = cast(ConstraintDescriptorImpl) context.getConstraintDescriptor();
        if (descriptor is null)
            return term;
        import flint.hibernate.validator.internal.constraintvalidators : attributeText;

        const name = term[1 .. $ - 1];
        const constraint = descriptor.builtin();
        const value = name == "message" ? descriptor.getMessageTemplate() : attributeText(constraint, name);
        return value is null ? term : escapeMessageParameter(value);
    }

    // ElTermResolver: the expression's value over the constraint's elements and `validatedValue`.
    private string expression(string term, Context context)
    {
        auto descriptor = cast(ConstraintDescriptorImpl) context.getConstraintDescriptor();
        ElValue lookup(string name)
        {
            if (name == "validatedValue")
                return validated(context.getValidatedValue());
            if (descriptor is null)
                return ElValue.init;
            foreach (a; descriptor.builtin().attributes)
                if (a.name == name)
                    return a.value;
            return ElValue.init;
        }

        try
            return evaluate(term[2 .. $ - 1], &lookup);
        catch (ElException)
            return term;
    }

    private static ElValue validated(Any value)
    {
        import flint.engine.aot.objects : objectToString;
        import flint.serde.java_number : javaDoubleString;

        if (value.isNull())
            return ElValue.init;
        if (value.holds!string())
            return ElValue.of(value.get!string());
        if (value.holds!bool())
            return ElValue.of(value.get!bool());
        if (value.holds!long())
            return ElValue.of(value.get!long());
        if (value.holds!double())
            return ElValue.ofDouble(value.get!double());
        if (auto o = value.asObject())
            return ElValue.of(objectToString(o));
        return ElValue.of(value.toString());
    }
}

/// Resource bundle message interpolator that does not support expressions: `${...}` terms stay as written.
class ParameterMessageInterpolator : ResourceBundleMessageInterpolator
{
    ///
    this() pure nothrow @nogc
    {
        evaluateExpressions = false;
    }
}

private bool contains(string s, char c) pure nothrow @nogc
{
    foreach (ch; s)
        if (ch == c)
            return true;
    return false;
}

/// InterpolationHelper.escapeMessageParameter: `\`, `{`, `}` and `$` gain a backslash.
string escapeMessageParameter(string value) pure nothrow
{
    string result;
    foreach (ch; value)
    {
        if (ch == '\\' || ch == '{' || ch == '}' || ch == '$')
            result ~= '\\';
        result ~= ch;
    }
    return result;
}

/// The reverse of `escapeMessageParameter`: `\{`, `\}`, `\$` and `\\` lose their backslash.
string unescapeMessageParameter(string message) pure nothrow
{
    string result;
    for (size_t i; i < message.length; ++i)
    {
        if (message[i] == '\\' && i + 1 < message.length && (message[i + 1] == '\\'
                || message[i + 1] == '{' || message[i + 1] == '}' || message[i + 1] == '$'))
            ++i;
        result ~= message[i];
    }
    return result;
}

/// A message template the tokenizer rejects: an unbalanced `{`/`}` or a nested `{`.
final class MessageDescriptorFormatException : Exception
{
    ///
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc
    {
        super(message, file, line);
    }
}

private struct Token
{
    string value;
    bool isParameter;
}

// TokenIterator and interpolateExpression: each interpolation term is replaced by `resolve(term)`; the message
// comes back as it was when no replacement differs from its term.
private string interpolateTerms(string message, bool el, scope string delegate(string) @safe resolve)
{
    string result;
    bool replaced;
    foreach (token; tokenize(message, el))
    {
        if (!token.isParameter)
        {
            result ~= token.value;
            continue;
        }
        const replacement = resolve(token.value);
        replaced = replaced || replacement != token.value;
        result ~= replacement;
    }
    return replaced ? result : message;
}

// TokenCollector with its parser states. In PARAMETER mode (`el` false) `{...}` is a term and `$` is text; in EL
// mode `${...}` is a term and a lone `{...}` is text. Backslash escapes the next character.
private Token[] tokenize(string message, bool el)
{
    auto collector = TokenCollector(message, el);
    foreach (c; message)
        collector.next(c);
    return collector.finish();
}

private struct TokenCollector
{
    enum State
    {
        message, // MessageState
        term, // InterpolationTermState
        el, // ELState: after a `$` in EL mode
        escaped, // EscapedState
    }

    string message;
    bool el;
    Token[] tokens;
    string current;
    bool open, parameter, expression;
    State state, afterEscape;

    this(string message, bool el) pure nothrow @nogc
    {
        this.message = message;
        this.el = el;
    }

    void next(char c)
    {
        final switch (state)
        {
        case State.message:
            return inMessage(c);
        case State.term:
            return inTerm(c);
        case State.el:
            return inEl(c);
        case State.escaped:
            append(c);
            state = afterEscape;
            return;
        }
    }

    Token[] finish()
    {
        if (state == State.term)
            throw unbalanced(message, '{');
        if (state == State.el)
            append('$');
        terminate();
        return tokens;
    }

    private void inMessage(char c)
    {
        if (c == '}')
            throw unbalanced(message, c);
        if (c == '$' && el)
        {
            state = State.el;
            return;
        }
        if (c == '{')
        {
            terminate();
            parameter = !el;
            state = State.term;
        }
        append(c);
        if (c == '\\')
            escape(State.message);
    }

    private void inTerm(char c)
    {
        if (c == '{')
            throw new MessageDescriptorFormatException(
                    "HV000169: The message descriptor '" ~ message ~ "' has nested parameters.");
        append(c);
        if (c == '}')
        {
            terminate();
            state = State.message;
        }
        else if (c == '\\')
            escape(State.term);
    }

    private void inEl(char c)
    {
        if (c == '}')
            throw unbalanced(message, c);
        if (c == '{')
            terminate();
        append('$');
        append(c);
        if (c == '{')
        {
            parameter = expression = true;
            state = State.term;
        }
        else if (c == '\\')
            escape(State.message);
        else
        {
            terminate();
            state = State.message;
        }
    }

    private void append(char c) pure nothrow
    {
        current ~= c;
        open = true;
    }

    private void terminate() pure nothrow
    {
        if (!open)
            return;
        tokens ~= Token(expression ? unescapeBraces(current) : current, parameter);
        current = null;
        open = parameter = expression = false;
    }

    private void escape(State back) pure nothrow @nogc
    {
        afterEscape = back;
        state = State.escaped;
    }
}

private MessageDescriptorFormatException unbalanced(string message, char c) pure nothrow
{
    return new MessageDescriptorFormatException(
            "HV000168: The message descriptor '" ~ message ~ "' contains an unbalanced meta character '" ~ c ~ "'.");
}

// Token.terminate for an EL term: `\{` and `\}` lose their backslash.
private string unescapeBraces(string value) pure nothrow
{
    string result;
    for (size_t i; i < value.length; ++i)
    {
        if (value[i] == '\\' && i + 1 < value.length && (value[i + 1] == '{' || value[i + 1] == '}'))
            ++i;
        result ~= value[i];
    }
    return result;
}
