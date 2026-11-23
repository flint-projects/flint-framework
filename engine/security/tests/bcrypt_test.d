module flint.engine.security.bcrypt_test;

import flint.arena : Status;
import flint.engine.security : bcryptAvailable, bcryptHash, bcryptSalt;

@safe:

private string hashed(string password, string setting) nothrow @nogc
{
    char[61] buffer;
    size_t length;
    const error = bcryptHash(cast(const(ubyte)[]) password, setting, buffer, length);
    if (error.code != Status.ok)
        return "error";
    return buffer[0 .. length] == setting ? "match" : "differs";
}

version (FlintNativeCryptBlowfish)
{
    unittest
    {
        // Positive: Openwall's vectors, the four versions, the empty key, and petclinic-rest's seeded admin hash.
        assert(bcryptAvailable());
        assert(hashed("U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW") == "match");
        assert(hashed("U*U*U", "$2a$05$XXXXXXXXXXXXXXXXXXXXXOAcXxm9kjPGEMsLznoKqmqw7tc8WCx4a") == "match");
        assert(hashed("\xff\xff\xa3", "$2y$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e") == "match");
        assert(hashed("\xff\xff\xa3", "$2b$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e") == "match");
        assert(hashed("\xff\xff\xa3", "$2a$05$/OK.fbVrR/bpIqNJ5ianF.nqd1wy.pTMdcvrRWxyiGL2eMz.2a85.") == "match");
        assert(hashed("", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.7uG0VCzI2bS7j6ymqJi9CdcdxiRTWNy") == "match");
        assert(hashed("admin", "$2a$10$ymaklWBnpBKlgdMgkjWVF.GMGyvH8aDuTK.glFOaKw712LHtRRymS") == "match");
        // Negative: a wrong password differs; bad settings are refused.
        assert(hashed("Admin", "$2a$10$ymaklWBnpBKlgdMgkjWVF.GMGyvH8aDuTK.glFOaKw712LHtRRymS") == "differs");
        assert(hashed("U*U", "$2c$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW") == "error");
        assert(hashed("U*U", "$2a$03$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW") == "error");
        assert(hashed("U*U", "$2a$05$CCCC") == "error" && hashed("U*U", "") == "error");
        // Keys past 72 bytes: only the first 72 count, as bcrypt specifies.
        enum long72 = "0123456789012345678901234567890123456789012345678901234567890123456789ab";
        char[30] setting;
        size_t settingLength;
        assert(bcryptSalt('a', 4, setting, settingLength).code == Status.ok);
        char[61] first, second;
        size_t a, b;
        assert(bcryptHash(cast(const(ubyte)[]) long72, setting[0 .. settingLength], first, a).code == Status.ok);
        assert(bcryptHash(cast(const(ubyte)[])(long72 ~ "cd"), setting[0 .. settingLength], second, b).code == Status
                .ok);
        assert(a == 60 && first[0 .. a] == second[0 .. b]);
    }

    unittest
    {
        // Salts: a fresh setting per call, in the requested version and cost, which then verifies.
        char[30] one, two;
        size_t first, second;
        assert(bcryptSalt('b', 4, one, first).code == Status.ok && first == 29 && one[0 .. 7] == "$2b$04$");
        assert(bcryptSalt('y', 5, two, second).code == Status.ok && two[0 .. 7] == "$2y$05$");
        assert(one[7 .. first] != two[7 .. second]);
        char[61] buffer;
        size_t length;
        assert(bcryptHash(cast(const(ubyte)[]) "secret", one[0 .. first], buffer, length).code == Status.ok);
        const hash = buffer[0 .. length].idup;
        assert(hashed("secret", hash) == "match" && hashed("Secret", hash) == "differs");
        // Refused: an unknown version letter, costs 3 and 32.
        assert(bcryptSalt('x', 4, one, first).code == Status.invalidArgument && first == 0);
        assert(bcryptSalt('a', 3, one, first).code == Status.invalidArgument);
        assert(bcryptSalt('a', 32, one, first).code == Status.invalidArgument);
    }
}
else
{
    unittest
    {
        // Without the provider both calls report unsupported and return empty results.
        assert(!bcryptAvailable());
        char[61] buffer;
        size_t length;
        assert(bcryptHash(cast(const(ubyte)[]) "admin", "$2a$10$ymaklWBnpBKlgdMgkjWVF.GMGyvH8aDuTK.glFOaKw712LHtRRymS",
                buffer, length).code == Status.unsupported && length == 0);
        char[30] setting;
        assert(bcryptSalt('a', 10, setting, length).code == Status.unsupported && length == 0);
    }
}
