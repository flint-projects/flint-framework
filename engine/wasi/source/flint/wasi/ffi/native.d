/// Linux Wasmtime shim with synchronous borrowed input and generation-checked instances.
module flint.wasi.ffi.native;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.wasi.types : GuestAbi, Limits, PluginOptions;

@safe:

version (linux)
{
    version (FlintNativeWasmtime) version = FlintWasiNative;
}

private struct NativeModule;

version (FlintWasiNative) static assert(Limits.sizeof == 40 && Limits.wallTimeNanos.offsetof == 32);

private struct Span
{
    const(char)* data;
    size_t length;
}

private struct Directory
{
    Span host;
    Span guest;
    uint writable;
}

private struct Environment
{
    Span name;
    Span value;
}

extern (C) private @system nothrow @nogc
{
    int flint_wasi_compile(uint abi, const(ubyte)* wasm, size_t size, NativeModule** output);
    void flint_wasi_compiled_release(NativeModule* owned);
    int flint_wasi_instantiate(const(NativeModule)* module_, const(Limits)* limits,
            const(Directory)* dirs, size_t dirCount, const(Environment)* env, size_t envCount,
            uint network, ulong* output);
    int flint_wasi_call_i32(ulong id, Span name, const(int)* args, size_t count, int* output);
    int flint_wasi_interrupt(ulong id);
    int flint_wasi_copy_output(ulong id, ubyte** output, size_t* length);
    void flint_wasi_output_free(ubyte* temporary);
    int flint_wasi_release(ulong id);
}

private Error outcome(int status) pure nothrow @nogc
{
    static immutable string[] messages = [
        null, // ok
        "invalid guest, export or capabilities", // invalidArgument
        "unable to allocate guest storage", // outOfMemory
        "guest execution interrupted", // cancelled
        "guest execution exceeded its wall deadline", // timedOut
        "guest handle or export not found", // notFound
        "guest store is busy or retired after interruption", // conflict
        "guest execution trapped", // ioError
        "unable to initialize the guest engine", // unavailable
        "guest engine or ABI adapter unavailable", // unsupported
        "guest capability denied", // permissionDenied
        "guest resource limit exceeded", // resourceExhausted
    ];
    static assert(messages.length == Status.max + 1);
    return status >= 0 && status <= Status.max ? Error(cast(Status) status,
            messages[status]) : Error(Status.ioError, "unexpected native guest status");
}

package(flint.wasi) struct Module
{
    private NativeModule* owned;

    bool available() const pure nothrow @nogc
    {
        return owned !is null;
    }

    // SAFETY: The ABI borrows the checked Wasm slice only through this synchronous call and
    // returns an owned compiled artifact. No guest callback can run during compilation.
    Error start(GuestAbi abi, scope const(ubyte)[] wasm) @trusted nothrow @nogc
    {
        version (FlintWasiNative)
        {
            const status = flint_wasi_compile(cast(uint) abi, wasm.ptr, wasm.length, &owned);
            return outcome(status);
        }
        else
            return outcome(Status.unsupported);
    }

    // SAFETY: Only this owner releases the artifact after synchronous instantiations complete.
    // Native stores retain their own engine and module ownership.
    void release() @trusted nothrow @nogc
    {
        version (FlintWasiNative)
            if (owned !is null)
                flint_wasi_compiled_release(owned);
        owned = null;
    }

    // SAFETY: Bounded stack descriptors reference immutable option strings only during
    // instantiation. Wasmtime copies values and admits only native capability callbacks.
    Result!ulong instantiate(scope const ref PluginOptions options) @trusted nothrow @nogc
    {
        version (FlintWasiNative)
        {
            Directory[32] directories;
            Environment[64] environment;
            if (options.preopens.length > directories.length || options.environment.length > environment.length)
                return Result!ulong(0, outcome(Status.invalidArgument));
            foreach (index, ref path; options.preopens)
                directories[index] = Directory(Span(path.hostPath.ptr, path.hostPath.length),
                        Span(path.guestPath.ptr, path.guestPath.length), path.writable);
            foreach (index, ref item; options.environment)
                environment[index] = Environment(Span(item.name.ptr, item.name.length),
                        Span(item.value.ptr, item.value.length));

            ulong id;
            const status = flint_wasi_instantiate(owned, &options.limits, directories.ptr,
                    options.preopens.length, environment.ptr, options.environment.length, options.allowNetwork, &id);
            return Result!ulong(id, outcome(status));
        }
        else
            return Result!ulong(0, outcome(Status.unsupported));
    }
}

// SAFETY: The ABI borrows the name and arguments synchronously and checks the slot generation
// before using a store. No D reference is retained by guest functions or native callbacks.
package(flint.wasi) Result!int call(ulong id, scope const(char)[] name, scope const(int)[] args) @trusted nothrow @nogc
{
    version (FlintWasiNative)
    {
        int result;
        const status = flint_wasi_call_i32(id, Span(name.ptr, name.length), args.ptr, args.length, &result);
        return Result!int(result, outcome(status));
    }
    else
        return Result!int(0, outcome(Status.unsupported));
}

// SAFETY: Only the scalar instance token crosses the ABI. Native lookup holds the scheduler lock.
package(flint.wasi) Error interrupt(ulong id) @trusted nothrow @nogc
{
    version (FlintWasiNative)
        return outcome(flint_wasi_interrupt(id));
    else
        return outcome(Status.unsupported);
}

// SAFETY: Snapshot memory is an owned, bounded native allocation. Copy into the caller's
// arena and free the temporary before returning. No alias survives the call.
package(flint.wasi) Result!Buffer copyOutput(ulong id, ref scope RequestArena arena) @trusted nothrow @nogc
{
    version (FlintWasiNative)
    {
        ubyte* snapshot;
        size_t length;
        const status = flint_wasi_copy_output(id, &snapshot, &length);
        scope (exit)
            flint_wasi_output_free(snapshot);
        if (status)
            return Result!Buffer(Buffer.init, outcome(status));
        return arena.copyIn(snapshot[0 .. length]);
    }
    else
        return Result!Buffer(Buffer.init, outcome(Status.unsupported));
}

// SAFETY: Only the scalar instance token crosses the ABI. The shim joins active use
// and retires the generation before freeing its provider resources.
package(flint.wasi) Error release(ulong id) @trusted nothrow @nogc
{
    version (FlintWasiNative)
        return outcome(flint_wasi_release(id));
    else
        return outcome(Status.unsupported);
}
