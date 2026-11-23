/++
What a generated startup condition can ask (AOT contract section 4.4, section 5.5).

Flint AOT compiles each definition's conditions (`@Profile`, `@ConditionalOnProperty`, `@ConditionalOnBean`, ...)
into one function over this interface. The runtime evaluates them once, at startup, in definition order.
+/
module flint.engine.aot.condition;

@safe:

/// The startup state a condition reads.
interface ConditionContext
{
    /// Whether `profile` is active, with Spring's rule that `default` is active when no profile is.
    bool acceptsProfile(string profile);
    /// `@ConditionalOnProperty`'s rule: with `havingValue` empty the property must exist and not equal `false`
    /// (ignoring case); otherwise it must equal `havingValue` (ignoring case). A `flint.*` name also matches
    /// its `spring.*` alias. A missing property matches when `matchIfMissing`.
    bool property(string name, string havingValue, bool matchIfMissing);
    /// Whether a definition registered so far can be injected as `type`.
    bool hasBeanOfType(string type);
    /// Whether a definition named `name` (or with that alias) is registered so far.
    bool hasBeanNamed(string name);
    /// Whether exactly one candidate of `type`, or exactly one primary candidate, is registered so far.
    bool hasSingleCandidate(string type);
    /// Whether the application is a web application of `type`: `ANY`, `SERVLET` or `REACTIVE`.
    bool isWebApplication(string type);
    /// Contract 2: whether the startup property `flint.autoconfigure.exclude` (alias `spring.autoconfigure.exclude`;
    /// a comma list or an indexed list) names the auto-configuration class `type`.
    bool isAutoConfigurationExcluded(string type);
}

/++
Boot's `@ConditionalOnProperty` match for a property value that `present` says exists. Shared by every
`ConditionContext` implementation so the rule lives in one place.
+/
bool propertyMatches(bool present, string value, string havingValue, bool matchIfMissing) pure nothrow @nogc
{
    if (!present)
        return matchIfMissing;
    if (havingValue.length == 0)
        return !equalsIgnoreCase(value, "false");
    return equalsIgnoreCase(value, havingValue);
}

/// ASCII case-insensitive equality, as Java's `String.equalsIgnoreCase` for the values properties hold.
bool equalsIgnoreCase(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z')
            x += 32;
        if (y >= 'A' && y <= 'Z')
            y += 32;
        if (x != y)
            return false;
    }
    return true;
}

unittest
{
    assert(propertyMatches(true, "on", "", false));
    assert(!propertyMatches(true, "FALSE", "", true));
    assert(propertyMatches(true, "True", "true", false));
    assert(!propertyMatches(true, "yes", "true", false));
    assert(propertyMatches(false, null, "true", true) && !propertyMatches(false, null, "", false));
}
