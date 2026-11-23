/// Owner-local stream receive credits and one outbound frame of owned bytes.
module flint.engine.web.stream_queues;

import flint.engine.web.sys.ownership : releaseBytes, reserveBytes;

@safe:
package(flint.engine.web):

/// The default HTTP/2 stream credit set by the provider.
enum streamInputCredit = 65_535;

struct StreamQueues
{
    private ubyte[] memory;
    private size_t inboundCapacity;
    private size_t receiveStart;
    size_t inbound;
    size_t outbound;

    bool open(bool duplex, size_t outgoing) nothrow @nogc
    {
        inboundCapacity = duplex ? streamInputCredit : 0;
        const capacity = inboundCapacity + outgoing;
        memory = reserveBytes(capacity);
        return memory.length == capacity;
    }

    void clear() nothrow @nogc
    {
        releaseBytes(memory);
        inboundCapacity = 0;
        receiveStart = 0;
        inbound = 0;
        outbound = 0;
    }

    bool admit(scope const(ubyte)[] source) nothrow @nogc
    {
        if (source.length > inboundCapacity - inbound)
            return false;
        if (source.length == 0)
            return true;
        const first = (receiveStart + inbound) % inboundCapacity;
        const tail = minimum(source.length, inboundCapacity - first);
        memory[first .. first + tail] = source[0 .. tail];
        memory[0 .. source.length - tail] = source[tail .. $];
        inbound += source.length;
        return true;
    }

    size_t read(scope ubyte[] output) nothrow @nogc
    {
        const count = minimum(inbound, output.length);
        if (count == 0)
            return 0;
        const tail = minimum(count, inboundCapacity - receiveStart);
        output[0 .. tail] = memory[receiveStart .. receiveStart + tail];
        output[tail .. count] = memory[0 .. count - tail];
        receiveStart = (receiveStart + count) % inboundCapacity;
        inbound -= count;
        return count;
    }

    size_t write(scope const(ubyte)[] source) nothrow @nogc
    {
        if (outbound != 0)
            return 0;
        const count = minimum(source.length, memory.length - inboundCapacity);
        memory[inboundCapacity .. inboundCapacity + count] = source[0 .. count];
        outbound = count;
        return count;
    }

    size_t send(scope ubyte[] output) nothrow @nogc
    {
        const count = minimum(outbound, output.length);
        output[0 .. count] = memory[inboundCapacity .. inboundCapacity + count];
        const remain = outbound - count;
        foreach (index; 0 .. remain)
            memory[inboundCapacity + index] = memory[inboundCapacity + index + count];
        outbound = remain;
        return count;
    }
}

private size_t minimum(size_t first, size_t second) pure nothrow @nogc
{
    return first < second ? first : second;
}
