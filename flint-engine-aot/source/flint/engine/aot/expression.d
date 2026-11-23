/++
Compiled SpEL for method-level expressions (AOT contract 3, section 9.1).

Flint AOT compiles each SpEL-valued attribute of a method's merged annotations (`@Cacheable(key)`,
`@PreAuthorize`, `@EventListener(condition)`, ...) to a typed D function over an `EvaluationContext`. The runtime
that applies the annotation builds the context over the invocation or event and calls `evaluate`.
+/
module flint.engine.aot.expression;

import flint.engine.aot.any : Any;

@safe:

/// What a compiled expression reads: the invocation's arguments and result, beans, placeholders and root functions.
interface EvaluationContext
{
    /// `#p0`, `#a0` or `#name`: the boxed argument at `index`.
    Any argument(size_t index);
    /// `#result`: the method's result; `Any.init` before the call.
    Any result();
    /// `#root.methodName`.
    string methodName();
    /// A root function such as `hasRole('A')`, `hasAnyRole`, `hasAuthority` or `isAuthenticated()`.
    Any rootFunction(string name, scope Any[] arguments);
    /// A root property such as `authentication`, `principal`, or an event root's `event`.
    Any rootProperty(string name);
    /// `@name`: the bean named `name`.
    Object bean(string name);
    /// `${...}` inside `#{...}`: the resolved placeholder text.
    string placeholder(string text);
}

/// An expression compiled by Flint AOT.
alias CompiledExpression = Any function(EvaluationContext context) @safe;

/// One SpEL-valued attribute of a method's merged annotations.
struct ExpressionSpec
{
    /// The annotation's fully qualified D name, as generated tables spell it.
    string annotation;
    /// The attribute holding the expression (`key`, `condition`, `unless`, `value`).
    string attribute;
    /// The expression's source text, for diagnostics.
    string source;
    /// The compiled expression.
    CompiledExpression evaluate;
}

/// Whether a condition's result means true: a `bool` true, or a string that reads `true` ignoring case
/// (Spring's `Boolean.TRUE.equals(value) || Boolean.parseBoolean(string)`).
bool isTrue(Any value)
{
    if (value.isNull)
        return false;
    if (value.typeName == "bool")
        return value.get!bool;
    if (value.typeName == "string")
    {
        const text = value.get!string;
        if (text.length != 4)
            return false;
        foreach (i, c; "true")
            if ((text[i] | 0x20) != c)
                return false;
        return true;
    }
    return false;
}

unittest
{
    assert(isTrue(Any.of(true)) && !isTrue(Any.of(false)) && !isTrue(Any.init));
    assert(isTrue(Any.of("TRUE")) && isTrue(Any.of("true")) && !isTrue(Any.of("yes")) && !isTrue(Any.of(1)));
}
