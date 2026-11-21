/// Deterministic resource names and exact checksum bytes.
module flint.migrate.embedding;

import flint.migrate.types : Migration;
import std.digest.sha : sha256Of;
import std.utf : UTFException, validate;

@safe:

package(flint.migrate) enum maximumProgram = 1_048_576;
package(flint.migrate) enum maximumPrograms = 67_108_864;

package(flint.migrate) bool space(char ch) pure nothrow @nogc
{
    return ch == ' ' || (ch >= '\t' && ch <= '\r');
}

package(flint.migrate) bool letter(char ch) pure nothrow @nogc
{
    return ch == '_' || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z');
}

private bool digit(char ch) pure nothrow @nogc
{
    return ch >= '0' && ch <= '9';
}

package(flint.migrate) bool validIdentifier(scope const(char)[] text) pure nothrow @nogc
{
    if (text.length == 0 || !letter(text[0]))
        return false;
    foreach (ch; text[1 .. $])
    {
        if (!letter(ch) && !digit(ch))
            return false;
    }
    return true;
}

private bool validName(string name, ulong expected) pure nothrow @nogc
{
    if (name.length < 14 || name[0] != 'V' || name[$ - 4 .. $] != ".sql")
        return false;
    ulong number;
    size_t index = 1;
    while (index < name.length && digit(name[index]))
    {
        const value = cast(ulong)(name[index++] - '0');
        if (number > (cast(ulong) long.max - value) / 10)
            return false;
        number = number * 10 + value;
    }
    if (index < 7 || index + 6 >= name.length || number == 0 || number != expected || name[index .. index + 2] != "__")
        return false;
    foreach (ch; name[index + 2 .. $ - 4])
    {
        if (!letter(ch) && !digit(ch))
            return false;
    }
    return true;
}

package(flint.migrate) bool validText(scope const(char)[] text)
{
    bool content;
    foreach (ch; text)
    {
        if (ch == '\0')
            return false;
        if (!space(ch))
            content = true;
    }
    if (!content)
        return false;
    try
        validate(text);
    catch (UTFException)
        return false;
    return true;
}

private struct Digest
{
    ubyte[32] bytes;
    bool valid;
}

private int hex(char ch) pure nothrow @nogc
{
    if (digit(ch))
        return ch - '0';
    return ch >= 'a' && ch <= 'f' ? ch - 'a' + 10 : -1;
}

private Digest parseHex(scope const(char)[] text) pure nothrow @nogc
{
    if (text.length != 64)
        return Digest.init;
    Digest output;
    foreach (index, ref ch; output.bytes)
    {
        const upper = hex(text[index * 2]);
        const lower = hex(text[index * 2 + 1]);
        if (upper < 0 || lower < 0)
            return Digest.init;
        ch = cast(ubyte)(upper * 16 + lower);
    }
    output.valid = true;
    return output;
}

package(flint.migrate) bool matchDigest(scope const(char)[] hexText, const ref ubyte[32] expected) pure nothrow @nogc
{
    const parsed = parseHex(hexText);
    return parsed.valid && parsed.bytes == expected;
}

package(flint.migrate) bool validDigestText(scope const(char)[] text) pure nothrow @nogc
{
    return parseHex(text).valid;
}

package(flint.migrate) void digestText(const ref ubyte[32] hash, ref char[64] output) pure nothrow @nogc
{
    enum digits = "0123456789abcdef";
    foreach (index, ch; hash)
    {
        output[index * 2] = digits[ch >> 4];
        output[index * 2 + 1] = digits[ch & 15];
    }
}

package(flint.migrate) bool correctDigest(scope const ref Migration migration)
{
    return sha256Of(cast(const(ubyte)[]) migration.sql) == migration.sha256;
}

private Digest readSidecar(string contents, string filename) pure nothrow @nogc
{
    if (contents.length != 67 + filename.length || contents[64 .. 66] != "  "
            || contents[66 .. $ - 1] != filename || contents[$ - 1] != '\n')
        return Digest.init;
    return parseHex(contents[0 .. 64]);
}

/// Load a vetted SQL filename and exact generated checksum from the D string import path.
Migration embeddedMigration(string fileName, ulong versionNumber, string description, bool transactional = true)()
{
    static if (!validName(fileName, versionNumber))
        static assert(false, "invalid embedded migration filename or version");
    else
    {
        static assert(validText(description), "invalid migration description");
        enum sql = import(fileName);
        static assert(sql.length <= maximumProgram && validText(sql), "invalid UTF-8 or size in migration SQL");
        enum digest = readSidecar(import(fileName ~ ".sha256"), fileName);
        static assert(digest.valid, "invalid migration SHA-256 sidecar");
        return Migration(versionNumber, description, sql, digest.bytes, transactional);
    }
}
