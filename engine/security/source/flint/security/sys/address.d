/// Length-checked IP literals for origin comparisons.
module flint.security.sys.address;

import core.sys.posix.arpa.inet : inet_pton;
import core.sys.posix.netinet.in_ : AF_INET, AF_INET6;

@safe:

// SAFETY: inet_pton reads only the terminated local input and writes 4 or 16 bytes to
// the caller-owned output. It cannot retain pointers, invoke callbacks, or throw.
package(flint.security) bool ipAddress(scope const(char)[] text, bool ipv6, ref ubyte[16] output) @trusted nothrow @nogc
{
    char[254] terminated;
    if (!text.length || text.length >= terminated.length)
        return false;
    foreach (item; text)
        if (item == 0)
            return false;
    terminated[0 .. text.length] = text[];
    terminated[text.length] = 0;
    return inet_pton(ipv6 ? AF_INET6 : AF_INET, terminated.ptr, &output[0]) == 1;
}
