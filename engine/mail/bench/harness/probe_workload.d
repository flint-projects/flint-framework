/// Shared equivalent-work SMTP measurement input and acceptance checks.
module probe_workload;

import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;
import core.stdc.string : strlen;
import flint.arena : Buffer, RequestArena, Status;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : readText;
import std.json : parseJSON;

@safe:

alias Deliver = long function(scope string, scope string, ref scope RequestArena, Buffer) @safe;

private long peakMemory()
{
    const status = readText("/proc/self/status");
    size_t start;
    while (start < status.length)
    {
        size_t end = start;
        while (end < status.length && status[end] != '\n')
            ++end;
        const line = status[start .. end];
        if (line.length >= 6 && line[0 .. 6] == "VmHWM:")
            return kibibytes(line[6 .. $]) * 1024;
        start = end + 1;
    }
    return 0;
}

private long kibibytes(scope const(char)[] field)
{
    size_t index;
    while (index < field.length && (field[index] == ' ' || field[index] == '\t'))
        ++index;
    if (index == field.length || field[index] < '0' || field[index] > '9')
        throw new Exception("VmHWM value is not a decimal number");
    long value;
    while (index < field.length && field[index] >= '0' && field[index] <= '9')
        value = value * 10 + (field[index++] - '0');
    return value;
}

private size_t attachmentBytes(string[] args)
{
    if (args.length == 2 && (args[1] == "1" || args[1] == "8"))
        return cast(size_t)(args[1][0] - '0') * 1024 * 1024;
    return 0;
}

// SAFETY: getenv returns null or a NUL-terminated environment string, copied before returning;
// the name is a NUL-terminated literal.
private string variable(scope const(char)* name) @trusted
{
    const value = getenv(name);
    return value is null ? "" : value[0 .. strlen(value)].idup;
}

// SAFETY: Fixed NUL-terminated literal formats; the digest is printed with its explicit length
// and every scalar matches its conversion.
private void report(size_t byteCount, scope string expected, long before, long after, long elapsed) @trusted
{
    printf("%zu %.*s\n", byteCount, cast(int) expected.length, expected.ptr);
    printf("peak_before_bytes=%lld peak_after_bytes=%lld peak_delta_bytes=%lld elapsed_milliseconds=%lld\n",
            before, after, after - before, elapsed);
}

/// Submit a deterministic transfer and check the fixture's decoded attachment.
int exercise(string[] args, scope Deliver deliver)
{
    const byteCount = attachmentBytes(args);
    if (!byteCount)
        return 1;
    const endpoint = variable("FLINT_MAIL_BENCH");
    const ca = variable("FLINT_MAIL_CA");
    const record = variable("FLINT_MAIL_BENCH_PATH");
    if (!endpoint.length || !ca.length || !record.length)
        return 2;
    auto arena = RequestArena(new ubyte[byteCount + 4096]);
    const attachment = arena.allocate(byteCount);
    if (!attachment.ok())
        return 3;
    const expected = initialized(arena, attachment.value, byteCount);
    if (!expected.length)
        return 4;
    const before = peakMemory();
    const elapsed = deliver(endpoint, ca, arena, attachment.value);
    if (elapsed < 0)
        return 5;
    const after = peakMemory();
    const observed = parseJSON(readText(record ~ ".bytes.json"));
    if (observed["length"].integer != byteCount || observed["sha256"].str != expected)
        return 7;
    report(byteCount, expected, before, after, elapsed);
    return before > 0 && after >= before ? 0 : 8;
}

private string initialized(ref scope RequestArena arena, Buffer input, size_t byteCount)
{
    if (arena.write(input, (scope ubyte[] bytes) {
            foreach (i, ref item; bytes)
                item = cast(ubyte)((i * 29 + byteCount) % 251);
        }) != Status.ok)
        return null;
    char[64] expected;
    if (arena.read(input, (scope const(ubyte)[] bytes) { expected[] = sha256Of(bytes).toHexString[]; }) != Status.ok)
        return null;
    return expected[].idup;
}
