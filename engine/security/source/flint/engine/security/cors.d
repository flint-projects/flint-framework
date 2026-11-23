/// Exact-origin and preflight access decisions for application middleware.
module flint.engine.security.cors;

import flint.engine.security.origin : Origin, parseOrigin, sameAscii;
import flint.engine.security.types : CorsDecision, CorsPolicy;

@safe:

/// Compare normalized scheme, address and port. Null and invalid origins are denied.
bool originAllowed(scope const ref CorsPolicy policy, scope const(char)[] origin) nothrow @nogc
{
    Origin requested;
    if (!parseOrigin(origin, requested))
        return false;
    bool allowed;
    foreach (configured; policy.origins)
    {
        if (configured == "*")
        {
            if (policy.credentials)
                return false;
            allowed = true;
            continue;
        }
        Origin candidate;
        if (!parseOrigin(configured, candidate))
            return false;
        allowed |= candidate == requested;
    }
    return allowed;
}

/// Check the requested method and comma-separated headers against the origin policy.
CorsDecision preflight(scope const ref CorsPolicy policy, scope const(char)[] origin,
        scope const(char)[] method, scope const(char)[] requestedHeaders) nothrow @nogc
{
    CorsDecision decision;
    if (originAllowed(policy, origin) && methodAllowed(policy.methods, method)
            && headersAllowed(policy.headers, requestedHeaders))
    {
        decision.allowed = true;
        decision.credentials = policy.credentials;
        decision.maxAgeSeconds = policy.maxAgeSeconds;
    }
    return decision;
}

private bool token(scope const(char)[] value) pure nothrow @nogc
{
    if (!value.length || value.length > 128)
        return false;
    foreach (item; value)
    {
        immutable letter = (item >= 'a' && item <= 'z') || (item >= 'A' && item <= 'Z');
        immutable digit = item >= '0' && item <= '9';
        bool punctuation;
        foreach (candidate; "!#$%&'*+-.^_|~")
            punctuation |= item == candidate;
        if (!letter && !digit && !punctuation)
            return false;
    }
    return true;
}

private bool methodAllowed(scope const(string)[] methods, scope const(char)[] method) pure nothrow @nogc
{
    if (!token(method))
        return false;
    foreach (allowed; methods)
        if (method == allowed)
            return true;
    return false;
}

private bool optionalSpace(char item) pure nothrow @nogc
{
    return item == ' ' || item == '\t';
}

private bool headerAllowed(scope const(string)[] allowed, scope const(char)[] item) pure nothrow @nogc
{
    size_t start;
    size_t end = item.length;
    while (start < end && optionalSpace(item[start]))
        ++start;
    while (end > start && optionalSpace(item[end - 1]))
        --end;
    const name = item[start .. end];
    if (!token(name))
        return false;
    foreach (entry; allowed)
        if (sameAscii(entry, name))
            return true;
    return false;
}

private bool headersAllowed(scope const(string)[] supported, scope const(char)[] input) pure nothrow @nogc
{
    if (input.length > 8192)
        return false;
    if (!input.length)
        return true;
    size_t start;
    foreach (index; 0 .. input.length + 1)
    {
        if (index != input.length && input[index] != ',')
            continue;
        if (!headerAllowed(supported, input[start .. index]))
            return false;
        start = index + 1;
    }
    return true;
}
