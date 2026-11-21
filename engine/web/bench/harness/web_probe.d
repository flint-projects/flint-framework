/// Fixed HTTP/1 parse-and-route fixture shared by the Web probe and its llhttp control.
module web_probe;

import core.stdc.stdio : printf;
import core.time : MonoTime;
import flint.arena : RequestArena, Status;

@safe:

/// One path, expected route and body size in the shared request corpus.
struct Example
{
    /// Wire request supplied to the pinned llhttp parser.
    string request;
    /// Expected endpoint identity.
    uint route;
    /// Bytes accepted by native body framing.
    size_t body;
}

/// Sends representative literal, parameter, wildcard and missed routes with one chunked request.
immutable Example[] examples = [
    Example("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n", 1, 0),
    Example("GET /users/42 HTTP/1.1\r\nHost: localhost\r\n\r\n", 2, 0),
    Example("GET /assets/icons/a.svg HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n"
            ~ "3\r\nabc\r\n0\r\n\r\n", 3, 3),
    Example("GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n", 4, 0)
];

/// A checked parser and route computation returning a stable result checksum.
alias Trial = uint delegate(scope const Example) @safe nothrow @nogc;

/// Consume the same arena work on each observed route.
uint observe(ref scope RequestArena arena, uint endpoint, size_t inbound) nothrow @nogc
{
    auto bytes = arena.copyIn(cast(const(ubyte)[]) "reply");
    if (!bytes.ok())
        return 0;
    uint result;
    const status = arena.read(bytes.value, (scope const(ubyte)[] response) @safe nothrow @nogc {
        result = endpoint * 100 + cast(uint) inbound;
        foreach (value; response)
            result += value;
    });
    return status == Status.ok ? result : 0;
}

private uint expected(scope const Example input) pure nothrow @nogc
{
    return input.route * 100 + cast(uint) input.body + 'r' + 'e' + 'p' + 'l' + 'y';
}

// SAFETY: The static format has integer-only, width-matched values; no pointer from the fixture is retained.
private void report(ulong requests, ulong checksum, long elapsed, ulong fixture) @trusted nothrow @nogc
{
    printf("requests=%llu checksum=%llu elapsed_ns=%lld fixed_corpus_checksum=%llu\n", requests,
            checksum, elapsed, fixture);
}

/// Check all four results outside timing, then time checked batches for at least 150 ms.
bool measure(scope Trial run) nothrow @nogc
{
    ulong fixture;
    foreach (ref input; examples)
    {
        const value = run(input);
        if (value != expected(input))
            return false;
        fixture += value;
    }

    ulong requests;
    ulong checksum;
    long elapsed;
    const start = MonoTime.currTime;
    do
    {
        foreach (repeat; 0 .. 32)
        {
            foreach (ref input; examples)
            {
                const value = run(input);
                if (value != expected(input))
                    return false;
                checksum += value;
            }
        }
        requests += 32 * examples.length;
        elapsed = (MonoTime.currTime - start).total!"nsecs";
    }
    while (elapsed < 150_000_000);

    report(requests, checksum, elapsed, fixture);
    return true;
}
