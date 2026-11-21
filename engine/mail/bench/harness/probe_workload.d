/// Shared equivalent-work SMTP measurement input and acceptance checks.
module probe_workload;

import flint.arena : Buffer, RequestArena, Status;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : readText;
import std.json : parseJSON;
import std.process : environment;
import std.stdio : writeln;
import std.string : lineSplitter, split;

@safe:

alias Deliver = long function(scope string, scope string, ref scope RequestArena, Buffer) @safe;

private long peakMemory()
{
    foreach (line; readText("/proc/self/status").lineSplitter)
        if (line.length >= 6 && line[0 .. 6] == "VmHWM:")
            return line.split()[1].to!long * 1024;
    return 0;
}

private size_t attachmentBytes(string[] args)
{
    if (args.length == 2 && (args[1] == "1" || args[1] == "8"))
        return args[1].to!size_t * 1024 * 1024;
    return 0;
}

/// Submit a deterministic transfer and check the fixture's decoded attachment.
int exercise(string[] args, scope Deliver deliver)
{
    const byteCount = attachmentBytes(args);
    if (!byteCount)
        return 1;
    const endpoint = environment.get("FLINT_MAIL_BENCH", "");
    const ca = environment.get("FLINT_MAIL_CA", "");
    const record = environment.get("FLINT_MAIL_BENCH_PATH", "");
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
    writeln(byteCount, " ", expected);
    writeln("peak_before_bytes=", before, " peak_after_bytes=", after, " peak_delta_bytes=",
            after - before, " elapsed_milliseconds=", elapsed);
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
