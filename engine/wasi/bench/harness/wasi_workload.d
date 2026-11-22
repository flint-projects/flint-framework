/// Shared checked compilation, cached instantiation, and scalar-call workloads.
module wasi_workload;

import core.memory : GC;
import core.stdc.stdio : FILE, fclose, fopen, fread, printf;
import core.time : MonoTime;
import std.exception : enforce;

@safe:

private enum batchSize = 100_000;
private enum batches = 20;
private enum compileSamples = 64;
private enum instanceSamples = 512;

// SAFETY: The path is copied with a terminating NUL; fread writes at most the length of the live
// local chunk, and the stream is closed before returning.
private ubyte[] readBytes(string path) @trusted
{
    FILE* stream = fopen((path ~ '\0').ptr, "rb");
    enforce(stream !is null, "could not open " ~ path);
    scope (exit)
        fclose(stream);
    ubyte[] bytes;
    ubyte[65_536] chunk;
    for (;;)
    {
        const count = fread(chunk.ptr, 1, chunk.length, stream);
        bytes ~= chunk[0 .. count];
        if (count < chunk.length)
            break;
    }
    return bytes;
}

private bool space(char value) pure nothrow @nogc
{
    return value == ' ' || value == '\t' || value == '\n' || value == '\r' || value == '\v' || value == '\f';
}

private string memoryCounter(string key)
{
    const status = cast(const(char)[]) readBytes("/proc/self/status");
    size_t start;
    while (start < status.length)
    {
        size_t end = start;
        while (end < status.length && status[end] != '\n')
            ++end;
        auto line = status[start .. end];
        if (line.length >= key.length && line[0 .. key.length] == key)
        {
            line = line[key.length .. $];
            while (line.length && space(line[0]))
                line = line[1 .. $];
            while (line.length && space(line[$ - 1]))
                line = line[0 .. $ - 1];
            return line.idup;
        }
        start = end + 1;
    }
    return "unavailable";
}

private string join(string directory, string name) pure
{
    return directory.length && directory[$ - 1] == '/' ? directory ~ name : directory ~ "/" ~ name;
}

// SAFETY: Fixed NUL-terminated literal format; the file name is printed with its explicit length
// and every scalar matches its conversion.
private void printGuest(string file, long compiled, long instantiated) @trusted nothrow @nogc
{
    printf("%.*s Wasmtime 51.0.0 fuel=10000000 compile_count=%d compile_ns=%lld"
            ~ " instantiate_count=%d instantiate_ns=%lld\n",
            cast(int) file.length, file.ptr, compileSamples, compiled, instanceSamples, instantiated);
}

// SAFETY: Fixed NUL-terminated literal formats with matching scalar arguments; the samples are
// read only within the bounds of the live slice.
private void printScalar(long aggregate, ulong gc, scope const(long)[] durations) @trusted nothrow @nogc
{
    printf("core scalar_calls_per_trial=%d scalar_trials=%d elapsed_ns=%lld gc_bytes=%llu trial_ns=[",
            batchSize, batches, aggregate, gc);
    foreach (index, duration; durations)
    {
        if (index != 0)
            printf(", ");
        printf("%lld", duration);
    }
    printf("]\n");
}

// SAFETY: Fixed NUL-terminated literal formats; each string is printed with its explicit length and
// the checksum matches its conversion.
private void printTotals(string before, string resident, string highWater, ulong checksum) @trusted nothrow @nogc
{
    printf("resident_before=%.*s resident_with_engine=%.*s rss_high_water=%.*s\n",
            cast(int) before.length, before.ptr, cast(int) resident.length, resident.ptr,
            cast(int) highWater.length, highWater.ptr);
    printf("wasi-scalar %llu\n", checksum);
}

private long elapsed(MonoTime start)
{
    return (MonoTime.currTime - start).total!"nsecs";
}

/// Run identical warmed engine workloads in both binaries.
int run(Backend)(string[] argv)
{
    enforce(argv.length == 2, "pass the directory containing the generated WASI fixtures");
    const memoryBefore = memoryCounter("VmRSS:");
    Backend driver;
    scope (exit)
        driver.close();
    ulong checksum;
    static immutable modules = ["core", "preview1", "wasi02", "wasi03"];
    foreach (abi, file; modules)
    {
        const guest = cast(const(ubyte)[]) readBytes(join(argv[1], file ~ ".wasm"));
        const started = MonoTime.currTime;
        foreach (iteration; 0 .. compileSamples)
            enforce(driver.compile(guest, cast(uint) abi), "guest compilation failed");
        const compiled = elapsed(started);
        const warm = MonoTime.currTime;
        foreach (iteration; 0 .. instanceSamples)
            enforce(driver.instantiate(), "cached guest instantiation failed");
        const instantiated = elapsed(warm);
        const answered = driver.answer();
        enforce(answered == 42, "WASI version probe produced an unexpected value");
        checksum += answered;
        printGuest(file, compiled, instantiated);
    }

    const core = cast(const(ubyte)[]) readBytes(join(argv[1], "core.wasm"));
    enforce(driver.compile(core, 0) && driver.instantiate() && driver.answer() == 42, "core scalar warm-up failed");
    const before = GC.stats().allocatedInCurrentThread;
    long[batches] durations;
    foreach (ref duration; durations)
    {
        const started = MonoTime.currTime;
        foreach (iteration; 0 .. batchSize)
        {
            const answer = driver.answer();
            if (answer != 42)
                throw new Exception("core scalar verification failed");
            checksum += answer;
        }
        duration = elapsed(started);
    }
    const gc = GC.stats().allocatedInCurrentThread - before;
    enforce(gc == 0 && checksum == 84_000_168, "WASI hot allocation or checksum failed");

    long aggregate;
    foreach (sample; durations)
        aggregate += sample;
    enforce(aggregate >= 100_000_000, "WASI scalar trials did not cover 100 ms");
    printScalar(aggregate, gc, durations[]);
    printTotals(memoryBefore, memoryCounter("VmRSS:"), memoryCounter("VmHWM:"), checksum);
    return 0;
}
