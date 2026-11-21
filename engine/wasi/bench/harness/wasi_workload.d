/// Shared checked compilation, cached instantiation, and scalar-call workloads.
module wasi_workload;

import core.memory : GC;
import core.time : MonoTime;
import std.algorithm.searching : startsWith;
import std.exception : enforce;
import std.file : read, readText;
import std.path : buildPath;
import std.stdio : writefln;
import std.string : splitLines;

@safe:

private enum batchSize = 100_000;
private enum batches = 20;
private enum compileSamples = 64;
private enum instanceSamples = 512;

private string memoryCounter(string key)
{
    foreach (line; readText("/proc/self/status").splitLines())
        if (line.startsWith(key))
            return line[key.length .. $].strip();
    return "unavailable";
}

private import std.string : strip;

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
        const guest = cast(const(ubyte)[]) read(buildPath(argv[1], file ~ ".wasm"));
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
        enum report = "%s Wasmtime 51.0.0 fuel=10000000 compile_count=%s compile_ns=%s"
            ~ " instantiate_count=%s instantiate_ns=%s";
        writefln(report, file, compileSamples, compiled, instanceSamples, instantiated);
    }

    const core = cast(const(ubyte)[]) read(buildPath(argv[1], "core.wasm"));
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
    writefln("core scalar_calls_per_trial=%s scalar_trials=%s elapsed_ns=%s gc_bytes=%s trial_ns=%s",
            batchSize, batches, aggregate, gc, durations[]);
    writefln("resident_before=%s resident_with_engine=%s rss_high_water=%s", memoryBefore,
            memoryCounter("VmRSS:"), memoryCounter("VmHWM:"));
    writefln("wasi-scalar %s", checksum);
    return 0;
}
