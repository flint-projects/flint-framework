/// Bounded scratch buffers and a checked protobuf-c descriptor bridge.
module flint.rpc.ffi.protobuf;

import core.stdc.stdlib : free, malloc;
import flint.arena : Error, Status;

@safe:

/// Immutable generated schema identity. Business messages never contain native pointers.
struct ProtoDescriptor;

/// A generated function returns the address of its static C descriptor.
extern (C) alias ProtoDescriptorFn = const(ProtoDescriptor)* function() @system nothrow @nogc;

package(flint.rpc) extern (C) struct ProtoField
{
    uint parent;
    uint number;
    ulong bits;
    double decimal = 0;
    size_t start;
    size_t length;
}

private extern (C) struct NativeArena
{
    ubyte* bytes;
    size_t capacity;
    size_t used;
    int exhausted;
}

version (FlintNativeProtobufC)
{
    private extern (C) @system nothrow @nogc
    {
        int flint_proto_pack_fields(const(ProtoDescriptor)*, scope const(ProtoField)*, size_t,
                scope const(ubyte)*, size_t, scope NativeArena*, scope ubyte*, size_t, scope size_t*);
        int flint_proto_unpack_fields(const(ProtoDescriptor)*, scope const(ubyte)*, size_t,
                scope NativeArena*, scope ProtoField*, size_t, scope size_t*);
    }
}

package(flint.rpc) alias ScratchFn = Error delegate(scope ubyte[]) @safe nothrow @nogc;

// SAFETY: Native bytes are exclusively owned during this synchronous call. The scoped delegate cannot retain
// the native slice, and this helper always frees the non-GC storage after the call.
@trusted package(flint.rpc) Error withScratch(size_t bytes, scope ScratchFn action) nothrow @nogc
{
    if (bytes == 0 || bytes > 33 * 1024 * 1024 || action is null)
        return Error(Status.invalidArgument, "invalid protobuf scratch request");
    auto memory = cast(ubyte*) malloc(bytes);
    if (memory is null)
        return Error(Status.outOfMemory, "protobuf native scratch unavailable");
    scope (exit)
        free(memory);
    return action(memory[0 .. bytes]);
}

// SAFETY: The generated supplier owns an immutable static descriptor. protobuf-c reads the scoped fields and
// byte payload and uses the exclusive scratch. Nothing from a D slice is retained beyond the synchronous call.
@trusted package(flint.rpc) Error packFields(ProtoDescriptorFn schema,
        scope const(ProtoField)[] fields, scope const(ubyte)[] bytes, scope ubyte[] scratch,
        scope ubyte[] wire, out size_t written) nothrow @nogc
{
    version (FlintNativeProtobufC)
    {
        if (schema is null || scratch.length == 0 || fields.length > 256)
            return Error(Status.invalidArgument, "invalid protobuf pack arguments");
        auto arena = NativeArena(scratch.ptr, scratch.length);
        const result = flint_proto_pack_fields(schema(), fields.ptr, fields.length, bytes.ptr,
                bytes.length, &arena, wire.ptr, wire.length, &written);
        if (result == -2 && wire.length == 0 && written != 0)
            return Error.init;
        if (result != 0 || written > wire.length)
            return Error(result == -2 ? Status.resourceExhausted : Status.invalidArgument, "protobuf pack failed");
        return Error.init;
    }
    else
        return Error(Status.unsupported, "pinned protobuf-c is unavailable");
}

// SAFETY: The generated supplier owns an immutable static descriptor. Native decoding uses only the scoped
// scratch and input spans. Output records contain scalar offsets that the D reader checks again before use.
@trusted package(flint.rpc) Error unpackFields(ProtoDescriptorFn schema, scope const(ubyte)[] wire,
        scope ubyte[] scratch, scope ProtoField[] fields, out size_t count) nothrow @nogc
{
    version (FlintNativeProtobufC)
    {
        if (schema is null || scratch.length == 0 || fields.length > 256)
            return Error(Status.invalidArgument, "invalid protobuf unpack arguments");
        auto arena = NativeArena(scratch.ptr, scratch.length);
        const result = flint_proto_unpack_fields(schema(), wire.ptr, wire.length, &arena,
                fields.ptr, fields.length, &count);
        if (result != 0 || count > fields.length)
            return Error(result == -2 ? Status.resourceExhausted : Status.invalidArgument, "protobuf unpack failed");
        return Error.init;
    }
    else
        return Error(Status.unsupported, "pinned protobuf-c is unavailable");
}
