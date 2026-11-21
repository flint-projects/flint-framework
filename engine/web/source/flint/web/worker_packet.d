/// Byte-only transport records for the full-D controller workers.
module flint.web.worker_packet;

import flint.arena : Buffer, RequestArena, Status;

@safe:
package(flint.web):

enum workerPacketBytes = 4096;
enum workerHeaderCount = 64;
enum workerCaptureCount = 16;

struct PacketSpan
{
    ushort first;
    ushort length;
}

struct PacketHeader
{
    PacketSpan name;
    PacketSpan value;
}

struct PacketCapture
{
    PacketSpan name;
    uint first;
    uint last;
}

struct WorkerRequest
{
    ulong identity;
    ubyte method;
    PacketSpan path;
    PacketSpan query;
    PacketSpan body;
    PacketHeader[workerHeaderCount] headers;
    PacketCapture[workerCaptureCount] captures;
    ubyte fields;
    ubyte captureCount;
    ushort used;
    ubyte[workerPacketBytes] bytes;

    bool appendBytes(scope const(ubyte)[] value, out PacketSpan destination) nothrow @nogc
    {
        if (value.length > bytes.length - used)
            return false;
        destination = PacketSpan(used, cast(ushort) value.length);
        bytes[used .. used + value.length] = value;
        used += cast(ushort) value.length;
        return true;
    }

    bool appendBuffer(Buffer buffer, ref scope RequestArena arena, out PacketSpan destination) nothrow @nogc
    {
        bool copied;
        const checked = arena.read(buffer, (scope const(ubyte)[] source) @safe nothrow @nogc {
            copied = appendBytes(source, destination);
        });
        return checked == Status.ok && copied;
    }

    const(ubyte)[] view(PacketSpan span) const return nothrow @nogc
    {
        return bytes[span.first .. span.first + span.length];
    }
}

/// Static public media spellings so copying a worker result needs no GC or live worker references.
enum WorkerMedia : ubyte
{
    none,
    json,
    text,
    textUtf8,
    binary,
    html,
    htmlUtf8
}

immutable string[7] workerMediaTypes = [
    "", "application/json", "text/plain", "text/plain; charset=utf-8", "application/octet-stream",
    "text/html", "text/html; charset=utf-8"
];

struct WorkerReply
{
    Status error;
    ushort status;
    WorkerMedia media;
    ushort length;
    ubyte[workerPacketBytes] body;
}
