/// Benchmark-only typed bindings to libcurl 8.23.0's multi-socket provider.
module curl_reference;

import core.sys.posix.poll : POLLERR, POLLHUP, POLLIN, POLLOUT, poll, pollfd;
import core.time : MonoTime;
import http_workload : ObserveBytes;

@system:

private struct Multi;
private struct Easy;

private struct Message
{
    int kind;
    Easy* easy;
    union
    {
        void* padding;
        int result;
    }
}

extern (C) private nothrow @nogc
{
    int curl_global_init(long flags);
    void curl_global_cleanup();
    Multi* curl_multi_init();
    int curl_multi_cleanup(Multi* multi);
    int curl_multi_setopt(Multi* multi, int option, ...);
    int curl_multi_add_handle(Multi* multi, Easy* easy);
    int curl_multi_remove_handle(Multi* multi, Easy* easy);
    int curl_multi_socket_action(Multi* multi, int fd, int events, int* running);
    Message* curl_multi_info_read(Multi* multi, int* remaining);
    Easy* curl_easy_init();
    void curl_easy_cleanup(Easy* easy);
    void curl_easy_reset(Easy* easy);
    int curl_easy_setopt(Easy* easy, int option, ...);
    int curl_easy_getinfo(Easy* easy, int info, ...);
}

private enum Opt
{
    writerData = 10_001,
    url = 10_002,
    proxy = 10_004,
    writer = 20_011,
    redirects = 52,
    verifyPeer = 64,
    root = 10_065,
    host = 81,
    protocol = 84,
    signals = 99,
    encoding = 10_102,
    connectTimeout = 156,
    pipeWait = 237,
    allowed = 10_318,
    allowedRedirects = 10_319,
}

private enum MultiOpt
{
    socketHandler = 20_001,
    socketContext = 10_002,
    timerHandler = 20_004,
    timerContext = 10_005,
    cached = 6,
    origin = 7,
    connections = 13,
    streams = 16,
}

private enum Info
{
    responseCode = 0x20_0002,
    protocol = 0x20_002e
}

private enum socketRemoved = 4;
private enum timeSocket = -1;
private enum complete = 1;
private enum http2 = 3;
private enum http2Tls = 4L;
private enum headerLimit = 65_536;
private enum entityLimit = 8 * 1024 * 1024;

private struct Transfer
{
    ObserveBytes receive;
    size_t used;
    size_t headers;
}

/// The benchmark calls the provider directly with the client fixture's socket and TLS options.
struct Provider
{
    private Multi* multi;
    private Easy* easy;
    private const(char)*[2] urls;
    private const(char)* root;
    private pollfd[400] interests;
    private size_t count;
    private long deadline = long.max;

    @disable this(this);

    // SAFETY: Startup owns the opaque provider handles and creates all retained string
    // storage. The probe drives and destroys the pool on the same thread.
    /// Prepare the reference pool and both immutable request URLs.
    bool open(string[2] addresses, string trust) @trusted
    {
        if (curl_global_init(3L) != 0)
            return false;
        multi = curl_multi_init();
        easy = curl_easy_init();
        if (multi is null || easy is null)
        {
            close();
            return false;
        }
        foreach (index, address; addresses)
            urls[index] = (address ~ '\0').ptr;
        root = (trust ~ '\0').ptr;
        if (setMulti())
            return true;
        close();
        return false;
    }

    private bool setMulti() nothrow @nogc
    {
        return curl_multi_setopt(multi, MultiOpt.socketHandler, &socketChange) == 0
            && curl_multi_setopt(multi, MultiOpt.socketContext,
                    &this) == 0 && curl_multi_setopt(multi, MultiOpt.timerHandler, &timerChange) == 0
            && curl_multi_setopt(multi, MultiOpt.timerContext, &this) == 0
            && curl_multi_setopt(multi, MultiOpt.cached, 64L) == 0
            && curl_multi_setopt(multi, MultiOpt.origin, 16L) == 0 && curl_multi_setopt(multi,
                    MultiOpt.connections, 64L) == 0 && curl_multi_setopt(multi, MultiOpt.streams, 64L) == 0;
    }

    // SAFETY: The stack transfer remains live up to synchronous multi removal. The
    // nonthrowing callback supplies a borrowed, bounded payload only during the call.
    /// Stream one verified HTTPS reply through the shared workload.
    bool fetch(size_t index, scope ObserveBytes receive) @trusted nothrow @nogc
    {
        Transfer transfer = {receive, 0, 0};
        if (!setRequest(index, &transfer) || curl_multi_add_handle(multi, easy) != 0)
            return false;
        scope (exit)
        {
            if (curl_multi_remove_handle(multi, easy) != 0)
                assert(0, "benchmark transfer removal failed");
            curl_easy_reset(easy);
        }
        const limit = milliseconds() + 10_000;
        while (milliseconds() < limit)
        {
            if (!drive())
                return false;
            int pending;
            const result = curl_multi_info_read(multi, &pending);
            if (result is null)
                continue;

            long status;
            long protocol;
            return result.kind == complete && result.easy is easy && result.result == 0
                && curl_easy_getinfo(easy, Info.responseCode, &status) == 0 && status == 200
                && curl_easy_getinfo(easy, Info.protocol, &protocol) == 0 && protocol == http2;
        }
        return false;
    }

    // SAFETY: This reference owns the handles and releases them on the driving thread.
    /// Retire both provider handles and process initialization.
    void close() @trusted nothrow @nogc
    {
        if (easy !is null)
            curl_easy_cleanup(easy);
        if (multi !is null && curl_multi_cleanup(multi) != 0)
            assert(0, "benchmark multi cleanup failed");
        curl_global_cleanup();
    }

    private bool setRequest(size_t index, Transfer* transfer) nothrow @nogc
    {
        return curl_easy_setopt(easy, Opt.url, urls[index]) == 0 && curl_easy_setopt(easy, Opt.proxy,
                "".ptr) == 0 && curl_easy_setopt(easy, Opt.allowed, "http,https".ptr) == 0
            && curl_easy_setopt(easy, Opt.allowedRedirects, "http,https".ptr) == 0
            && curl_easy_setopt(easy, Opt.redirects,
                    0L) == 0 && curl_easy_setopt(easy, Opt.verifyPeer, 1L) == 0
            && curl_easy_setopt(easy, Opt.host, 2L) == 0 && curl_easy_setopt(easy, Opt.root, root) == 0
            && curl_easy_setopt(easy, Opt.protocol, http2Tls) == 0 && curl_easy_setopt(easy, Opt.signals,
                    1L) == 0 && curl_easy_setopt(easy, Opt.encoding, "".ptr) == 0
            && curl_easy_setopt(easy, Opt.connectTimeout, 5_000L) == 0 && curl_easy_setopt(easy, Opt.pipeWait,
                    1L) == 0 && curl_easy_setopt(easy, Opt.writer, &readBody) == 0
            && curl_easy_setopt(easy, Opt.writerData, transfer) == 0 && curl_easy_setopt(easy,
                    20_079, &readHeader) == 0 && curl_easy_setopt(easy, 10_029, transfer) == 0;
    }

    private bool drive() nothrow @nogc
    {
        int running;
        const wait = deadline - milliseconds();
        if (wait <= 0)
            return curl_multi_socket_action(multi, timeSocket, 0, &running) == 0;
        pollfd[400] ready;
        const size_t snapshot = count;
        ready[0 .. snapshot] = interests[0 .. snapshot];
        const countReady = poll(ready.ptr, snapshot, cast(int)(wait < 5 ? wait : 5));
        if (countReady < 0)
            return false;
        foreach (item; ready[0 .. snapshot])
        {
            if (!item.revents)
                continue;
            const events = ((item.revents & POLLIN) != 0 ? 1 : 0) | ((item.revents & POLLOUT) != 0
                    ? 2 : 0) | ((item.revents & (POLLERR | POLLHUP)) != 0 ? 4 : 0);
            if (curl_multi_socket_action(multi, item.fd, events, &running) != 0)
                return false;
        }
        return true;
    }
}

private long milliseconds() nothrow @nogc
{
    return MonoTime.currTime.ticks / (MonoTime.ticksPerSecond / 1_000);
}

extern (C) private nothrow @nogc
{
    int socketChange(Easy*, int fd, int interest, void* context, void*)
    {
        auto driver = cast(Provider*) context;
        size_t index;
        while (index < driver.count && driver.interests[index].fd != fd)
            ++index;
        if (interest == socketRemoved || interest == 0)
        {
            if (index < driver.count)
                driver.interests[index] = driver.interests[--driver.count];
            return 0;
        }
        if (index == driver.count)
        {
            if (driver.count == driver.interests.length)
                return -1;
            ++driver.count;
        }
        const flags = (interest & 1 ? POLLIN : 0) | (interest & 2 ? POLLOUT : 0);
        driver.interests[index] = pollfd(fd, cast(short) flags, 0);
        return 0;
    }

    int timerChange(Multi*, long delay, void* context)
    {
        auto driver = cast(Provider*) context;
        driver.deadline = delay < 0 ? long.max : milliseconds() + delay;
        return 0;
    }

    size_t readBody(const(ubyte)* data, size_t size, size_t count, void* user)
    {
        auto transfer = cast(Transfer*) user;
        const length = size * count;
        if (length > entityLimit - transfer.used)
            return 0;
        transfer.receive(data[0 .. length]);
        transfer.used += length;
        return length;
    }

    size_t readHeader(const(ubyte)*, size_t size, size_t count, void* user)
    {
        auto transfer = cast(Transfer*) user;
        const length = size * count;
        if (length > headerLimit - transfer.headers)
            return 0;
        transfer.headers += length;
        return length;
    }
}
