/// Pinned, capability-limited WebAssembly execution for Linux hosts.
module flint.engine.wasi;

import core.atomic : atomicExchange, atomicLoad, atomicStore;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.engine.wasi.ffi.native : Module, callNative = call, captureNative = copyOutput,
    interruptNative = interrupt, releaseNative = release;

public import flint.engine.wasi.types : Engine, GuestAbi, GuestEnvironment, Limits, PluginOptions, Preopen;

@safe:

/// A move-only compiled guest, reusable to instantiate multiple independent stores.
struct CompiledPlugin
{
    @disable this(this);
    private Module compiled;
    private Engine engine;
    private GuestAbi abi;

    /// Validate and compile raw WebAssembly bytes for one engine and ABI.
    static Result!CompiledPlugin compile(scope const(ubyte)[] wasm, Engine engine = Engine.wasmtime,
            GuestAbi abi = GuestAbi.core)
    {
        Result!CompiledPlugin result;
        if (engine > Engine.max || abi > GuestAbi.max)
        {
            result.error = Error(Status.invalidArgument, "invalid guest engine or ABI");
            return result;
        }
        if (engine == Engine.wamr)
        {
            result.error = Error(Status.unsupported, "WAMR is unavailable in this profile");
            return result;
        }
        result.error = result.value.compiled.start(abi, wasm);
        result.value.engine = engine;
        result.value.abi = abi;
        return result;
    }

    /// Create a fresh tenant store with an explicit and independent capability set.
    Result!Plugin instantiate(PluginOptions options = PluginOptions.init)
    {
        Result!Plugin result;
        if (!compiled.available())
        {
            result.error = Error(Status.notFound, "compiled guest is closed");
            return result;
        }
        if (options.abi != abi || options.engine != engine)
        {
            result.error = Error(Status.invalidArgument, "compiled guest ABI and engine must match runtime policy");
            return result;
        }
        if (options.inheritEnvironment && !options.environment.length)
        {
            result.error = Error(Status.unsupported, "guest environment requires explicit entries");
            return result;
        }

        const instance = compiled.instantiate(options);
        atomicStore(result.value.identity, instance.value);
        result.error = instance.error;
        return result;
    }

    /// Release the compiled artifact. Existing instances retain their own engine resources.
    Error close()
    {
        compiled.release();
        return Error.init;
    }

    ~this()
    {
        compiled.release();
    }
}

/// A move-only, generation-checked guest instance with one callable store.
struct Plugin
{
    @disable this(this);
    private shared ulong identity;

    /// Compile and instantiate a fresh instance.
    static Result!Plugin load(scope const(ubyte)[] wasm, PluginOptions options = PluginOptions.init)
    {
        auto prepared = CompiledPlugin.compile(wasm, options.engine, options.abi);
        if (!prepared.ok())
            return Result!Plugin(Plugin(), prepared.error);
        return prepared.value.instantiate(options);
    }

    /// Execute a scalar export with i32 inputs and one i32 output.
    Result!int callI32(scope const(char)[] exportName, scope const int[] args)
    {
        return callNative(atomicLoad(identity), exportName, args);
    }

    /// Interrupt the in-flight call without cancelling another tenant's work.
    Error interrupt()
    {
        return interruptNative(atomicLoad(identity));
    }

    /// Copy the last operation's combined stdout and stderr prefix into the supplied arena.
    Result!Buffer copyOutput(ref scope RequestArena arena)
    {
        return captureNative(atomicLoad(identity), arena);
    }

    /// Interrupt active use, wait for native retirement, and invalidate the handle.
    Error close()
    {
        return retire();
    }

    ~this()
    {
        retire();
    }

    private Error retire() nothrow @nogc
    {
        const id = atomicExchange(&identity, 0UL);
        return id ? releaseNative(id) : Error.init;
    }
}
