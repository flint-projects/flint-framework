/*
 * Ported from Hibernate Validator 9.1.6.Final, https://github.com/hibernate/hibernate-validator,
 * tag 9.1.6.Final: engine/src/main/java/org/hibernate/validator/messageinterpolation/
 * {AbstractMessageInterpolator,ResourceBundleMessageInterpolator,ParameterMessageInterpolator}.java
 * and internal/engine/messageinterpolation/{InterpolationTerm,ParameterTermResolver,
 * util/InterpolationHelper,parser/TokenCollector}.java
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

    /// Interpolates the message template based on the constraint validation context.
    string interpolate(string messageTemplate, Context context)
    {
        if (messageTemplate is null)
            return null;
        if (!contains(messageTemplate, '{'))
            return unescapeMessageParameter(messageTemplate);
        auto resolved = resolveMessage(messageTemplate);
        if (contains(resolved, '{'))
        {
            resolved = replaceTerms(resolved, false, (string term) => parameter(term, context));
            if (evaluateExpressions)
                resolved = replaceTerms(resolved, true, (string term) => expression(term, context));
        }
        return unescapeMessageParameter(resolved);
    }

    // AbstractMessageInterpolator.resolveMessage: the user bundle recursively, then the default bundle once.
    private string resolveMessage(string message)
    {
        string resolved = message;
        for (int round; round < 8; ++round)
        {
            auto user = replaceTerms(resolved, false, (string term) {
                auto found = term[1 .. $ - 1] in userBundle;
                return found is null ? term : *found;
            });
            const before = resolved;
            resolved = replaceTerms(user, false, (string term) {
                const value = defaultMessage(term[1 .. $ - 1]);
                return value is null ? term : value;
            });
            if (user == before && resolved == user)
                break;
        }
        return resolved;
    }

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

// TokenCollector: replace each `{...}` (parameter mode, skipping `${...}`) or each `${...}` (expression mode),
// honouring backslash escapes.
private string replaceTerms(string message, bool expressions, scope string delegate(string) @safe resolve)
{
    string result;
    size_t i;
    while (i < message.length)
    {
        if (message[i] == '\\' && i + 1 < message.length)
        {
            result ~= message[i .. i + 2];
            i += 2;
            continue;
        }
        const kind = termAt(message, i);
        if (kind == Term.none || (expressions && kind == Term.parameter))
        {
            result ~= message[i++];
            continue;
        }
        const end = closing(message, kind == Term.expression ? i + 1 : i);
        if (end == size_t.max)
        {
            result ~= message[i .. $];
            break;
        }
        const term = message[i .. end + 1];
        result ~= (!expressions && kind == Term.expression) ? term : resolve(term);
        i = end + 1;
    }
    return result;
}

private enum Term
{
    none,
    parameter,
    expression,
}

// Whether a `{...}` parameter or a `${...}` expression starts at `i`.
private Term termAt(string message, size_t i) pure nothrow @nogc
{
    if (message[i] == '$' && i + 1 < message.length && message[i + 1] == '{')
        return Term.expression;
    if (message[i] == '{' && (i == 0 || message[i - 1] != '$'))
        return Term.parameter;
    return Term.none;
}

// The index of the '}' closing the '{' at `open`, skipping quoted text and escapes; size_t.max when unclosed.
private size_t closing(string message, size_t open) pure nothrow @nogc
{
    char quote = 0;
    for (size_t i = open + 1; i < message.length; ++i)
    {
        const c = message[i];
        if (c == '\\')
        {
            ++i;
            continue;
        }
        if (quote)
        {
            if (c == quote)
                quote = 0;
            continue;
        }
        if (c == '\'' || c == '"')
            quote = c;
        else if (c == '}')
            return i;
        else if (c == '{')
            return size_t.max;
    }
    return size_t.max;
}
