/// Owner-local TLS transport. Applications receive only HTTP plaintext completions.
module flint.web.transport;

import core.time : MonoTime, ticksToNSecs;
import flint.arena : Error, Status;
import flint.conc : Context, Deadline;
import flint.reactor : AcceptDelegate, Completion, CompletionDelegate, ConnectionId, ReadDelegate,
    Reactor, TaskContext, TaskDelegate;
import flint.web.ffi.tls : TlsProgress, TlsServer, TlsSession;
import flint.web.sys.ownership : releaseBytes, reserveBytes;
import flint.web.types : ServerOptions;

@safe:
package(flint.web):

private enum ioBytes = 4096;

private enum Phase : ubyte
{
    handshake,
    plaintext,
    flushing,
    stopping
}

private struct SecureSocket
{
    TlsTransport transport;
    TaskDelegate work;
    uint index;
    ConnectionId id;
    TlsSession session;
    Phase phase;
    Status closeStatus;
    Deadline handshakeDeadline;
    bool readPending;
    bool writePending;
    bool queued;
    bool driving;
    size_t cipherCount;
    ReadDelegate receive;
    size_t readLimit;
    Context readContext;
    CompletionDelegate send;
    Context writeContext;
    ubyte[] payload;
    size_t length;
    size_t offset;

    void resume() nothrow @nogc
    {
        transport.resume(index);
    }
}

/// TLS mode retains raw and application I/O through their final owner-loop callbacks.
final class TlsTransport
{
    private ServerOptions limits;
    private Context root;
    private AcceptDelegate http1;
    private AcceptDelegate http2;
    private SecureSocket[] sockets;
    private TlsServer credentials;

    this(ServerOptions limits, Context root, AcceptDelegate http1, AcceptDelegate http2)
    {
        this.limits = limits;
        this.root = root;
        this.http1 = http1;
        this.http2 = http2;
        sockets = new SecureSocket[limits.cores * limits.maxConnectionsPerCore];
        foreach (index, ref socket; sockets)
        {
            socket.transport = this;
            socket.index = cast(uint) index;
            socket.work = &socket.resume;
        }
    }

    Error open() nothrow @nogc
    {
        return credentials.open(limits.tlsCertificateFile, limits.tlsPrivateKeyFile, http2 !is null);
    }

    void accept(ConnectionId id) nothrow @nogc
    {
        auto socket = slot(id);
        if (socket is null || socket.id.generation != 0 || root.cancelled() || !credentials.accept(socket.session))
        {
            Reactor.current().close(id);
            return;
        }
        socket.id = id;
        socket.phase = Phase.handshake;
        socket.handshakeDeadline = following(limits.headerTimeoutNanos);
        socket.payload = reserveBytes(ioBytes);
        if (socket.payload.length != ioBytes)
        {
            abort(socket, Status.outOfMemory);
            return;
        }
        drive(socket);
    }

    Status read(ConnectionId id, size_t maximum, Context context, ReadDelegate receiver) nothrow @nogc
    {
        auto socket = active(id);
        if (socket is null || socket.phase != Phase.plaintext || maximum == 0 || maximum > ioBytes || receiver is null)
            return Status.invalidArgument;
        if (socket.receive !is null)
            return Status.conflict;
        if (!schedule(socket))
            return Status.unavailable;
        socket.receive = receiver;
        socket.readContext = context;
        socket.readLimit = maximum;
        return Status.ok;
    }

    Status write(ConnectionId id, scope const(ubyte)[] bytes, Context context, CompletionDelegate sender) nothrow @nogc
    {
        auto socket = active(id);
        if (socket is null || socket.phase != Phase.plaintext || bytes.length == 0
                || bytes.length > ioBytes || sender is null)
            return Status.invalidArgument;
        if (socket.send !is null)
            return Status.conflict;
        if (!schedule(socket))
            return Status.unavailable;
        socket.payload[0 .. bytes.length] = bytes;
        socket.send = sender;
        socket.writeContext = context;
        socket.length = bytes.length;
        socket.offset = 0;
        return Status.ok;
    }

    void close(ConnectionId id) nothrow @nogc
    {
        auto socket = active(id);
        if (socket is null || socket.phase >= Phase.flushing)
            return;
        if (socket.phase == Phase.plaintext && socket.send is null && socket.session.shutdown())
        {
            socket.closeStatus = Status.cancelled;
            socket.phase = Phase.flushing;
            if (schedule(socket))
                return;
        }
        abort(socket, Status.cancelled);
    }

    void release() nothrow @nogc
    {
        foreach (ref socket; sockets)
        {
            if (socket.id.generation != 0)
                retire(&socket);
        }
        credentials.close();
        root = Context.init;
    }

    private SecureSocket* slot(ConnectionId id) nothrow @nogc
    {
        if (id.ownerCore >= limits.cores || id.slot >= limits.maxConnectionsPerCore)
            return null;
        return &sockets[id.ownerCore * limits.maxConnectionsPerCore + id.slot];
    }

    private SecureSocket* active(ConnectionId id) nothrow @nogc
    {
        auto socket = slot(id);
        return socket !is null && socket.id == id && id.generation != 0 ? socket : null;
    }

    private bool schedule(SecureSocket* socket) nothrow @nogc
    {
        if (socket.queued || socket.driving)
            return true;
        const posted = Reactor.current().postWith(socket.id.ownerCore, socket.work, TaskContext.init);
        if (posted.code != Status.ok)
            return false;
        socket.queued = true;
        return true;
    }

    private void resume(uint index) nothrow @nogc
    {
        auto socket = &sockets[index];
        socket.queued = false;
        if (socket.id.generation != 0)
            drive(socket);
    }

    private void drive(SecureSocket* socket) nothrow @nogc
    {
        if (socket.driving)
            return;
        socket.driving = true;
        bool resumeLater;
        scope (exit)
        {
            socket.driving = false;
            if (resumeLater && socket.id.generation != 0 && socket.phase == Phase.plaintext && !schedule(socket))
                abort(socket, Status.unavailable);
        }
        if (socket.phase == Phase.handshake)
            negotiate(socket);
        if (socket.phase == Phase.plaintext)
            resumeLater = applications(socket);
        if (socket.phase == Phase.flushing)
        {
            if (!socket.session.pending() && !socket.writePending)
                abort(socket, socket.closeStatus);
        }
        if (socket.phase < Phase.stopping)
            sendCiphertext(socket);
        if (socket.phase == Phase.stopping)
            closeWhenDrained(socket);
    }

    private void negotiate(SecureSocket* socket) nothrow @nogc
    {
        final switch (socket.session.handshake())
        {
        case TlsProgress.ready:
            socket.phase = Phase.plaintext;
            if (socket.session.useH2() && http2 !is null)
                http2(socket.id);
            else
                http1(socket.id);
            break;
        case TlsProgress.waiting:
            awaitInput(socket, root.withDeadline(socket.handshakeDeadline));
            break;
        case TlsProgress.eof:
        case TlsProgress.failed:
            flushFailure(socket, Status.ioError);
            break;
        }
    }

    private bool applications(SecureSocket* socket) nothrow @nogc
    {
        for (uint iteration; iteration < 16 && socket.phase == Phase.plaintext; ++iteration)
        {
            const sent = processWrite(socket);
            if (socket.phase != Phase.plaintext)
                return false;
            const read = processRead(socket);
            if (!sent && !read)
                return false;
        }
        return socket.phase == Phase.plaintext;
    }

    private bool processWrite(SecureSocket* socket) nothrow @nogc
    {
        if (socket.send is null || socket.writePending || socket.session.pending())
            return false;
        const checked = socket.writeContext.check();
        if (checked.code != Status.ok)
        {
            abort(socket, checked.code);
            return false;
        }
        if (socket.offset == socket.length)
        {
            const sender = socket.send;
            socket.send = null;
            socket.writeContext = Context.init;
            sender(Completion(socket.id, Status.ok, socket.length));
            return true;
        }
        const result = socket.session.write(socket.payload[socket.offset .. socket.length]);
        return handleWrite(socket, result.progress, result.bytes);
    }

    private bool handleWrite(SecureSocket* socket, TlsProgress progress, size_t bytes) nothrow @nogc
    {
        final switch (progress)
        {
        case TlsProgress.ready:
            if (bytes == 0)
            {
                abort(socket, Status.ioError);
                return false;
            }
            socket.offset += bytes;
            return true;
        case TlsProgress.waiting:
            awaitInput(socket, socket.writeContext);
            return false;
        case TlsProgress.eof:
        case TlsProgress.failed:
            flushFailure(socket, Status.ioError);
            return false;
        }
    }

    private bool processRead(SecureSocket* socket) nothrow @nogc
    {
        if (socket.receive is null)
            return false;
        const checked = socket.readContext.check();
        if (checked.code == Status.cancelled)
        {
            completeRead(socket, Status.cancelled, null);
            return true;
        }
        if (checked.code != Status.ok)
        {
            abort(socket, checked.code);
            return false;
        }
        ubyte[ioBytes] bytes;
        const result = socket.session.read(bytes[0 .. socket.readLimit]);
        final switch (result.progress)
        {
        case TlsProgress.ready:
            completeRead(socket, Status.ok, bytes[0 .. result.bytes]);
            return true;
        case TlsProgress.waiting:
            awaitInput(socket, socket.readContext);
            return false;
        case TlsProgress.eof:
            if (socket.session.shutdown())
                flushFailure(socket, Status.cancelled);
            else
                abort(socket, Status.cancelled);
            return false;
        case TlsProgress.failed:
            flushFailure(socket, Status.ioError);
            return false;
        }
    }

    private void completeRead(SecureSocket* socket, Status status, scope const(ubyte)[] bytes) nothrow @nogc
    {
        const receiver = socket.receive;
        socket.receive = null;
        socket.readContext = Context.init;
        receiver(Completion(socket.id, status, bytes.length), bytes);
    }

    private void awaitInput(SecureSocket* socket, Context context) nothrow @nogc
    {
        if (socket.readPending || socket.phase >= Phase.flushing)
            return;
        const queued = Reactor.current().readWith(socket.id, ioBytes, context, &receivedCiphertext);
        if (queued.ok())
            socket.readPending = true;
        else
            abort(socket, queued.error.code);
    }

    private void receivedCiphertext(Completion completion, scope const(ubyte)[] bytes) nothrow @nogc
    {
        auto socket = active(completion.connection);
        if (socket is null || !socket.readPending)
            return;
        socket.readPending = false;
        if (socket.phase == Phase.stopping)
        {
            closeWhenDrained(socket);
            return;
        }
        if (completion.status == Status.cancelled && socket.phase == Phase.plaintext)
        {
            if (socket.receive !is null)
                completeRead(socket, Status.cancelled, null);
            drive(socket);
            return;
        }
        if (completion.status != Status.ok || bytes.length == 0)
        {
            abort(socket, completion.status == Status.ok ? Status.cancelled : completion.status);
            return;
        }
        if (socket.phase < Phase.flushing && !socket.session.receive(bytes))
        {
            abort(socket, Status.ioError);
            return;
        }
        drive(socket);
    }

    private void sendCiphertext(SecureSocket* socket) nothrow @nogc
    {
        if (socket.writePending || !socket.session.pending())
            return;
        ubyte[ioBytes] output;
        const count = socket.session.send(output[]);
        if (count == 0)
        {
            abort(socket, Status.ioError);
            return;
        }
        const queued = Reactor.current().writeWith(socket.id, output[0 .. count],
                cipherDeadline(socket), &sentCiphertext);
        if (queued.ok())
        {
            socket.writePending = true;
            socket.cipherCount = count;
        }
        else
            abort(socket, queued.error.code);
    }

    private Context cipherDeadline(SecureSocket* socket) nothrow @nogc
    {
        if (socket.phase == Phase.handshake)
            return root.withDeadline(socket.handshakeDeadline);
        if (socket.phase == Phase.plaintext && socket.send !is null)
            return socket.writeContext;
        return Context.init.withDeadline(following(limits.idleTimeoutNanos));
    }

    private void sentCiphertext(Completion completion) nothrow @nogc
    {
        auto socket = active(completion.connection);
        if (socket is null || !socket.writePending)
            return;
        socket.writePending = false;
        if (completion.status != Status.ok || completion.bytes != socket.cipherCount)
        {
            abort(socket, completion.status == Status.ok ? Status.ioError : completion.status);
            return;
        }
        drive(socket);
    }

    private void flushFailure(SecureSocket* socket, Status status) nothrow @nogc
    {
        socket.closeStatus = status;
        socket.phase = Phase.flushing;
        if (!socket.session.pending() && !socket.writePending)
            abort(socket, status);
    }

    private void abort(SecureSocket* socket, Status status) nothrow @nogc
    {
        if (socket.phase != Phase.stopping)
        {
            socket.phase = Phase.stopping;
            socket.closeStatus = status;
            Reactor.current().close(socket.id);
        }
        closeWhenDrained(socket);
    }

    private void closeWhenDrained(SecureSocket* socket) nothrow @nogc
    {
        if (socket.id.generation == 0 || socket.readPending || socket.writePending || socket.queued)
            return;

        const id = socket.id;
        const status = socket.closeStatus;
        const reader = socket.receive;
        const writer = socket.send;
        retire(socket);
        if (reader !is null)
            reader(Completion(id, status, 0), null);
        if (writer !is null)
            writer(Completion(id, status, 0));
    }

    private void retire(SecureSocket* socket) nothrow @nogc
    {
        socket.receive = null;
        socket.send = null;
        socket.readContext = Context.init;
        socket.writeContext = Context.init;
        socket.session.close();
        releaseBytes(socket.payload);
        socket.id = ConnectionId.init;
        socket.readPending = false;
        socket.writePending = false;
        socket.queued = false;
        socket.phase = Phase.stopping;
    }
}

private Deadline following(long delta) nothrow @nogc
{
    const timestamp = ticksToNSecs(MonoTime.currTime.ticks);
    return Deadline(delta >= long.max - timestamp ? long.max - 1 : timestamp + delta);
}

Status readPlain(TlsTransport tls, ConnectionId id, size_t limit, Context context, ReadDelegate done) nothrow @nogc
{
    return tls is null ? Reactor.current().readWith(id, limit, context, done).error.code
        : tls.read(id, limit, context, done);
}

Status writePlain(TlsTransport tls, ConnectionId id, scope const(ubyte)[] bytes, Context context,
        CompletionDelegate done) nothrow @nogc
{
    return tls is null ? Reactor.current().writeWith(id, bytes, context, done).error.code
        : tls.write(id, bytes, context, done);
}

void closePlain(TlsTransport tls, ConnectionId id) nothrow @nogc
{
    if (tls is null)
        Reactor.current().close(id);
    else
        tls.close(id);
}
