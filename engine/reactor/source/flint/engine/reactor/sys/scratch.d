module flint.engine.reactor.sys.scratch;

@safe:

version (linux)
{
    import core.stdc.errno : EACCES, ENOMEM, EPERM, errno;
    import core.sys.posix.sys.mman : MAP_ANON, MAP_FAILED, MAP_PRIVATE, PROT_READ, PROT_WRITE, mmap, munmap;
    import flint.arena : Status;

    /// An owner-local, zero-filled mapping for the fixed operation slots.
    package(flint.engine.reactor) struct Scratch
    {
        private ubyte[] storage;

        @disable this(this);

        // SAFETY: A successful anonymous private mapping is writable for exactly `bytes` bytes.
        // The worker owns its unique mapping until startup fails or all native I/O has retired.
        Status reserve(size_t bytes) @trusted nothrow @nogc
        {
            if (bytes == 0)
                return Status.invalidArgument;
            if (storage !is null)
                return Status.conflict;
            auto address = mmap(null, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
            if (address == MAP_FAILED)
            {
                const code = errno;
                if (code == ENOMEM)
                    return Status.outOfMemory;
                if (code == EACCES || code == EPERM)
                    return Status.permissionDenied;
                return Status.ioError;
            }
            if (address is null)
            {
                munmap(address, bytes);
                return Status.ioError;
            }
            storage = (cast(ubyte*) address)[0 .. bytes];
            return Status.ok;
        }

        ubyte[] slice(size_t begin, size_t end) return scope pure nothrow @nogc
        {
            return storage[begin .. end];
        }

        // SAFETY: This package-private owner releases its only mapping after joining the worker
        // and closing the completion port. Startup cleanup never submitted I/O or lent a view.
        void release() @trusted nothrow @nogc
        {
            if (storage is null)
                return;
            const released = munmap(storage.ptr, storage.length);
            assert(released == 0);
            storage = null;
        }
    }

    @safe nothrow @nogc unittest
    {
        Scratch scratch;
        assert(scratch.reserve(0) == Status.invalidArgument);
        assert(scratch.reserve(size_t.max) != Status.ok);
        assert(scratch.reserve(16_384) == Status.ok);
        assert(scratch.reserve(1) == Status.conflict);
        {
            scope first = scratch.slice(0, 4_096);
            scope last = scratch.slice(12_288, 16_384);
            foreach (value; first)
                assert(value == 0);
            foreach (value; last)
                assert(value == 0);
            first[0] = 211;
            last[$ - 1] = 173;
            assert(scratch.slice(0, 1)[0] == 211 && scratch.slice(16_383, 16_384)[0] == 173);
        }
        scratch.release();
        scratch.release();
        assert(scratch.reserve(4_096) == Status.ok);
        assert(scratch.slice(0, 1)[0] == 0);
        scratch.release();
    }
}
