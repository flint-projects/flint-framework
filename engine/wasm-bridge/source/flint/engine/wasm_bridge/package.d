/// Caller-owned FLNT command encoding for native and browser guests.
module flint.engine.wasm_bridge;

import flint.arena : Error, Result, Status;
import flint.engine.wasm_bridge.internal : clearColor, permittedAttribute, rectangle, validUtf8, write16, write32;
import flint.engine.wasm_bridge.sys.borrow : BatchVisitor, borrowed, invalidMove, withBatch;

@safe:
nothrow:
@nogc:

/// Version of the scalar browser protocol.
enum abiVersion = 1U;

/// Operation identifiers in the little-endian wire format.
enum Opcode : ushort
{
    createElement = 1,
    setText,
    setAttribute,
    appendChild,
    remove,
    canvas,
    webgpu
}

/// Allowlisted host element tags.
enum TagName : ushort
{
    div = 1,
    span,
    button,
    input,
    canvas,
    paragraph
}

/// A node slot and the generation established by the host registry.
struct NodeHandle
{
    /// Registry index. Zero is reserved for the mount.
    uint index;
    /// Unique lifetime of the slot.
    uint generation;
}

/// Copied scalar data for an application-defined event.
struct EventRecord
{
    /// Target node slot.
    uint nodeIndex;
    /// Target node lifetime.
    uint nodeGeneration;
    /// Application event discriminator.
    uint type;
    /// Application data.
    int value;
}

/// Inspect one borrowed complete frame.
alias ByteVisitor = BatchVisitor;

private enum header = 32;
private enum recordHeader = 16;
private enum maximumField = 65_536;

/// Number of encoded bytes required for one text command, or zero for an oversized field.
uint textCommandBytes(size_t textBytes) pure
{
    if (textBytes > maximumField)
        return 0;
    return (recordHeader + 4 + cast(uint) textBytes + 7) & ~7U;
}

private bool valid(NodeHandle node) pure
{
    return node.index < 65_536 && node.generation != 0 && (node.index != 0 || node.generation == 1);
}

private Error invalid() pure
{
    return Error(Status.invalidArgument, "invalid FLNT command or buffer");
}

/// Bound commands to one caller-owned backing buffer.
struct CommandBuffer
{
@safe:
nothrow:
@nogc:

    private ubyte[] storage;
    private uint used = header;
    private uint count;
    private uint sequence;
    private uint epoch;

    @disable this(this);
    @disable void opAssign(CommandBuffer value);

    private this(return scope ubyte[] backing, uint session)
    {
        storage = backing;
        epoch = session;
        refresh();
    }

    /// Store the nonzero host epoch and establish the empty frame.
    static Result!CommandBuffer fromStorage(return scope ubyte[] callerStorage, uint sessionEpoch = 1)
    {
        if (callerStorage.length < header || callerStorage.length > 16 * 1024 * 1024 || sessionEpoch == 0)
            return Result!CommandBuffer(CommandBuffer.init, invalid());
        return Result!CommandBuffer(CommandBuffer(callerStorage, sessionEpoch));
    }

    /// Moving a borrowed frame would invalidate its synchronous lifetime guard.
    void opPostMove(scope const ref CommandBuffer original) scope
    {
        if (borrowed(original.storage))
            invalidMove();
    }

    /// Create a detached element with its host-issued slot generation.
    Error createElement(NodeHandle node, TagName tag) scope
    {
        if (node.index == 0 || tag < TagName.div || tag > TagName.paragraph)
            return invalid();
        ubyte[4] payload;
        write16(payload[], 0, tag);
        return append(Opcode.createElement, node, payload[], null, null);
    }

    /// Replace a node's text with valid UTF-8.
    Error setText(NodeHandle node, scope const(ubyte)[] utf8) scope
    {
        if (utf8.length > maximumField || !validUtf8(utf8))
            return invalid();
        ubyte[4] length;
        write32(length[], 0, cast(uint) utf8.length);
        return append(Opcode.setText, node, length[], utf8, null);
    }

    /// Set an allowlisted attribute with valid UTF-8 content.
    Error setAttribute(NodeHandle node, scope const(ubyte)[] name, scope const(ubyte)[] value) scope
    {
        if (name.length > maximumField || value.length > maximumField || !permittedAttribute(name) || !validUtf8(value))
            return invalid();
        ubyte[8] lengths;
        write32(lengths[], 0, cast(uint) name.length);
        write32(lengths[], 4, cast(uint) value.length);
        return append(Opcode.setAttribute, node, lengths[], name, value);
    }

    /// Attach or move a non-mount child.
    Error appendChild(NodeHandle parent, NodeHandle child) scope
    {
        if (!valid(child) || child.index == 0 || parent.index == child.index)
            return invalid();
        ubyte[8] payload;
        write32(payload[], 0, child.index);
        write32(payload[], 4, child.generation);
        return append(Opcode.appendChild, parent, payload[], null, null);
    }

    /// Remove a non-mount node and its descendants.
    Error remove(NodeHandle node) scope
    {
        return node.index == 0 ? invalid() : append(Opcode.remove, node, null, null, null);
    }

    /// Queue the v1 Canvas rectangle operation on a fixed 300 by 150 surface.
    Error canvas(NodeHandle node, scope const(ubyte)[] commands) scope
    {
        return rectangle(commands) ? append(Opcode.canvas, node, commands, null, null) : invalid();
    }

    /// Queue the v1 WebGPU clear-pass operation with normalized RGBA.
    Error webgpu(NodeHandle node, scope const(ubyte)[] commands) scope
    {
        return clearColor(commands) ? append(Opcode.webgpu, node, commands, null, null) : invalid();
    }

    /// Borrow exactly the initialized frame bytes for a synchronous observation.
    Error visit(scope ByteVisitor visitor) scope const
    {
        if (visitor is null || storage.length < header)
            return invalid();
        withBatch(storage[0 .. used], visitor);
        return Error.init;
    }

    /// Number of bytes ready for the host, including the frame header.
    uint usedBytes() scope const
    {
        return storage.length == 0 ? 0 : used;
    }

    /// Maximum bytes in the backing storage.
    uint capacityBytes() scope const
    {
        return cast(uint) storage.length;
    }

    /// Check that an owner can write a complete group of records without touching the current frame.
    Error checkRoom(size_t bytes) scope const
    {
        if (storage.length < header)
            return invalid();
        if (borrowed(storage))
            return Error(Status.conflict, "cannot change a borrowed FLNT frame");
        if (bytes > storage.length - used)
            return Error(Status.resourceExhausted, "FLNT command buffer is full");
        return Error.init;
    }

    /// Start the next frame. Active scoped visitors keep the current frame unchanged.
    void clear() scope
    {
        if (storage.length < header || borrowed(storage))
            return;
        used = header;
        count = 0;
        ++sequence;
        refresh();
    }

    private void refresh() scope
    {
        storage[0 .. header] = 0;
        write32(storage, 0, 0x544e4c46);
        write16(storage, 4, abiVersion);
        write32(storage, 8, used);
        write32(storage, 16, sequence);
        write32(storage, 20, epoch);
    }

    private Error append(Opcode opcode, NodeHandle node, scope const(ubyte)[] prefix,
            scope const(ubyte)[] first, scope const(ubyte)[] second) scope
    {
        if (!valid(node))
            return invalid();
        const payload = prefix.length + first.length + second.length;
        const bytes = (recordHeader + payload + 7) & ~cast(size_t) 7;
        const room = checkRoom(bytes);
        if (room.code != Status.ok)
            return room;
        auto record = storage[used .. used + bytes];
        write16(record, 0, opcode);
        write16(record, 2, 0);
        write32(record, 4, cast(uint) bytes);
        write32(record, 8, node.index);
        write32(record, 12, node.generation);
        size_t next = recordHeader;
        scope const(ubyte)[][3] parts = [prefix, first, second];
        foreach (part; parts)
        {
            foreach (value; part)
                record[next++] = value;
        }
        record[next .. $] = 0;
        used += cast(uint) bytes;
        ++count;
        write32(storage, 8, used);
        write32(storage, 12, count);
        return Error.init;
    }
}
