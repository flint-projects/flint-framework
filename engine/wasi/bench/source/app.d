/// Exercise compiled Wasmtime guests through the public Flint API.
module app;

import core.lifetime : move;
import flint.engine.wasi : CompiledPlugin, GuestAbi, Plugin, PluginOptions;
import wasi_workload : run;

@safe:

private struct FlintBackend
{
    private CompiledPlugin compiled;
    private Plugin tenant;
    private PluginOptions options;

    bool compile(scope const(ubyte)[] guest, uint abi)
    {
        close();
        options.abi = cast(GuestAbi) abi;
        options.limits.maxInstances = 4;
        auto module_ = CompiledPlugin.compile(guest, options.engine, options.abi);
        if (!module_.ok())
            return false;
        compiled = move(module_.value);
        return true;
    }

    bool instantiate()
    {
        tenant.close();
        auto requested = compiled.instantiate(options);
        if (!requested.ok())
            return false;
        tenant = move(requested.value);
        return true;
    }

    int answer()
    {
        const result = tenant.callI32("answer", null);
        return result.ok() ? result.value : int.min;
    }

    void close()
    {
        tenant.close();
        compiled.close();
    }
}

int main(string[] argv)
{
    return run!FlintBackend(argv);
}
