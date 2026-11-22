/// Numeric, synchronous callbacks for the pinned nghttp2 session.
module flint.web.ffi.http2;

import flint.arena : Error, Result, Status;
import flint.web.stream : StreamField, validStreamFields;
import flint.web.wire : hasField, httpDate;

@safe:

/// Connection and stream events normalized by the C adapter.
package(flint.web) enum H2Event : uint
{
    begin = 16,
    field,
    body,
    end,
    closed,
    goaway,
    reset,
    headers
}

/// A decoder callback may accept, reject one stream with a protocol code, or abort the connection with -1.
package(flint.web) alias H2Events = int delegate(H2Event event, int stream, uint code,
        scope const(ubyte)[] name, scope const(ubyte)[] value) @safe nothrow @nogc;

/// One response chunk and indication that no additional body bytes remain.
package(flint.web) struct H2Chunk
{
    ptrdiff_t length = -1;
    bool eof;
}

/// Sized output borrow owned by the provider for the callback's duration.
package(flint.web) alias H2Body = H2Chunk delegate(int stream, scope ubyte[] value) @safe nothrow @nogc;

/// Scoped callbacks for a single serialization call.
package(flint.web) struct H2Output
{
    H2Events events;
    H2Body body;
}

private struct NativeSession;

private extern (C) struct NativeField
{
    const(char)* name;
    size_t nameLength;
    const(char)* value;
    size_t valueLength;
}

package(flint.web) enum holdStreamCredit = int.max;
package(flint.web) enum deferOutput = -2;
private ulong activeToken;
private H2Events activeEvents;
private H2Body activeBody;

version (FlintNativeNghttp2)
{
    private extern (C) alias NativeEvents = int function(ulong, uint, int, uint,
            scope const(ubyte)*, size_t, scope const(ubyte)*, size_t) @system nothrow @nogc;
    private extern (C) alias NativeBody = ptrdiff_t function(ulong token, int stream,
            scope ubyte* value, size_t length, scope int* eof) @system nothrow @nogc;

    private extern (C) @system nothrow @nogc
    {
        NativeSession* flint_h2_new_token(ulong token, uint maxStreams, NativeEvents sink, NativeBody body);
        int flint_h2_feed(NativeSession* session, scope const(ubyte)* data, size_t length);
        int flint_h2_send(NativeSession* session, scope ubyte* data, size_t capacity, scope size_t* written);
        int flint_h2_reply(NativeSession* session, int stream, uint status,
                scope const(char)* contentType, size_t typeLength, size_t bodyLength, int head);
        int flint_h2_stream_headers(NativeSession* session, int stream, uint status,
                scope const(NativeField)* fields, size_t count);
        int flint_h2_consume_stream(NativeSession* session, int stream, size_t count);
        int flint_h2_resume_stream(NativeSession* session, int stream);
        int flint_h2_reset(NativeSession* session, int stream, uint code);
        int flint_h2_drain(NativeSession* session);
        int flint_h2_pending(const NativeSession* session);
        int flint_h2_done(const NativeSession* session);
        void flint_h2_free(NativeSession* session);

        int relayEvent(ulong token, uint event, int stream, uint code, scope const(ubyte)* name,
                size_t nameLength, scope const(ubyte)* value, size_t valueLength)
        {
            if (token != activeToken || activeEvents is null || event < H2Event.begin || event > H2Event.headers)
                return -1;
            if ((name is null && nameLength != 0) || (value is null && valueLength != 0))
                return -1;
            return activeEvents(cast(H2Event) event, stream, code, nameLength == 0
                    ? null : name[0 .. nameLength], valueLength == 0 ? null : value[0 .. valueLength]);
        }

        ptrdiff_t relayBody(ulong token, int stream, scope ubyte* value, size_t length, scope int* eof)
        {
            if (token != activeToken || activeBody is null || stream <= 0)
                return -1;
            if (value is null || length > 4000 || eof is null)
                return -1;
            const result = activeBody(stream, value[0 .. length]);
            *eof = result.eof ? 1 : 0;
            return result.length;
        }
    }
}

/// One owner-core nghttp2 session; no provider pointer leaves this module.
package(flint.web) struct H2Session
{
    private NativeSession* native;
    private ulong token;

    @disable this(this);
    @disable void opAssign(H2Session replacement);

    // SAFETY: This creates one owned server session. C saves only its generation and static callback functions.
    Error open(ulong generation, uint streams) scope @trusted nothrow @nogc
    {
        if (generation == 0 || streams == 0 || streams > 100)
            return Error(Status.invalidArgument, "invalid HTTP/2 session bounds");
        if (native !is null)
            return Error(Status.conflict, "HTTP/2 session already open");
        version (FlintNativeNghttp2)
        {
            native = flint_h2_new_token(generation, streams, &relayEvent, &relayBody);
            if (native is null)
                return Error(Status.outOfMemory, "unable to create HTTP/2 session");
            token = generation;
            return Error.init;
        }
        else
            return Error(Status.unsupported, "pinned nghttp2 provider is unavailable");
    }

    // SAFETY: nghttp2 borrows the input and invokes the generation-checked relay synchronously on the owner.
    bool feed(scope const(ubyte)[] input, scope H2Events events) scope @trusted nothrow @nogc
    {
        version (FlintNativeNghttp2)
        {
            if (native is null || activeToken != 0 || events is null)
                return false;
            activeToken = token;
            activeEvents = events;
            scope (exit)
            {
                activeToken = 0;
                activeEvents = null;
            }
            return flint_h2_feed(native, input.ptr, input.length) == 0;
        }
        else
            return false;
    }

    // SAFETY: nghttp2 copies into the bounded output and borrows callback state only until this call returns.
    Result!size_t send(scope ubyte[] output, scope H2Output sink) scope @trusted nothrow @nogc
    {
        version (FlintNativeNghttp2)
        {
            if (native is null || activeToken != 0 || sink.events is null || sink.body is null || output.length == 0)
                return Result!size_t(0, Error(Status.invalidArgument));
            activeToken = token;
            activeEvents = sink.events;
            activeBody = sink.body;
            scope (exit)
            {
                activeToken = 0;
                activeEvents = null;
                activeBody = null;
            }
            size_t written;
            if (flint_h2_send(native, output.ptr, output.length, &written) != 0 || written > output.length)
                return Result!size_t(0, Error(Status.ioError));
            return Result!size_t(written);
        }
        else
            return Result!size_t(0, Error(Status.unsupported));
    }

    // SAFETY: The session is live and owner-confined. nghttp2 copies the scoped type and enqueues scalar metadata.
    bool reply(int stream, ushort status, scope string media, size_t length, bool head) scope @trusted nothrow @nogc
    {
        version (FlintNativeNghttp2)
            return native !is null && activeToken == 0 && stream > 0 && media.length <= 256
                && flint_h2_reply(native, stream, status, media.ptr, media.length, length, head) == 0;
        else
            return false;
    }

    // Every span is bounded and valid for this call. nghttp2 copies all names and values before returning,
    // so the stack digits and borrowed media, date and allow text are not retained; content comes later
    // SAFETY: from the generation-checked body relay. The live owner-local session is outside callbacks.
    bool respond(int stream, ushort status, scope const(char)[] media, size_t length,
            scope const(char)[] date, scope const(char)[] allow) scope @trusted nothrow @nogc
    {
        version (FlintNativeNghttp2)
        {
            if (native is null || activeToken != 0 || stream <= 0 || media.length > 256
                    || date.length > 64 || allow.length > 64)
                return false;
            char[20] digits;
            size_t first = digits.length;
            size_t remaining = length;
            do
            {
                digits[--first] = cast(char)('0' + remaining % 10);
                remaining /= 10;
            }
            while (remaining != 0);
            NativeField[4] fields;
            size_t count;
            // RFC 9110 sections 8.6 and 15.4.5: 204 never carries Content-Length, and a 304 frames no body.
            if (status != 204 && status != 304)
                fields[count++] = NativeField("content-length".ptr, 14, &digits[first], digits.length - first);
            if (media.length != 0)
                fields[count++] = NativeField("content-type".ptr, 12, media.ptr, media.length);
            if (date.length != 0)
                fields[count++] = NativeField("date".ptr, 4, date.ptr, date.length);
            if (allow.length != 0)
                fields[count++] = NativeField("allow".ptr, 5, allow.ptr, allow.length);
            return flint_h2_stream_headers(native, stream, status, fields.ptr, count) == 0;
        }
        else
            return false;
    }

    // A response head gains the worker's Date field unless the application supplied one, while the
    // provider's 32-field table has room. Trailers (status 0) are passed through unchanged.
    // SAFETY: A live owner-local session validates the bounded field spans. The provider copies the
    // response fields or makes a native-owned trailer record before returning. No D pointer is retained.
    bool streamHeaders(int stream, ushort status, scope const(StreamField)[] fields) scope @trusted nothrow @nogc
    {
        version (FlintNativeNghttp2)
        {
            if (native is null || activeToken != 0 || stream <= 0 || !validStreamFields(fields, false))
                return false;
            NativeField[32] converted;
            foreach (index, ref field; fields)
                converted[index] = NativeField(field.name.ptr, field.name.length, field.value.ptr, field.value.length);
            size_t count = fields.length;
            if (status != 0 && count < converted.length && !hasField(fields, "date"))
            {
                const date = httpDate();
                converted[count++] = NativeField("date".ptr, 4, date.ptr, date.length);
            }
            return flint_h2_stream_headers(native, stream, status, converted.ptr, count) == 0;
        }
        else
            return false;
    }

    // SAFETY: Credits only bytes the owner drained for the live stream. The scalar operation cannot invoke callbacks.
    bool consumeStream(int stream, size_t count) scope @trusted nothrow @nogc
    {
        version (FlintNativeNghttp2)
            return native !is null && activeToken == 0 && stream > 0 && count > 0
                && flint_h2_consume_stream(native, stream, count) == 0;
        else
            return false;
    }

    // SAFETY: Mark a live stream's DATA provider available without passing a pointer into D storage.
    bool resumeStream(int stream) scope @trusted nothrow @nogc
    {
        version (FlintNativeNghttp2)
            return native !is null && activeToken == 0 && stream > 0 && flint_h2_resume_stream(native, stream) == 0;
        else
            return false;
    }

    // SAFETY: The owner enqueues a stream reset using only validated scalar values, outside provider callbacks.
    bool reset(int stream, uint code) scope @trusted nothrow @nogc
    {
        version (FlintNativeNghttp2)
            return native !is null && activeToken == 0 && stream > 0 && flint_h2_reset(native, stream, code) == 0;
        else
            return false;
    }

    // SAFETY: The live owner-local session enqueues GOAWAY without retaining any D data.
    bool drain() scope @trusted nothrow @nogc
    {
        version (FlintNativeNghttp2)
            return native !is null && activeToken == 0 && flint_h2_drain(native) == 0;
        else
            return false;
    }

    // SAFETY: A live owner-local query exposes a boolean and cannot invoke a callback.
    bool pending() const scope @trusted nothrow @nogc
    {
        version (FlintNativeNghttp2)
            return native !is null && flint_h2_pending(native) != 0;
        else
            return false;
    }

    // SAFETY: A live owner-local query returns whether nghttp2 still needs transport; no callback can run.
    bool done() const scope @trusted nothrow @nogc
    {
        version (FlintNativeNghttp2)
            return native !is null && flint_h2_done(native) != 0;
        else
            return false;
    }

    // SAFETY: The owner releases its unique session after all provider calls and transport completions are done.
    void close() scope @trusted nothrow @nogc
    {
        version (FlintNativeNghttp2)
        {
            if (native !is null && activeToken == 0)
            {
                flint_h2_free(native);
                native = null;
                token = 0;
            }
        }
    }
}
