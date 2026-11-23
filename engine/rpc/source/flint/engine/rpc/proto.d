/// Typed Protobuf dispatch and the checked generated-adapter interface.
module flint.engine.rpc.proto;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.engine.rpc.ffi.protobuf : ProtoField, packFields, unpackFields, withScratch;
import flint.engine.rpc.utf8 : utf8Valid;
import flint.engine.rpc.grpc : maximumMessageBytes;

public import flint.engine.rpc.ffi.protobuf : ProtoDescriptor, ProtoDescriptorFn;

@safe:

/// Serialize an explicitly generated Protobuf DTO into the supplied arena.
Result!Buffer encodeProto(T)(scope const ref T message, ref scope RequestArena arena) nothrow @nogc
{
    static if (is(typeof(T.flintEncode(message, arena))))
        return T.flintEncode(message, arena);
    else
        static assert(false, "encodeProto requires a generated Flint DTO");
}

/// Decode one generated DTO. The output is published only after a complete successful mapping.
Error decodeProto(T)(scope const(ubyte)[] wire, ref T message, ref scope RequestArena arena) nothrow @nogc
{
    static if (is(typeof(T.flintDecode(wire, message, arena))))
        return T.flintDecode(wire, message, arena);
    else
        static assert(false, "decodeProto requires a generated Flint DTO");
}

private enum fieldLimit = 256;

/// Bounded repeated values used by the generated adapters.
struct ProtoRepeated(T, uint capacity)
{
    /// Owned fixed slots.
    T[capacity] values;
    /// Number of populated slots.
    uint count;

    /// Append one generated value, preserving the existing values when full.
    bool add(scope const ref T next) scope nothrow @nogc
    {
        if (count >= capacity)
            return false;
        values[count++] = next;
        return true;
    }
}

/// Optional message or oneof-independent field presence in a generated DTO.
struct ProtoOptional(T)
{
    /// Whether the field is present on the wire.
    bool present;
    /// Supplied value.
    T value;
}

/// Numeric flattening cursor. Generated encoders use field numbers and parent references.
struct ProtoWriter
{
    private ProtoField[fieldLimit] fields;
    private Buffer[fieldLimit] objects;
    private size_t used;
    private size_t byteCount;

    /// Record an integral, Boolean or enum value.
    bool integer(uint parent, uint number, ulong bits) scope nothrow @nogc
    {
        if (!admit(parent, number))
            return false;
        fields[used - 1].bits = bits;
        return true;
    }

    /// Record a binary floating-point field.
    bool floating(uint parent, uint number, double decimal) scope nothrow @nogc
    {
        if (!admit(parent, number))
            return false;
        fields[used - 1].decimal = decimal;
        return true;
    }

    /// Record a scoped byte handle. Text is checked before the native encoder.
    bool bytes(uint parent, uint number, Buffer value, bool text = false) scope nothrow @nogc
    {
        if (value.length > maximumMessageBytes - byteCount || !admit(parent, number))
            return false;
        fields[used - 1].start = byteCount;
        fields[used - 1].length = value.length;
        fields[used - 1].bits = text;
        objects[used - 1] = value;
        byteCount += value.length;
        return true;
    }

    /// Record a nested message and return its parent index.
    uint nested(uint parent, uint number) scope nothrow @nogc
    {
        return admit(parent, number) ? cast(uint) used : 0;
    }

    private bool admit(uint parent, uint number) scope pure nothrow @nogc
    {
        if (used >= fields.length || number == 0 || parent > used)
            return false;
        fields[used++] = ProtoField(parent, number);
        return true;
    }

    /// Create the exact packed output with pinned protobuf-c.
    Result!Buffer pack(ProtoDescriptorFn schema, ref scope RequestArena arena) scope nothrow @nogc
    {
        Result!Buffer output;
        const size = byteCount * 2 + 8192 + used * 512;
        const packed = withScratch(size, (scope ubyte[] memory) @safe nothrow @nogc {
            auto input = memory[0 .. byteCount];
            auto scratch = memory[byteCount .. $];
            auto copied = stage(input, arena);
            if (copied.code != Status.ok)
                return copied;
            size_t needed;
            auto measured = packFields(schema, fields[0 .. used], input, scratch, null, needed);
            if (measured.code != Status.ok)
                return measured;
            if (needed > maximumMessageBytes)
                return Error(Status.resourceExhausted, "protobuf wire exceeds the message bound");
            output = arena.allocate(needed, 1);
            if (!output.ok() || needed == 0)
                return output.error;
            Error wrote;
            const accessed = arena.write(output.value, (scope ubyte[] encoded) @safe nothrow @nogc {
                size_t written;
                wrote = packFields(schema, fields[0 .. used], input, scratch, encoded, written);
                if (wrote.code == Status.ok && written != needed)
                    wrote = Error(Status.ioError, "protobuf size changed during packing");
            });
            return accessed == Status.ok ? wrote : Error(accessed, "protobuf output changed during packing");
        });
        return packed.code == Status.ok ? output : Result!Buffer(Buffer.init, packed);
    }

    private Error stage(scope ubyte[] output, ref scope RequestArena arena) scope nothrow @nogc
    {
        foreach (index; 0 .. used)
        {
            const handle = objects[index];
            if (handle == Buffer.init)
                continue;
            const offset = fields[index].start;
            const text = fields[index].bits != 0;
            bool valid = true;
            const read = arena.read(handle, (scope const(ubyte)[] value) @safe nothrow @nogc {
                if (text && !utf8Valid(value))
                    valid = false;
                else
                    output[offset .. offset + value.length] = value;
            });
            if (read != Status.ok || !valid)
                return Error(Status.invalidArgument, "invalid protobuf string or arena handle");
        }
        return Error.init;
    }
}

/// An immutable flattened view produced by pinned protobuf-c and scoped to a mapping call.
struct ProtoReader
{
    private const(ProtoField)[] fields;
    private const(ubyte)[] scratch;

    private this(return scope const(ProtoField)[] fields, return scope const(ubyte)[] scratch) pure nothrow @nogc
    {
        this.fields = fields;
        this.scratch = scratch;
    }

    /// Find the next record for a field. The cursor starts at zero and advances to its nested parent identifier.
    bool next(uint parent, uint number, ref size_t cursor) const scope pure nothrow @nogc
    {
        for (; cursor < fields.length; ++cursor)
        {
            const field = fields[cursor];
            if (field.parent == parent && field.number == number)
            {
                ++cursor;
                return true;
            }
        }
        return false;
    }

    /// Read an integral, Boolean or enum value by cursor.
    ulong integer(size_t cursor) const scope pure nothrow @nogc
    {
        return cursor == 0 || cursor > fields.length ? 0 : fields[cursor - 1].bits;
    }

    /// Read a floating-point value by cursor.
    double floating(size_t cursor) const scope pure nothrow @nogc
    {
        return cursor == 0 || cursor > fields.length ? 0 : fields[cursor - 1].decimal;
    }

    /// Copy native bytes into the caller arena before the provider scratch is released.
    Result!Buffer bytes(size_t cursor, ref scope RequestArena arena, bool text = false) const scope nothrow @nogc
    {
        if (cursor == 0 || cursor > fields.length)
            return Result!Buffer(Buffer.init, Error(Status.invalidArgument, "invalid protobuf field cursor"));
        const field = fields[cursor - 1];
        if (field.start > scratch.length || field.length > scratch.length - field.start)
            return Result!Buffer(Buffer.init, Error(Status.invalidArgument, "invalid native protobuf span"));
        const source = scratch[field.start .. field.start + field.length];
        if (text && !utf8Valid(source))
            return Result!Buffer(Buffer.init, Error(Status.invalidArgument, "invalid UTF-8 proto3 text"));
        return arena.copyIn(source);
    }
}

/// A generated body maps fields synchronously while the native arena remains borrowed.
alias ProtoMapping = Error delegate(scope const ref ProtoReader) @safe nothrow @nogc;

/// Decode a bounded message with a generated, scoped mapping.
Error readProto(ProtoDescriptorFn schema, scope const(ubyte)[] wire, scope ProtoMapping mapping) nothrow @nogc
{
    if (wire.length > maximumMessageBytes || mapping is null)
        return Error(Status.resourceExhausted, "protobuf message exceeds the input bound");
    return withScratch(65_536 + wire.length * 8, (scope ubyte[] scratch) @safe nothrow @nogc {
        ProtoField[fieldLimit] fields;
        size_t used;
        auto loaded = unpackFields(schema, wire, scratch, fields[], used);
        if (loaded.code != Status.ok)
            return loaded;
        scope view = ProtoReader(fields[0 .. used], scratch);
        return mapping(view);
    });
}
