module probe_workload;

import core.time : MonoTime, msecs;
import std.algorithm.sorting : sort;
import std.exception : enforce;
import std.process : environment;
import std.socket : InternetAddress, SocketOption, SocketOptionLevel, TcpSocket;
import std.stdio : writefln;

/// The server admits this many simultaneous persistent clients.
enum connectionLimit = 1024;
/// The largest message in the workload.
enum maxPayload = 4096;
/// A single control octet outside the normal payload's first-octet range.
enum ubyte cancellationMarker = 255;

/// A caller may force the real readiness fallback for like-for-like local comparisons.
bool useUring()
{
    version (FlintNativeLiburing)
        return environment.get("FLINT_REACTOR_PROBE_BACKEND", "io_uring") == "io_uring";
    else
        return false;
}

private TcpSocket connectPeer(ushort port)
{
    auto peer = new TcpSocket;
    peer.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 5_000.msecs);
    peer.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, 5_000.msecs);
    peer.connect(new InternetAddress("127.0.0.1", port));
    return peer;
}

private void sendAll(TcpSocket peer, scope const(ubyte)[] bytes)
{
    while (bytes.length != 0)
    {
        const count = peer.send(bytes);
        enforce(count > 0, "TCP send failed");
        bytes = bytes[count .. $];
    }
}

private void receiveAll(TcpSocket peer, scope ubyte[] bytes)
{
    while (bytes.length != 0)
    {
        const count = peer.receive(bytes);
        enforce(count > 0, "TCP response ended early");
        bytes = bytes[count .. $];
    }
}

private void closePeers(TcpSocket[] peers)
{
    foreach (peer; peers)
        if (peer !is null)
            peer.close();
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
        auto peer = connectPeer(port);
        scope (exit)
            peer.close();
        ubyte[1] rejected;
        enforce(peer.receive(rejected[]) == 0, "connection should have been rejected at capacity");
    }
}

private ulong exchange(TcpSocket[] peers, size_t payloadSize)
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
    latency.sort;
    writefln("echo clients=%s payload=%s requests=%s throughput=%.2f p50_ns=%s p99_ns=%s p999_ns=%s", peers.length,
            payloadSize, samples, cast(double) samples * 1.0e9 / elapsed, quantile(latency, 500),
            quantile(latency, 990), quantile(latency, 999));
    return checksum;
}

private void writeSamples(size_t clients, size_t payload, scope const(long)[] samples)
{
    import std.file : mkdirRecurse;
    import std.format : format;
    import std.path : buildPath;
    import std.stdio : File;

    const directory = environment.get("FLINT_REACTOR_PROBE_SAMPLE_DIR");
    if (directory.length == 0)
        return;
    mkdirRecurse(directory);
    auto output = File(buildPath(directory, format("%s-%s-ns.txt", clients, payload)), "w");
    foreach (sample; samples)
        output.writeln(sample);
}

private void cancelPeers(TcpSocket[] peers)
{
    const ubyte[1] control = [cancellationMarker];
    foreach (peer; peers)
        sendAll(peer, control[]);
    foreach (peer; peers)
    {
        ubyte[1] output;
        enforce(peer.receive(output[]) == 0, "cancelled socket did not close cleanly");
    }
    writefln("cancelled=%s", peers.length);
}

/// Execute identical traffic against the Flint and direct-provider reactors.
ulong runWorkloads(ushort port)
{
    ulong checksum;
    foreach (count; [1, 64, connectionLimit])
    {
        auto peers = new TcpSocket[count];
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
    writefln("checksum=%s", checksum);
    return checksum;
}
