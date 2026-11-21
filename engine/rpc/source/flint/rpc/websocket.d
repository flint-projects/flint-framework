/// RFC 6455 WebSocket framing and message bounds.
module flint.rpc.websocket;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.rpc.utf8 : Utf8State, utf8Valid;

@safe:

/// WebSocket version 13 handler route.
struct WebSocket
{
    /// Absolute HTTP GET path.
    string path;
}

package(flint.rpc):

enum maximumWsMessage = 4 * 1024 * 1024;
enum maximumControlBytes = 125;

enum WsOpcode : ubyte
{
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10
}

/// A complete data message or control frame. Control bytes are owned inline.
struct WsProgress
{
    size_t consumed;
    bool complete;
    WsOpcode opcode;
    Buffer payload;
    ubyte[maximumControlBytes] control;
    ubyte controlLength;
    ushort closeCode;
    Error error;
}

/// Keep one fragmented message and consume up to one message or immediate control frame.
struct WsDecoder
{
    private ubyte[14] header;
    private ubyte[maximumControlBytes] control;
    private ubyte headerUsed;
    private ubyte headerLength = 2;
    private ubyte maskIndex;
    private bool masked;
    private bool frameOpen;
    private bool finalFrame;
    private WsOpcode opcode;
    private size_t length;
    private size_t frameUsed;
    private bool fragmented;
    private WsOpcode messageOpcode;
    private Buffer message;
    private Utf8State utf8;
    private ushort failureCode;
    private Status failure;

    /// A server expects masked client frames. A client expects unmasked server frames.
    bool expectMasked = true;

    // dfmt off
    WsProgress feed(scope const(ubyte)[] wire, ref scope RequestArena arena,
            size_t limit = maximumWsMessage) scope nothrow @nogc
    {
        if (failureCode != 0)
            return fail(0, failureCode, failure, "WebSocket decoder failed");
        size_t consumed;
        while (consumed != wire.length)
        {
            if (!frameOpen)
            {
                takeHeader(wire, consumed);
                if (headerUsed != headerLength)
                    return WsProgress(consumed);
                const admitted = beginFrame(arena, limit);
                if (admitted.closeCode != 0)
                    return fail(consumed, admitted.closeCode, admitted.error.code, admitted.error.message);
            }

            const remaining = length - frameUsed;
            const available = wire.length - consumed;
            const chunk = remaining < available ? remaining : available;
            if (chunk != 0)
            {
                const accepted = save(wire[consumed .. consumed + chunk], arena, consumed);
                if (accepted.closeCode != 0)
                    return fail(accepted.consumed, accepted.closeCode, accepted.error.code, accepted.error.message);
                frameUsed += chunk;
                consumed += chunk;
            }
            if (frameUsed != length)
                return WsProgress(consumed);
            auto finished = endFrame(consumed);
            if (finished.closeCode != 0)
                return fail(consumed, finished.closeCode, finished.error.code, finished.error.message);
            if (finished.complete)
                return finished;
        }
        return WsProgress(consumed);
    }
    // dfmt on

    Error end() const scope nothrow @nogc
    {
        if (failureCode != 0)
            return Error(failure, "WebSocket decoder failed");
        if (fragmented || headerUsed != 0 || frameOpen)
            return Error(Status.invalidArgument, "truncated WebSocket frame");
        return Error.init;
    }

    private void takeHeader(scope const(ubyte)[] wire, ref size_t taken) scope nothrow @nogc
    {
        while (headerUsed < headerLength && taken < wire.length)
        {
            header[headerUsed++] = wire[taken++];
            if (headerUsed == 2)
            {
                const indicator = header[1] & 0x7f;
                const extended = indicator < 126 ? 0 : (indicator == 126 ? 2 : 8);
                headerLength = cast(ubyte)(2 + extended + ((header[1] & 0x80) != 0 ? 4 : 0));
            }
        }
    }

    private WsProgress beginFrame(ref scope RequestArena arena, size_t limit) scope nothrow @nogc
    {
        if ((header[0] & 0x70) != 0)
            return badHeader("WebSocket extension bits were not negotiated");
        masked = (header[1] & 0x80) != 0;
        if (masked != expectMasked)
            return badHeader("incorrect WebSocket masking direction");

        finalFrame = (header[0] & 0x80) != 0;
        opcode = cast(WsOpcode)(header[0] & 0x0f);
        const invalid = validateOpcode();
        if (invalid.closeCode != 0)
            return invalid;
        const size = frameLength();
        if (size > long.max)
            return badHeader("noncanonical WebSocket frame length");

        if (!isControl(opcode))
        {
            const previous = opcode == WsOpcode.continuation ? message.length : 0;
            const capacity = limit < maximumWsMessage ? limit : maximumWsMessage;
            if (previous > capacity || size > capacity - previous)
                return rejection(0, 1009, Status.resourceExhausted, "WebSocket message exceeds the byte limit");
            if (opcode != WsOpcode.continuation)
            {
                const stored = arena.allocate(0, 1);
                if (!stored.ok())
                    return rejection(0, 1011, stored.error.code, "WebSocket message storage unavailable");
                message = stored.value;
                messageOpcode = opcode;
                utf8 = Utf8State.init;
            }
        }
        length = cast(size_t) size;
        frameUsed = 0;
        frameOpen = true;
        return WsProgress.init;
    }

    private WsProgress validateOpcode() const scope nothrow @nogc
    {
        switch (opcode)
        {
        case WsOpcode.continuation:
            return fragmented ? WsProgress.init : badHeader("unexpected WebSocket continuation");
        case WsOpcode.text, WsOpcode.binary:
            return fragmented
                ? badHeader("WebSocket text interrupted by a data frame") : WsProgress.init;
        case WsOpcode.close, WsOpcode.ping, WsOpcode.pong:
            return finalFrame && (header[1] & 0x7f) <= maximumControlBytes
                ? WsProgress.init : badHeader("invalid WebSocket control frame length or fragmentation");
        default:
            return badHeader("unsupported WebSocket opcode");
        }
    }

    private ulong frameLength() scope nothrow @nogc
    {
        const uint indicator = header[1] & 0x7f;
        maskIndex = 2;
        if (indicator < 126)
            return indicator;
        const uint extended = indicator == 126 ? 2 : 8;
        ulong size;
        foreach (part; header[2 .. 2 + extended])
            size = (size << 8) | part;
        maskIndex += cast(ubyte) extended;
        return size < (indicator == 126 ? 126UL : 65_536UL) ? ulong.max : size;
    }

    // dfmt off
    private WsProgress save(scope const(ubyte)[] bytes, ref scope RequestArena arena,
            size_t consumed) scope nothrow @nogc
    {
        if (isControl(opcode))
        {
            foreach (index, value; bytes)
                control[frameUsed + index] = unmask(value, frameUsed + index);
            return WsProgress.init;
        }
        ubyte[4096] block;
        size_t first;
        while (first < bytes.length)
        {
            const left = bytes.length - first;
            const count = left < block.length ? left : block.length;
            foreach (index, value; bytes[first .. first + count])
            {
                const decoded = unmask(value, frameUsed + first + index);
                if (messageOpcode == WsOpcode.text && !utf8.accept(decoded))
                    return rejection(consumed + first + index + 1, 1007, Status.invalidArgument,
                            "invalid UTF-8 WebSocket text");
                block[index] = decoded;
            }
            const status = arena.append(message, block[0 .. count]);
            if (status != Status.ok)
            {
                const code = status == Status.outOfMemory ? 1009 : 1011;
                return rejection(consumed + first + count, cast(ushort) code, status,
                        "WebSocket message arena cannot grow");
            }
            first += count;
        }
        return WsProgress.init;
    }
    // dfmt on

    private ubyte unmask(ubyte value, size_t position) const scope pure nothrow @nogc
    {
        return masked ? cast(ubyte)(value ^ header[maskIndex + (position & 3)]) : value;
    }

    private WsProgress endFrame(size_t consumed) scope nothrow @nogc
    {
        frameOpen = false;
        headerUsed = 0;
        headerLength = 2;
        if (isControl(opcode))
        {
            if (opcode == WsOpcode.close && length != 0)
            {
                if (length == 1 || !validCloseCode(cast(ushort)((control[0] << 8) | control[1])))
                    return rejection(consumed, 1002, Status.invalidArgument, "invalid WebSocket close code");
                if (!utf8Valid(control[2 .. length]))
                    return rejection(consumed, 1007, Status.invalidArgument,
                            "invalid UTF-8 in WebSocket close reason");
            }
            WsProgress completed;
            completed.consumed = consumed;
            completed.complete = true;
            completed.opcode = opcode;
            completed.control = control;
            completed.controlLength = cast(ubyte) length;
            return completed;
        }

        fragmented = !finalFrame;
        if (fragmented)
            return WsProgress(consumed);
        if (messageOpcode == WsOpcode.text && !utf8.complete())
            return rejection(consumed, 1007, Status.invalidArgument, "truncated UTF-8 in WebSocket text");
        return WsProgress(consumed, true, messageOpcode, message);
    }

    private WsProgress fail(size_t consumed, ushort code, Status status, string diagnostic) scope nothrow @nogc
    {
        failureCode = code;
        failure = status;
        return rejection(consumed, code, status, diagnostic);
    }
}

private bool isControl(WsOpcode operation) pure nothrow @nogc
{
    return operation >= WsOpcode.close;
}

bool validCloseCode(ushort code) pure nothrow @nogc
{
    return (code >= 1000 && code <= 1014 && code != 1004 && code != 1005 && code != 1006) || (code >= 3000
            && code <= 4999);
}

private WsProgress rejection(size_t consumed, ushort code, Status status, string diagnostic) pure nothrow @nogc
{
    WsProgress failed;
    failed.consumed = consumed;
    failed.closeCode = code;
    failed.error = Error(status, diagnostic);
    return failed;
}

private WsProgress badHeader(string diagnostic) pure nothrow @nogc
{
    return rejection(0, 1002, Status.invalidArgument, diagnostic);
}

struct WsHeader
{
    ubyte[14] bytes;
    ubyte length;
}

/// Encode a server frame. Masking is required only for client frames.
Result!WsHeader serverHeader(WsOpcode opcode, size_t length, bool finalFrame = true) pure nothrow @nogc
{
    if (length > maximumWsMessage || (isControl(opcode) && (length > maximumControlBytes || !finalFrame)))
        return Result!WsHeader(WsHeader.init, Error(Status.invalidArgument, "invalid WebSocket response frame"));
    WsHeader result;
    result.bytes[0] = cast(ubyte)((finalFrame ? 0x80 : 0) | opcode);
    if (length < 126)
    {
        result.bytes[1] = cast(ubyte) length;
        result.length = 2;
    }
    else if (length <= ushort.max)
    {
        result.bytes[1] = 126;
        result.bytes[2] = cast(ubyte)(length >> 8);
        result.bytes[3] = cast(ubyte) length;
        result.length = 4;
    }
    else
    {
        result.bytes[1] = 127;
        const wireLength = cast(ulong) length;
        foreach (uint index; 0 .. 8)
            result.bytes[2 + index] = cast(ubyte)(wireLength >> ((7 - index) * 8));
        result.length = 10;
    }
    return Result!WsHeader(result);
}

/// Encode client frame metadata with the independently selected frame mask.
Result!WsHeader clientHeader(WsOpcode opcode, size_t length, ubyte[4] mask) pure nothrow @nogc
{
    auto frame = serverHeader(opcode, length);
    if (frame.ok())
    {
        frame.value.bytes[1] |= 0x80;
        const end = frame.value.length;
        frame.value.bytes[end .. end + mask.length] = mask[];
        frame.value.length += mask.length;
    }
    return frame;
}
