/// Exercise the identical guests through the pinned Wasmtime C ABI.
module app;

import wasi_workload : run;

@safe:

private struct Code;
private struct Guest;

extern (C) private @system nothrow @nogc
{
    pragma(mangle, "reference_wasi_compile") Code* compileGuest(const(ubyte)* bytes, size_t length, uint abi);
    pragma(mangle, "reference_wasi_instantiate") Guest* instantiateGuest(Code* code);
    pragma(mangle, "reference_wasi_answer") int guestAnswer(Guest* guest);
    pragma(mangle, "reference_wasi_close") void closeGuest(Guest* guest);
    pragma(mangle, "reference_wasi_release") void releaseCode(Code* code);
}

private struct DirectBackend
{
    private Code* code;
    private Guest* guest;

    // SAFETY: A byte span is borrowed only for synchronous provider compilation.
    bool compile(scope const(ubyte)[] bytes, uint abi) @trusted nothrow @nogc
    {
        close();
        code = compileGuest(bytes.ptr, bytes.length, abi);
        return code !is null;
    }

    // SAFETY: Both store and compiled code are owned by the benchmark driver.
    bool instantiate() @trusted nothrow @nogc
    {
        closeGuest(guest);
        guest = instantiateGuest(code);
        return guest !is null;
    }

    // SAFETY: This is a synchronous call with no borrowed guest result bytes.
    int answer() @trusted nothrow @nogc
    {
        return guestAnswer(guest);
    }

    // SAFETY: Retire benchmark-owned native storage after its last synchronous use.
    void close() @trusted nothrow @nogc
    {
        closeGuest(guest);
        releaseCode(code);
        guest = null;
        code = null;
    }
}

int main(string[] argv)
{
    return run!DirectBackend(argv);
}
