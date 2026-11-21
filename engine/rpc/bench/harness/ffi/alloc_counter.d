/// GNU linker heap-call counts for the separately instrumented local probes.
module ffi.alloc_counter;

@safe:

version (FlintRpcAllocationProbe)
{
    private extern (C) @system nothrow @nogc
    {
        void flint_rpc_begin_count();
        ulong flint_rpc_end_count();
    }
}

/// Start observing native allocations in the caller's benchmark thread.
// SAFETY: This only resets native thread-local counters and retains no arguments.
void beginCount() @trusted nothrow @nogc
{
    version (FlintRpcAllocationProbe)
        flint_rpc_begin_count();
}

/// Return the observed allocations or ulong.max when the fixture has no instrumentation.
// SAFETY: The native function reads and disables its thread-local scalar counter.
ulong endCount() @trusted nothrow @nogc
{
    version (FlintRpcAllocationProbe)
        return flint_rpc_end_count();
    else
        return ulong.max;
}
