/// Explicit compile-time policy registration and scoped role inspection.
module flint.engine.security.authorization;

import flint.arena : Error, RequestArena, Status;
import flint.conc : Context;
import flint.engine.security.types : PreAuthorize, Principal, RolesAllowed;

@safe:

/// An authorization check over a verified principal and caller context.
alias PrincipalPolicy = Error function(scope const ref Principal principal, ref Context context) @safe nothrow @nogc;

/// Register one check under a startup-independent identifier.
struct RegisteredPolicy(string name, alias check)
{
    static assert(identifier(name), "authorization policy name must be an identifier");
    static assert(is(typeof(&check) : PrincipalPolicy), "authorization policy must have the PrincipalPolicy signature");
    private enum policyName = name;
    private static Error decide(scope const ref Principal principal, ref Context context) nothrow @nogc
    {
        return check(principal, context);
    }
}

/// Invoke a compile-time selected policy with the verified principal.
Error authorize(PreAuthorize rule, Entries...)(scope const ref Principal principal, ref Context context) nothrow @nogc
{
    enum count = policyCount!(rule.policy, Entries);
    static assert(count == 1, "authorization policy is missing or ambiguous: " ~ rule.policy);
    const active = context.check();
    if (active.code != Status.ok)
        return active;
    static foreach (Entry; Entries)
        static if (Entry.policyName == rule.policy)
            return Entry.decide(principal, context);
}

private template policyCount(string name, Entries...)
{
    static if (Entries.length == 0)
        enum policyCount = 0;
    else
        enum policyCount = (Entries[0].policyName == name) + policyCount!(name, Entries[1 .. $]);
}

/// Evaluate compile-time role metadata using exact, case-sensitive membership.
bool rolesAllowed(RolesAllowed rule)(scope const ref Principal principal, ref scope RequestArena arena) nothrow @nogc
{
    static assert(validRoles(rule.roles), "invalid RolesAllowed metadata");
    foreach (role; rule.roles)
        if (hasRole(principal, role, arena))
            return true;
    return false;
}

/// Check a validated arena-backed role name.
bool hasRole(scope const ref Principal principal, scope const(char)[] role, ref scope RequestArena arena) nothrow @nogc
{
    if (!role.length || role.length > ushort.max)
        return false;
    bool found;
    const status = arena.read(principal.roles, (scope const(ubyte)[] packed) {
        found = contains(packed, cast(const(ubyte)[]) role);
    });
    return status == Status.ok && found;
}

private bool contains(scope const(ubyte)[] packed, scope const(ubyte)[] target) pure nothrow @nogc
{
    bool found;
    size_t offset;
    while (offset < packed.length)
    {
        if (packed.length - offset < 2)
            return false;
        const length = cast(size_t) packed[offset] | (cast(size_t) packed[offset + 1] << 8);
        offset += 2;
        if (length == 0 || length > packed.length - offset)
            return false;
        found |= packed[offset .. offset + length] == target;
        offset += length;
    }
    return found;
}

private bool identifier(scope const(char)[] name) pure nothrow @nogc
{
    if (!name.length || name.length > 128)
        return false;
    foreach (index, item; name)
    {
        const alpha = (item >= 'a' && item <= 'z') || (item >= 'A' && item <= 'Z') || item == '_';
        if (!alpha && (index == 0 || item < '0' || item > '9'))
            return false;
    }
    return true;
}

private bool validRoles(scope const(string)[] roles) pure nothrow @nogc
{
    if (!roles.length || roles.length > 64)
        return false;
    foreach (index, item; roles)
    {
        if (!item.length || item.length > 128)
            return false;
        foreach (character; item)
            if (character <= ' ' || character == 127)
                return false;
        foreach (other; roles[0 .. index])
            if (item == other)
                return false;
    }
    return true;
}
