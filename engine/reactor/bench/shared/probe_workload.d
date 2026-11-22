module probe_workload;

import core.stdc.stdio : fclose, fprintf, printf, snprintf;
import core.stdc.stdlib : getenv, qsort;
import core.stdc.string : strlen;
import core.sys.posix.arpa.inet : htonl, htons;
import core.sys.posix.netinet.in_ : INADDR_LOOPBACK, IPPROTO_TCP, sockaddr_in;
import core.sys.posix.sys.socket : AF_INET, MSG_NOSIGNAL, SOCK_STREAM, SOL_SOCKET, SO_RCVTIMEO,
    SO_SNDTIMEO, connect, recv, send, setsockopt, sockaddr, socket;
import core.sys.posix.sys.time : timeval;
import core.sys.posix.unistd : close;
import core.time : MonoTime;
import std.exception : enforce;

/// The server admits this many simultaneous persistent clients.
enum connectionLimit = 1024;
/// The largest message in the workload.
enum maxPayload = 4096;
/// A single control octet outside the normal payload's first-octet range.
enum ubyte cancellationMarker = 255;

/// Copy an environment value, or return null when it is unset.
private string variable(scope const(char)* name)
{
    const value = getenv(name);
    return value is null ? null : value[0 .. strlen(value)].idup;
}

/// A caller may force the real readiness fallback for like-for-like local comparisons.
bool useUring()
{
    version (FlintNativeLiburing)
    {
        const selected = getenv("FLINT_REACTOR_PROBE_BACKEND");
        return selected is null || selected[0 .. strlen(selected)] == "io_uring";
    }
    else
        return false;
}

/// Connect one blocking loopback client with five-second send and receive timeouts.
private int connectPeer(ushort port)
{
    const peer = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    enforce(peer >= 0, "TCP socket creation failed");
    const timeout = timeval(5, 0);
    enforce(setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeout.sizeof) == 0
            && setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeout.sizeof) == 0, "TCP timeout setup failed");
    sockaddr_in address;
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    enforce(connect(peer, cast(const(sockaddr)*)&address, address.sizeof) == 0, "TCP connect failed");
    return peer;
}

private void sendAll(int peer, scope const(ubyte)[] bytes)
{
    while (bytes.length != 0)
    {
        const count = send(peer, bytes.ptr, bytes.length, MSG_NOSIGNAL);
        enforce(count > 0, "TCP send failed");
        bytes = bytes[count .. $];
    }
}

private void receiveAll(int peer, scope ubyte[] bytes)
{
    while (bytes.length != 0)
    {
        const count = recv(peer, bytes.ptr, bytes.length, 0);
        enforce(count > 0, "TCP response ended early");
        bytes = bytes[count .. $];
    }
}

private void closePeers(int[] peers)
{
    foreach (peer; peers)
        if (peer >= 0)
            close(peer);
}

private extern (C) int compareLatency(const void* left, const void* right) nothrow @nogc
{
    const first = *cast(const(long)*) left;
    const second = *cast(const(long)*) right;
    return (first > second) - (first < second);
}

private long quantile(scope const(long)[] sorted, size_t numerator)
{
    const rank = (sorted.length * numerator + 999) / 1000;
    return sorted[rank - 1];
}

private void checkOverflow(ushort port)
{
    foreach (_; 0 .. 32)
    {
        const peer = connectPeer(port);
        scope (exit)
            close(peer);
        ubyte[1] rejected;
        enforce(recv(peer, rejected.ptr, rejected.length, 0) == 0, "connection should have been rejected at capacity");
    }
}

private ulong exchange(int[] peers, size_t payloadSize)
{
    enum targetRequests = 32_768;
    const rounds = peers.length < 512 ? targetRequests / peers.length : 32;
    auto latency = new long[rounds * peers.length];
    auto sent = new MonoTime[peers.length];
    ubyte[maxPayload] input, output;
    foreach (index; 0 .. payloadSize)
        input[index] = cast(ubyte)((index * 17 + 57) % 251);

    ulong checksum;
    size_t samples;
    const started = MonoTime.currTime;
    foreach (_; 0 .. rounds)
    {
        foreach (index, peer; peers)
        {
            sent[index] = MonoTime.currTime;
            sendAll(peer, input[0 .. payloadSize]);
        }
        foreach (index, peer; peers)
        {
            receiveAll(peer, output[0 .. payloadSize]);
            latency[samples++] = (MonoTime.currTime - sent[index]).total!"nsecs";
            enforce(input[0 .. payloadSize] == output[0 .. payloadSize], "echo response mismatch");
            checksum += output[0] + cast(ulong) output[payloadSize - 1];
        }
    }
    const elapsed = (MonoTime.currTime - started).total!"nsecs";
    writeSamples(peers.length, payloadSize, latency);
    qsort(latency.ptr, latency.length, long.sizeof, &compareLatency);
    printf("echo clients=%zu payload=%zu requests=%zu throughput=%.2f p50_ns=%lld p99_ns=%lld p999_ns=%lld\n",
            peers.length, payloadSize,
            samples, cast(double) samples * 1.0e9 / elapsed, quantile(latency, 500), quantile(latency,
                990), quantile(latency, 999));
    return checksum;
}

private void writeSamples(size_t clients, size_t payload, scope const(long)[] samples)
{
    import core.stdc.errno : EEXIST, errno;
    import core.stdc.stdio : fopen;
    import core.sys.posix.sys.stat : mkdir;

    const directory = variable("FLINT_REACTOR_PROBE_SAMPLE_DIR");
    if (directory.length == 0)
        return;
    foreach (end; 1 .. directory.length + 1)
    {
        if (end != directory.length && directory[end] != '/')
            continue;
        const prefix = directory[0 .. end] ~ '\0';
        enforce(mkdir(prefix.ptr, 0x1ff) == 0 || errno == EEXIST, "sample directory creation failed");
    }
    char[64] name;
    const length = snprintf(name.ptr, name.length, "%zu-%zu-ns.txt", clients, payload);
    enforce(length > 0 && length < name.length, "sample file name did not fit");
    const separator = directory[$ - 1] == '/' ? "" : "/";
    auto output = fopen((directory ~ separator ~ name[0 .. length] ~ '\0').ptr, "w");
    enforce(output !is null, "sample file could not be opened");
    foreach (sample; samples)
        enforce(fprintf(output, "%lld\n", sample) > 0, "sample file write failed");
    enforce(fclose(output) == 0, "sample file close failed");
}

private void cancelPeers(int[] peers)
{
    const ubyte[1] control = [cancellationMarker];
    foreach (peer; peers)
        sendAll(peer, control[]);
    foreach (peer; peers)
    {
        ubyte[1] output;
        enforce(recv(peer, output.ptr, output.length, 0) == 0, "cancelled socket did not close cleanly");
    }
    printf("cancelled=%zu\n", peers.length);
}

/// Execute identical traffic against the Flint and direct-provider reactors.
ulong runWorkloads(ushort port)
{
    ulong checksum;
    foreach (count; [1, 64, connectionLimit])
    {
        auto peers = new int[count];
        peers[] = -1;
        scope (exit)
            closePeers(peers);
        foreach (ref peer; peers)
            peer = connectPeer(port);

        checksum += exchange(peers, 64);
        checksum += exchange(peers, maxPayload);
        if (count == connectionLimit)
            checkOverflow(port);
        cancelPeers(peers);
    }
    printf("checksum=%llu\n", checksum);
    return checksum;
}
