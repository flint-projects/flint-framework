/// Length-delimited calls into the bcrypt shim over the pinned crypt_blowfish provider (flint_bcrypt.h).
module flint.engine.security.ffi.bcrypt;

import flint.arena : Status;

@safe:
nothrow @nogc:

version (FlintNativeCryptBlowfish)
{
    extern (C) private @system
    {
        int flint_bcrypt_hash(const(ubyte)*, size_t, const(char)*, size_t, char*, size_t);
        int flint_bcrypt_setting(char, uint, const(ubyte)*, char*, size_t);
    }

    /// Whether the provider is linked.
    package(flint.engine.security) enum bcryptLinked = true;
}
else
    package(flint.engine.security) enum bcryptLinked = false;

// SAFETY: `key` and `setting` are valid for their lengths and only read during the call; `output` is a 61-byte
// buffer the shim writes at most 61 bytes into (it checks the capacity it is given). Nothing is retained.
package(flint.engine.security) @trusted Status bcryptHash(scope const(ubyte)[] key,
        scope const(char)[] setting, ref char[61] output)
{
    output[] = '\0';
    static if (bcryptLinked)
        return cast(Status) flint_bcrypt_hash(key.length ? &key[0] : null, key.length,
                setting.length ? &setting[0] : null, setting.length, &output[0], output.length);
    else
        return Status.unsupported;
}

// SAFETY: `random` is 16 readable bytes and `output` a 30-byte buffer, both only used during the call; the shim
// writes at most `output.length` bytes.
package(flint.engine.security) @trusted Status bcryptSetting(char minor, uint cost,
        ref const ubyte[16] random, ref char[30] output)
{
    output[] = '\0';
    static if (bcryptLinked)
        return cast(Status) flint_bcrypt_setting(minor, cost, &random[0], &output[0], output.length);
    else
        return Status.unsupported;
}
