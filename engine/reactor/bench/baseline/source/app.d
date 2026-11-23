module app;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.stdio : printf;
import core.stdc.errno : EAGAIN, ECANCELED, EINTR, errno;
import core.sys.posix.sys.socket : recv, send, sockaddr, socklen_t;
import core.sys.posix.unistd : close;
import core.thread.osthread : Thread;
import core.time : MonoTime, msecs;
import probe_workload : cancellationMarker, connectionLimit, maxPayload, runWorkloads, useUring;
import std.exception : enforce;
import std.socket : InternetAddress, TcpSocket;

version (OSX)
{
    // The kqueue equivalent of the epoll provider baseline (ADR-024).
    import core.sys.darwin.sys.event : EV_ADD, EV_DELETE, EVFILT_READ, EVFILT_WRITE, kevent64, kevent64_s, kqueue;
    import core.sys.posix.fcntl : FD_CLOEXEC, F_GETFL, F_SETFD, F_SETFL, O_NONBLOCK, fcntl;
    import core.sys.posix.pthread : pthread_self, pthread_t;
    import core.sys.posix.sys.socket : SOL_SOCKET, SO_NOSIGPIPE, accept, setsockopt;
    import core.sys.posix.time : timespec;

    private enum sendFlags = 0;

    private struct ThreadBasicInfo
    {
        int userSeconds, userMicros, systemSeconds, systemMicros;
        int[6] rest;
    }

    private extern (C) nothrow @nogc
    {
        uint pthread_mach_thread_np(pthread_t thread);
        int thread_info(uint thread, int flavor, ThreadBasicInfo* info, uint* count);
    }

    // Darwin has no CPU affinity API on Apple silicon.
    private bool pinCurrentThread()
    {
        return false;
    }

    private struct Usage
    {
        long cpuMicros;
        long voluntary;
        long involuntary;
    }

    // Mach thread CPU time; Darwin exposes no per-thread context-switch counts.
    private Usage threadUsage()
    {
        ThreadBasicInfo info;
        uint count = ThreadBasicInfo.sizeof / int.sizeof;
        enforce(thread_info(pthread_mach_thread_np(pthread_self()), 3, &info, &count) == 0, "thread usage unavailable");
        const seconds = cast(long) info.userSeconds + info.systemSeconds;
        return Usage(seconds * 1_000_000 + info.userMicros + info.systemMicros);
    }
}
else
{
    import core.sys.linux.sched : CPU_ISSET, CPU_SET, cpu_set_t, sched_getaffinity, sched_setaffinity;
    import core.sys.linux.epoll : EPOLLIN, EPOLLOUT, EPOLLRDHUP, EPOLL_CLOEXEC, EPOLL_CTL_ADD,
        EPOLL_CTL_MOD, epoll_create1, epoll_ctl, epoll_event, epoll_wait;
    import core.sys.posix.fcntl : O_CLOEXEC, O_NONBLOCK;
    import core.sys.posix.sys.resource : RUSAGE_THREAD, getrusage, rusage;
    import core.sys.posix.sys.socket : MSG_NOSIGNAL;

    private enum sendFlags = MSG_NOSIGNAL;

    private extern (C) int accept4(int descriptor, sockaddr* addr, socklen_t* len, int flags) nothrow @nogc;

    private bool pinCurrentThread()
    {
        cpu_set_t allowed;
        if (sched_getaffinity(0, allowed.sizeof, &allowed) != 0)
            return false;
        foreach (cpu; 0 .. cpu_set_t.sizeof * 8)
        {
            if (CPU_ISSET(cpu, &allowed))
            {
                cpu_set_t preferred;
                CPU_SET(cpu, &preferred);
                return sched_setaffinity(0, preferred.sizeof, &preferred) == 0;
            }
        }
        return false;
    }

    private struct Usage
    {
        long cpuMicros;
        long voluntary;
        long involuntary;
    }

    private Usage threadUsage()
    {
        rusage usage;
        enforce(getrusage(RUSAGE_THREAD, &usage) == 0, "thread usage unavailable");
        return Usage((usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000
                + usage.ru_utime.tv_usec + usage.ru_stime.tv_usec, usage.ru_nvcsw, usage.ru_nivcsw);
    }
}

version (FlintNativeLiburing)
{
    private extern (C) nothrow @nogc
    {
        int flint_uring_open(uint entries, void** ring);
        void flint_uring_close(void* ring);
        int flint_uring_accept(void* ring, int descriptor, ulong token);
        int flint_uring_recv(void* ring, int fd, ubyte* buffer, uint length, ulong token);
        int flint_uring_send(void* ring, int fd, const(ubyte)* buffer, uint length, ulong token);
        int flint_uring_cancel(void* ring, ulong token);
        int flint_uring_wait(void* ring, uint millis, ulong* token, int* result);
    }
}

private enum listenToken = 1UL;

private enum Phase
{
    receive,
    transmit,
    cancel
}

private struct Peer
{
    int fd = -1;
    uint generation;
    Phase phase;
    size_t count;
    size_t emitted;
    bool pending;
    bool cancelling;
    MonoTime cancelAt;
    ubyte[maxPayload] buffer;
}

private struct DirectServer
{
    Peer[] peers;
    int listener;
    int poller = -1;
    shared bool finished;

    version (FlintNativeLiburing)
    {
        void* ring;
        bool listening;
        bool acceptCancelled;
        uint cancelAcks;
    }

    void run()
    {
        const pinned = pinCurrentThread();
        const before = threadUsage();
        version (OSX)
            runKqueue();
        else version (FlintNativeLiburing)
        {
            if (useUring())
                runUring();
            else
                runEpoll();
        }
        else
            runEpoll();
        const after = threadUsage();
        uint outstanding;
        foreach (ref peer; peers)
        {
            if (peer.fd >= 0 || peer.pending)
                ++outstanding;
        }
        enforce(outstanding == 0, "direct provider retained operations after shutdown");
        const cpuMicros = after.cpuMicros - before.cpuMicros;
        version (OSX)
            const backend = "kqueue";
        else
            const backend = useUring() ? "ioUring" : "epoll";
        const pinnedText = pinned ? "true" : "false";
        printf("backend=%.*s pinned=%.*s worker_cpu_ns=%lld voluntary_switches=%ld involuntary_switches=%ld "
                ~ "outstanding=%u\n", cast(int) backend.length,
                backend.ptr, cast(int) pinnedText.length, pinnedText.ptr,
                cast(long)(cpuMicros * 1_000), cast(long)(after.voluntary - before.voluntary),
                cast(long)(after.involuntary - before.involuntary), outstanding);
    }

    void stop()
    {
        atomicStore(finished, true);
    }

    private size_t admit(int fd)
    {
        foreach (index, ref peer; peers)
        {
            if (peer.fd >= 0)
                continue;
            peer.fd = fd;
            ++peer.generation;
            return index;
        }
        close(fd);
        return peers.length;
    }

    private void retire(ref Peer peer)
    {
        enforce(!peer.pending, "direct provider released in-flight memory");
        close(peer.fd);
        const generation = peer.generation;
        peer = Peer.init;
        peer.generation = generation;
    }

    private ulong token(size_t index) const
    {
        return (cast(ulong) peers[index].generation << 32) | index;
    }

    private bool matches(ulong tag, uint index) const
    {
        return index < peers.length && peers[index].fd >= 0 && token(index) == tag;
    }

    private void progress(ref Peer peer, ptrdiff_t result)
    {
        enforce(result >= 0, "direct provider reported an invalid byte count");
        if (peer.phase == Phase.receive)
        {
            if (result == 0)
                retire(peer);
            else if (result == 1 && peer.buffer[0] == cancellationMarker)
            {
                peer.phase = Phase.cancel;
                peer.cancelAt = MonoTime.currTime + 25.msecs;
            }
            else
            {
                peer.count = cast(size_t) result;
                peer.emitted = 0;
                peer.phase = Phase.transmit;
            }
        }
        else
        {
            enforce(peer.phase == Phase.transmit && result > 0, "unexpected direct send completion");
            peer.emitted += result;
            if (peer.emitted == peer.count)
                peer.phase = Phase.receive;
        }
    }

    version (OSX)
    {
        private void change(int descriptor, short filter, ushort flags, ulong tag)
        {
            auto request = kevent64_s(cast(ulong) descriptor, filter, flags, 0, 0, tag);
            enforce(kevent64(poller, &request, 1, null, 0, 0, null) == 0, "direct kqueue registration failed");
        }

        private void runKqueue()
        {
            poller = kqueue();
            enforce(poller >= 0, "direct kqueue setup failed");
            scope (exit)
                close(poller);
            change(listener, EVFILT_READ, EV_ADD, listenToken);

            kevent64_s[64] events;
            const wait = timespec(0, 5_000_000);
            while (!atomicLoad(finished))
            {
                const ready = kevent64(poller, null, 0, events.ptr, cast(int) events.length, 0, &wait);
                if (ready < 0 && errno == EINTR)
                    continue;
                enforce(ready >= 0, "direct kqueue wait failed");
                foreach (ref event; events[0 .. ready])
                    handleKqueue(event.udata);

                const now = MonoTime.currTime;
                foreach (ref peer; peers)
                    if (peer.fd >= 0 && peer.phase == Phase.cancel && peer.cancelAt <= now)
                        retire(peer);
            }
            foreach (ref peer; peers)
                if (peer.fd >= 0)
                    retire(peer);
        }

        private void acceptKqueue()
        {
            const fd = accept(listener, null, null);
            if (fd < 0)
            {
                enforce(errno == EAGAIN || errno == EINTR, "direct accept failed");
                return;
            }
            const int enabled = 1;
            enforce(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0, "direct accepted socket setup failed");
            enforce(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, "direct accepted socket setup failed");
            enforce(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, enabled.sizeof) == 0,
                    "direct accepted socket setup failed");
            const index = admit(fd);
            if (index < peers.length)
                change(fd, EVFILT_READ, EV_ADD, token(index));
        }

        private void handleKqueue(ulong tag)
        {
            if (tag == listenToken)
                return acceptKqueue();

            const index = cast(uint) tag;
            if (!matches(tag, index))
                return;
            auto peer = &peers[index];
            if (peer.phase == Phase.cancel)
                return;

            const oldPhase = peer.phase;
            const bytes = oldPhase == Phase.receive ? recv(peer.fd, peer.buffer.ptr,
                    peer.buffer.length, 0) : send(peer.fd, peer.buffer.ptr + peer.emitted,
                    peer.count - peer.emitted, sendFlags);
            if (bytes < 0 && (errno == EAGAIN || errno == EINTR))
                return;
            enforce(bytes >= 0, "direct nonblocking I/O failed");
            progress(*peer, bytes);
            if (peer.fd >= 0 && peer.phase != oldPhase)
            {
                // Drop the old direction's filter and arm the new one, as EPOLL_CTL_MOD does.
                change(peer.fd, oldPhase == Phase.receive ? EVFILT_READ : EVFILT_WRITE, EV_DELETE, tag);
                if (peer.phase != Phase.cancel)
                    change(peer.fd, peer.phase == Phase.receive ? EVFILT_READ : EVFILT_WRITE, EV_ADD, tag);
            }
        }
    }
    else
    {
        private void registerEpoll(int descriptor, int operation, ulong tag, uint flags)
        {
            epoll_event event;
            event.events = flags;
            event.data.u64 = tag;
            enforce(epoll_ctl(poller, operation, descriptor, &event) == 0, "direct epoll registration failed");
        }

        private void runEpoll()
        {
            poller = epoll_create1(EPOLL_CLOEXEC);
            enforce(poller >= 0, "direct epoll setup failed");
            scope (exit)
                close(poller);
            registerEpoll(listener, EPOLL_CTL_ADD, listenToken, EPOLLIN);

            epoll_event[64] events;
            while (!atomicLoad(finished))
            {
                const ready = epoll_wait(poller, events.ptr, events.length, 5);
                if (ready < 0 && errno == EINTR)
                    continue;
                enforce(ready >= 0, "direct epoll wait failed");
                foreach (ref event; events[0 .. ready])
                    handleEpoll(event.data.u64);

                const now = MonoTime.currTime;
                foreach (ref peer; peers)
                    if (peer.fd >= 0 && peer.phase == Phase.cancel && peer.cancelAt <= now)
                        retire(peer);
            }
            foreach (ref peer; peers)
                if (peer.fd >= 0)
                    retire(peer);
        }

        private void handleEpoll(ulong tag)
        {
            if (tag == listenToken)
            {
                const fd = accept4(listener, null, null, O_NONBLOCK | O_CLOEXEC);
                if (fd >= 0)
                {
                    const index = admit(fd);
                    if (index < peers.length)
                        registerEpoll(fd, EPOLL_CTL_ADD, token(index), EPOLLIN | EPOLLRDHUP);
                }
                else
                    enforce(errno == EAGAIN || errno == EINTR, "direct accept failed");
                return;
            }

            const index = cast(uint) tag;
            if (!matches(tag, index))
                return;
            auto peer = &peers[index];
            if (peer.phase == Phase.cancel)
                return;

            const oldPhase = peer.phase;
            const bytes = oldPhase == Phase.receive ? recv(peer.fd, peer.buffer.ptr,
                    peer.buffer.length, 0) : send(peer.fd, peer.buffer.ptr + peer.emitted,
                    peer.count - peer.emitted, MSG_NOSIGNAL);
            if (bytes < 0 && (errno == EAGAIN || errno == EINTR))
                return;
            enforce(bytes >= 0, "direct nonblocking I/O failed");
            progress(*peer, bytes);
            if (peer.fd >= 0 && peer.phase != oldPhase)
            {
                const flags = peer.phase == Phase.receive ? EPOLLIN | EPOLLRDHUP : EPOLLOUT;
                if (peer.phase == Phase.cancel)
                {
                    import core.sys.linux.epoll : EPOLL_CTL_DEL;

                    enforce(epoll_ctl(poller, EPOLL_CTL_DEL, peer.fd, null) == 0, "direct epoll cancellation failed");
                }
                else
                    registerEpoll(peer.fd, EPOLL_CTL_MOD, tag, flags);
            }
        }
    }

    version (FlintNativeLiburing)
    {
        private void runUring()
        {
            enforce(flint_uring_open(2 * (2 * connectionLimit + 3), &ring) == 0, "direct io_uring setup failed");
            uint live;
            do
            {
                live = queueUring();
                ulong tag;
                int result;
                const received = flint_uring_wait(ring, 5, &tag, &result);
                enforce(received >= 0, "direct io_uring poll failed");
                if (received != 0)
                    finishUring(tag, result);
            }
            while (!atomicLoad(finished) || live != 0 || listening || cancelAcks != 0);
            flint_uring_close(ring);
        }

        private uint queueUring()
        {
            const stopping = atomicLoad(finished);
            const now = MonoTime.currTime;
            if (!stopping && !listening)
            {
                const code = flint_uring_accept(ring, listener, listenToken);
                enforce(code == 0 || code == -EAGAIN, "direct async accept submission failed");
                listening = code == 0;
            }
            if (stopping && listening && !acceptCancelled)
                acceptCancelled = queueCancellation(listenToken);

            uint active;
            foreach (index, ref peer; peers)
            {
                if (peer.fd < 0)
                    continue;
                if (stopping || (peer.phase == Phase.cancel && peer.cancelAt <= now))
                {
                    if (peer.pending)
                    {
                        if (!peer.cancelling)
                            peer.cancelling = queueCancellation(token(index));
                    }
                    else
                        retire(peer);
                }
                else if (!peer.pending)
                    peer.pending = submitUring(peer, token(index));
                if (peer.fd >= 0)
                    ++active;
            }
            return active;
        }

        private bool submitUring(ref Peer peer, ulong tag)
        {
            const code = peer.phase == Phase.transmit ? flint_uring_send(ring, peer.fd,
                    peer.buffer.ptr + peer.emitted, cast(uint)(peer.count - peer.emitted), tag) : flint_uring_recv(ring,
                    peer.fd, peer.buffer.ptr, cast(uint) peer.buffer.length, tag);
            enforce(code == 0 || code == -EAGAIN, "direct io_uring transfer submission failed");
            return code == 0;
        }

        private bool queueCancellation(ulong tag)
        {
            const code = flint_uring_cancel(ring, tag);
            enforce(code == 0 || code == -EAGAIN, "direct async cancellation submission failed");
            if (code == 0)
                ++cancelAcks;
            return code == 0;
        }

        private void finishUring(ulong tag, int result)
        {
            if (tag == 0)
            {
                --cancelAcks;
                return;
            }
            if (tag == listenToken)
            {
                listening = false;
                if (result >= 0)
                    admit(result);
                else
                    enforce(result == -EAGAIN || result == -ECANCELED, "direct async accept failed");
                return;
            }

            const index = cast(uint) tag;
            enforce(matches(tag, index), "stale direct-provider completion");
            auto peer = &peers[index];
            peer.pending = false;
            if (peer.cancelling)
                retire(*peer);
            else if (result != -EAGAIN)
                progress(*peer, result);
        }
    }
}

/// Run the same bounded echo workload using OS/provider calls directly.
int main()
{
    auto listener = new TcpSocket;
    scope (exit)
        listener.close();
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(2048);
    listener.blocking = false;

    DirectServer server;
    server.listener = listener.handle;
    server.peers = new Peer[connectionLimit];

    const port = (cast(InternetAddress) listener.localAddress).port;
    ulong checksum;
    auto driver = new Thread({
        scope (exit)
            server.stop();
        checksum = runWorkloads(port);
    }).start();

    server.run();
    driver.join();
    enforce(checksum != 0, "direct workload produced no checksum");
    return 0;
}
