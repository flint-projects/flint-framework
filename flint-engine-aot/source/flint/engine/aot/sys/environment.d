/++
The process environment behind `flint.engine.aot.host`: one variable, and a copy of every entry.
Private to `flint:engine-aot`; applications never import it.

Every function copies what the C library or Windows hands back into GC memory before it returns, so nothing
retains a pointer into the environment block, which a later `setenv` may free.
+/
module flint.engine.aot.sys.environment;

@safe:

version (Windows)
{
    import core.sys.windows.windef : DWORD;

    private extern (Windows) nothrow @nogc
    {
        DWORD GetEnvironmentVariableW(scope const(wchar)* name, wchar* buffer, DWORD size) @system;
        wchar* GetEnvironmentStringsW() @system;
        int FreeEnvironmentStringsW(wchar* block) @system;
        DWORD GetLastError() @system;
        void SetLastError(DWORD error) @system;
        int LCMapStringEx(scope const(wchar)* locale, DWORD flags, scope const(wchar)* source, int sourceLength,
            wchar* destination, int destinationLength, void* version_, void* reserved, size_t handle) @system;
    }

    private enum DWORD ERROR_ENVVAR_NOT_FOUND = 203;

    /++
    The value of the variable `namez` names (UTF-16, ending in the NUL the caller added): null when it is not set, a
    non-null empty array when it is set to the empty string. Windows compares names without regard to case.
    +/
    // GetEnvironmentVariableW returns 0 both for an empty value and on failure, and sets the error only on failure,
    // so the error is cleared first (as std.process does); any error but "not found" reads as empty.
    // SAFETY: namez is NUL-terminated (checked); Windows writes at most buffer.length units, NUL included, into
    // the GC buffer this function owns, which is resized to the reported length before each retry.
    @trusted wchar[] readVariable(scope const(wchar)[] namez) nothrow
    {
        if (namez.length == 0 || namez[$ - 1] != '\0')
            return null;
        auto buffer = new wchar[](256);
        for (;;)
        {
            SetLastError(0);
            const length = GetEnvironmentVariableW(&namez[0], &buffer[0], cast(DWORD) buffer.length);
            if (length == 0)
                return GetLastError() == ERROR_ENVVAR_NOT_FOUND ? null : buffer[0 .. 0];
            if (length < buffer.length)
                return buffer[0 .. length];
            buffer = new wchar[](length); // too small: length counts the NUL
        }
    }

    /++
    A copy of the environment block: `name=value` entries, each followed by a NUL, the last by a second NUL.
    Null when Windows cannot provide it.
    +/
    // SAFETY: the block ends in two NULs (Windows' contract); reads stop at the first double NUL and the copy is
    // made before the block is freed, so nothing points into it afterwards.
    @trusted wchar[] environmentBlock() nothrow
    {
        wchar* block = GetEnvironmentStringsW();
        if (block is null)
            return null;
        size_t length;
        while (block[length] != '\0' || block[length + 1] != '\0')
            length++;
        auto copy = block[0 .. length + 2].dup;
        FreeEnvironmentStringsW(block);
        return copy;
    }

    /++
    `name` upper-cased with the invariant locale, as Windows compares environment names; std.process uses std.uni's
    `toUpper`, which agrees for every name made of letters, digits and punctuation.
    +/
    // SAFETY: LCMapStringEx reads name.length units of name and writes at most upper.length units into the GC
    // buffer this function owns, which has exactly name.length units (upper-casing in place keeps the length).
    @trusted wchar[] upperCase(scope const(wchar)[] name) nothrow
    {
        enum DWORD LCMAP_UPPERCASE = 0x0200;
        static immutable wchar[1] invariantLocale = ['\0'];
        auto upper = name.dup;
        if (name.length == 0 || name.length > int.max)
            return upper;
        const written = LCMapStringEx(&invariantLocale[0], LCMAP_UPPERCASE, &name[0], cast(int) name.length,
            &upper[0], cast(int) upper.length, null, null, 0);
        return written == name.length ? upper : name.dup;
    }
}
else version (Posix)
{
    import core.stdc.string : strlen;
    import core.sys.posix.unistd : environ;

    private extern (C) const(char)* getenv(scope const(char)* name) nothrow @nogc @system;

    /++
    The value of the variable `namez` names (ending in the NUL the caller added), copied: null when it is not set,
    `""` when it is set to the empty string.
    +/
    // SAFETY: namez is NUL-terminated (checked); getenv's result is read up to its NUL and copied before return.
    @trusted string readVariable(scope const(char)[] namez) nothrow
    {
        if (namez.length == 0 || namez[$ - 1] != '\0')
            return null;
        const value = getenv(&namez[0]);
        if (value is null)
            return null;
        const length = strlen(value);
        return length == 0 ? "" : value[0 .. length].idup;
    }

    /// A copy of every `name=value` entry of `environ`, in order.
    // SAFETY: environ is a null-terminated array of NUL-terminated strings (POSIX); each is copied before return.
    @trusted string[] environmentEntries() nothrow
    {
        const(char*)* entries = environ;
        string[] copies;
        if (entries is null)
            return copies;
        for (size_t i = 0; entries[i] !is null; i++)
            copies ~= entries[i][0 .. strlen(entries[i])].idup;
        return copies;
    }
}
else
    static assert(0, "flint.engine.aot.sys.environment: unsupported platform");

version (Posix) unittest
{
    import std.process : environment;

    // Positive: a set variable, an empty one (non-null), and the entry list holding both.
    environment["FLINT_SYS_ENV_TEST"] = "value=with=equals";
    environment["FLINT_SYS_ENV_EMPTY"] = "";
    scope (exit)
    {
        environment.remove("FLINT_SYS_ENV_TEST");
        environment.remove("FLINT_SYS_ENV_EMPTY");
    }
    assert(readVariable("FLINT_SYS_ENV_TEST\0") == "value=with=equals");
    const empty = readVariable("FLINT_SYS_ENV_EMPTY\0");
    assert(empty !is null && empty.length == 0);
    bool sawTest, sawEmpty;
    foreach (entry; environmentEntries())
    {
        sawTest |= entry == "FLINT_SYS_ENV_TEST=value=with=equals";
        sawEmpty |= entry == "FLINT_SYS_ENV_EMPTY=";
    }
    assert(sawTest && sawEmpty);

    // Negative: an unset variable is null, and a name without its NUL is refused rather than read past.
    assert(readVariable("FLINT_SYS_ENV_UNSET_EVER\0") is null);
    assert(readVariable("FLINT_SYS_ENV_TEST") is null);
    assert(readVariable("") is null);
}
