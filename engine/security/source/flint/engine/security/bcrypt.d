/++
bcrypt password hashing over the pinned crypt_blowfish provider (owner decision 5; size-levers' `crypt-blowfish`).

`bcryptHash` hashes a password with a setting (`$2a$10$` and a 22-character salt) or, given a stored hash as the
setting, rehashes it for verification. `bcryptSalt` makes a setting from 16 bytes of OS randomness. Without the
provider both report `Status.unsupported`.
+/
module flint.engine.security.bcrypt;

public import flint.arena : Error, Status;
import flint.engine.security.ffi.bcrypt : bcryptLinked, bcryptSetting, nativeHash = bcryptHash;

@safe:
nothrow @nogc:

/// Whether the bcrypt provider is linked into this program.
bool bcryptAvailable() pure
{
    return bcryptLinked;
}

/// Hash `password` (its first 72 bytes, as bcrypt does) with `setting`. The hash is `output[0 .. length]` (60
/// characters); `length` is 0 on failure.
Error bcryptHash(scope const(ubyte)[] password, scope const(char)[] setting, ref char[61] output, out size_t length)
{
    const status = nativeHash(password, setting, output);
    if (status != Status.ok)
        return failure(status);
    while (length < output.length && output[length] != '\0')
        length++;
    return Error.init;
}

/// A bcrypt setting for version `minor` (`'a'`, `'b'` or `'y'`) and `cost` log rounds (4 to 31), salted with 16
/// bytes of OS randomness. The setting is `output[0 .. length]` (29 characters); `length` is 0 on failure.
Error bcryptSalt(char minor, uint cost, ref char[30] output, out size_t length)
{
    import flint.conc : fillSecureRandom;

    ubyte[16] random;
    const randomness = fillSecureRandom(random[]);
    if (randomness.code != Status.ok)
        return randomness;
    const status = bcryptSetting(minor, cost, random, output);
    random[] = 0;
    if (status != Status.ok)
        return failure(status);
    while (length < output.length && output[length] != '\0')
        length++;
    return Error.init;
}

private Error failure(Status status) pure
{
    return Error(status, status == Status.unsupported
            ? "bcrypt provider (crypt-blowfish) is not linked" : "bcrypt rejected the password, setting or cost");
}
