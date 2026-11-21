module flint.wasi.contract_tests;

import flint.arena : Status;
import flint.wasi : Engine, GuestAbi, Plugin, PluginOptions;

@safe:

private immutable ubyte[] answerModule = [
    0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127, 3, 2, 1, 0, 7, 10, 1, 6, 97, 110, 115,
    119, 101, 114, 0, 0, 10, 6, 1, 4, 0, 65, 42, 11
];

@("Wasmtime validates and executes the required core fixture")
unittest
{
    const ubyte[] invalid = [1, 2, 3, 4];
    assert(Plugin.load(invalid).error.code == Status.invalidArgument);
    auto loaded = Plugin.load(answerModule);
    assert(loaded.ok(), loaded.error.message);
    scope (exit)
        assert(loaded.value.close().code == Status.ok);
    const answer = loaded.value.callI32("answer", null);
    assert(answer.ok() && answer.value == 42, answer.error.message);
    assert(loaded.value.callI32("answer", [1]).error.code == Status.invalidArgument);
    assert(loaded.value.callI32("missing", null).error.code == Status.notFound);

    PluginOptions other;
    other.engine = Engine.wamr;
    other.abi = GuestAbi.wasi03Component;
    assert(Plugin.load(answerModule, other).error.code == Status.unsupported);
}

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import flint.arena : RequestArena;
import flint.wasi : CompiledPlugin, GuestEnvironment, Preopen;
import flint.wasi.fixture_bytes : coreGuest = core, preview1Guest = preview1,
    unexpectedGuest = unexpected, component02 = wasi02, component03 = wasi03;
import std.conv : to;
import std.file : exists, mkdirRecurse, rmdirRecurse, symlink, tempDir, write;
import std.path : buildPath;

@("core store bounds, signature validation, traps and fuel")
unittest
{
    assert(Plugin.load(unexpectedGuest).error.code == Status.invalidArgument);
    assert(Plugin.load(preview1Guest).error.code == Status.invalidArgument);
    PluginOptions options;
    options.limits.maxMemoryBytes = 2 * 65_536;
    options.limits.maxTableElements = 2;
    options.limits.fuel = 200_000;
    auto loaded = Plugin.load(coreGuest, options);
    assert(loaded.ok(), loaded.error.message);
    auto answer = loaded.value.callI32("add", [41, 1]);
    assert(answer.ok() && answer.value == 42);
    assert(loaded.value.callI32("memory", null).error.code == Status.invalidArgument);
    assert(loaded.value.callI32("wrong-input", [1]).error.code == Status.invalidArgument);
    assert(loaded.value.callI32("wrong-output", null).error.code == Status.invalidArgument);
    assert(loaded.value.callI32("trap", null).error.code == Status.ioError);
    assert(loaded.value.callI32("grow", [1]).value == 1);
    assert(loaded.value.callI32("grow", [1]).value == -1);
    assert(loaded.value.callI32("table-grow", [1]).value == 1);
    assert(loaded.value.callI32("table-grow", [1]).value == -1);

    const start = MonoTime.currTime;
    const depleted = loaded.value.callI32("spin", null);
    assert(depleted.error.code == Status.resourceExhausted, depleted.error.message);
    assert((MonoTime.currTime - start).total!"msecs" < 100);
    assert(loaded.value.callI32("answer", null).value == 42);
    assert(loaded.value.close().code == Status.ok);
    assert(loaded.value.callI32("answer", null).error.code == Status.notFound);
}

@("one compiled artifact gives independent stores and a bounded wall deadline")
unittest
{
    auto prepared = CompiledPlugin.compile(coreGuest);
    assert(prepared.ok(), prepared.error.message);
    PluginOptions options;
    options.limits.wallTimeNanos = 30_000_000;
    options.limits.fuel = ulong.max;
    auto first = prepared.value.instantiate(options);
    auto other = prepared.value.instantiate();
    assert(first.ok() && other.ok());
    assert(prepared.value.close().code == Status.ok);
    assert(first.value.callI32("bump", null).value == 1);
    assert(first.value.callI32("bump", null).value == 2);
    assert(other.value.callI32("bump", null).value == 1);
    const start = MonoTime.currTime;
    const stopped = first.value.callI32("spin", null);
    assert(stopped.error.code == Status.timedOut, stopped.error.message);
    assert((MonoTime.currTime - start).total!"msecs" < 130);
    assert(other.value.callI32("answer", null).value == 42);
}

private final class Running
{
    Plugin* current;
    shared bool ready;
    shared bool finished;
    shared int result;

    void spin()
    {
        atomicStore(ready, true);
        const ended = current.callI32("spin", null);
        atomicStore(result, cast(int) ended.error.code);
        atomicStore(finished, true);
    }
}

@("cross-thread interrupt cancels the active generation only")
@system unittest
{
    auto prepared = CompiledPlugin.compile(coreGuest);
    assert(prepared.ok());
    PluginOptions options;
    options.limits.fuel = ulong.max;
    auto active = prepared.value.instantiate(options);
    auto unrelated = prepared.value.instantiate(options);
    assert(active.ok() && unrelated.ok());
    auto running = new Running;
    running.current = &active.value;
    auto thread = new Thread(&running.spin).start();
    scope (exit)
        thread.join();
    while (!atomicLoad(running.ready))
        Thread.sleep(1.msecs);
    const began = MonoTime.currTime;
    while (!atomicLoad(running.finished) && (MonoTime.currTime - began).total!"msecs" < 100)
    {
        assert(active.value.interrupt().code == Status.ok);
        const healthy = unrelated.value.callI32("answer", null);
        assert(healthy.ok() && healthy.value == 42);
        Thread.sleep(1.msecs);
    }
    assert(atomicLoad(running.finished));
    assert(atomicLoad(running.result) == Status.cancelled);
    assert(active.value.callI32("answer", null).value == 42);
}

private PluginOptions previewOptions() nothrow @nogc
{
    PluginOptions options;
    options.abi = GuestAbi.wasiPreview1;
    return options;
}

@("Preview1 environment and output are explicit and bounded")
unittest
{
    auto options = previewOptions();
    auto isolated = Plugin.load(preview1Guest, options);
    assert(isolated.ok(), isolated.error.message);
    assert(isolated.value.callI32("answer", null).value == 42);
    assert(isolated.value.callI32("environment-count", null).value == 0);

    options.inheritEnvironment = true;
    assert(Plugin.load(preview1Guest, options).error.code == Status.unsupported);
    options.environment = [GuestEnvironment("BAD=NAME", "value")];
    assert(Plugin.load(preview1Guest, options).error.code == Status.invalidArgument);
    options.environment = [GuestEnvironment("NOTE", "red\0other")];
    assert(Plugin.load(preview1Guest, options).error.code == Status.invalidArgument);
    options.environment = [GuestEnvironment("NOTE", "red")];
    options.limits.maxOutputBytes = 4;
    auto enabled = Plugin.load(preview1Guest, options);
    assert(enabled.ok(), enabled.error.message);
    assert(enabled.value.callI32("environment-count", null).value == 1);
    assert(enabled.value.callI32("environment-value", null).value == 'r');
    ubyte[128] storage;
    auto arena = RequestArena(storage[]);
    foreach (fd; [1, 2])
    {
        assert(enabled.value.callI32("emit", [fd]).error.code == Status.resourceExhausted);
        const bytes = enabled.value.copyOutput(arena);
        assert(bytes.ok() && bytes.value.length == 4);
        assert(arena.read(bytes.value, (scope const(ubyte)[] value) {
                assert(value == cast(const(ubyte)[]) "flin");
            }) == Status.ok);
    }
}

@("Preview1 preopens enforce directory handles, read-only rights and traversal restrictions")
@system unittest
{
    const path = buildPath(tempDir(), "flint-wasi-" ~ MonoTime.currTime.ticks.to!string);
    mkdirRecurse(buildPath(path, "cap"));
    scope (exit)
        rmdirRecurse(path);
    mkdirRecurse(buildPath(path, "outside"));
    write(buildPath(path, "cap", "allowed"), "Q");
    write(buildPath(path, "outside", "secret"), "Z");
    symlink("../outside/secret", buildPath(path, "cap", "escape"));
    symlink("cap", buildPath(path, "linked"));

    auto options = previewOptions();
    options.preopens = [Preopen(buildPath(path, "linked"), "/sandbox")];
    assert(Plugin.load(preview1Guest, options).error.code == Status.permissionDenied);
    options.preopens = [Preopen(buildPath(path, "cap"), "/sandbox")];
    auto denied = Plugin.load(preview1Guest, options);
    assert(denied.ok(), denied.error.message);
    assert(denied.value.callI32("read-allowed", null).value == 'Q');
    foreach (name; ["read-parent", "read-link"])
    {
        const blocked = denied.value.callI32(name, null);
        assert(blocked.ok() && blocked.value != 0 && blocked.value != 'Z');
    }
    assert(denied.value.callI32("create-file", null).value != 0);
    assert(!exists(buildPath(path, "cap", "newfile")));
    options.preopens[0].writable = true;
    auto allowed = Plugin.load(preview1Guest, options);
    assert(allowed.ok(), allowed.error.message);
    assert(allowed.value.callI32("create-file", null).value == 0);
    assert(exists(buildPath(path, "cap", "newfile")));
}

@("Preview1 async host wait observes the wall deadline and retires the pending store")
unittest
{
    auto options = previewOptions();
    options.limits.wallTimeNanos = 30_000_000;
    auto loaded = Plugin.load(preview1Guest, options);
    assert(loaded.ok(), loaded.error.message);
    const start = MonoTime.currTime;
    const ended = loaded.value.callI32("sleep", null);
    const elapsed = (MonoTime.currTime - start).total!"msecs";
    assert(ended.error.code == Status.timedOut, ended.error.message);
    assert(elapsed >= 25 && elapsed < 130);
    assert(loaded.value.callI32("answer", null).error.code == Status.conflict);
}

@("versioned WASI component linkers exercise their pinned WIT imports")
unittest
{
    PluginOptions options;
    options.abi = GuestAbi.wasi02Component;
    assert(Plugin.load(component02, options).error.code == Status.invalidArgument);
    options.limits.maxInstances = 4;
    auto p2 = Plugin.load(component02, options);
    assert(p2.ok(), p2.error.message);
    assert(p2.value.callI32("answer", null).value == 42);
    assert(p2.value.callI32("add", [22, 20]).value == 42);
    assert(p2.value.callI32("add", [42]).error.code == Status.invalidArgument);
    const defaultNetwork = p2.value.callI32("resolve", null);
    assert(defaultNetwork.ok() && defaultNetwork.value == 1, defaultNetwork.error.message);
    options.allowNetwork = true;
    auto network = Plugin.load(component02, options);
    assert(network.ok(), network.error.message);
    const explicitNetwork = network.value.callI32("resolve", null);
    assert(explicitNetwork.ok() && explicitNetwork.value == 0, explicitNetwork.error.message);
    assert(Plugin.load(component03, options).error.code == Status.invalidArgument);

    options.abi = GuestAbi.wasi03Component;
    options.allowNetwork = false;
    auto p3 = Plugin.load(component03, options);
    assert(p3.ok(), p3.error.message);
    foreach (iteration; 0 .. 64)
    {
        assert(p3.value.callI32("answer", null).value == 42);
        assert(p3.value.callI32("add", [20, 22]).value == 42);
        assert(p2.value.callI32("answer", null).value == 42);
    }
    assert(Plugin.load(component02, options).error.code == Status.invalidArgument);
    assert(Plugin.load(component03).error.code == Status.invalidArgument);
}
