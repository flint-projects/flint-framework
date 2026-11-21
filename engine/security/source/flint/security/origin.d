/// Strict HTTP origin parsing shared by CORS and the JWKS configuration boundary.
module flint.security.origin;

import flint.security.sys.address : ipAddress;

@safe:

package(flint.security) struct Origin
{
    bool secure;
    ushort port;
    ubyte family;
    ubyte[16] address;
    char[253] host;
}

package(flint.security) char lowerAscii(char item) pure nothrow @nogc
{
    return item >= 'A' && item <= 'Z' ? cast(char)(item + 'a' - 'A') : item;
}

package(flint.security) bool sameAscii(scope const(char)[] left, scope const(char)[] right) pure nothrow @nogc
{
    if (left.length != right.length)
        return false;
    foreach (index, item; left)
        if (lowerAscii(item) != lowerAscii(right[index]))
            return false;
    return true;
}

private bool parsePort(scope const(char)[] input, out ushort number) pure nothrow @nogc
{
    uint collected;
    if (!input.length || input.length > 5)
        return false;
    foreach (item; input)
    {
        if (item < '0' || item > '9')
            return false;
        collected = collected * 10 + (item - '0');
    }
    if (!collected || collected > ushort.max)
        return false;
    number = cast(ushort) collected;
    return true;
}

private bool nameHost(scope const(char)[] host, ref Origin parsed) pure nothrow @nogc
{
    size_t labelLength;
    bool numeric = true;
    if (!host.length || host.length > parsed.host.length)
        return false;
    foreach (index, raw; host)
    {
        const item = lowerAscii(raw);
        if (item == '.')
        {
            if (!labelLength || host[index - 1] == '-')
                return false;
            labelLength = 0;
        }
        else
        {
            const alpha = item >= 'a' && item <= 'z';
            const digit = item >= '0' && item <= '9';
            if (!alpha && !digit && !(item == '-' && labelLength))
                return false;
            numeric &= digit;
            if (++labelLength > 63)
                return false;
        }
        parsed.host[index] = item;
    }
    return !numeric && host[$ - 1] != '-';
}

private bool parseAuthority(scope const(char)[] authority, ref Origin parsed) nothrow @nogc
{
    if (!authority.length)
        return false;
    const ipv6 = authority[0] == '[';
    const start = ipv6 ? 1 : 0;
    const delimiter = ipv6 ? ']' : ':';
    size_t end = start;
    while (end < authority.length && authority[end] != delimiter)
        ++end;
    if (ipv6 && end == authority.length)
        return false;

    const host = authority[start .. end];
    size_t tail = end + cast(size_t) ipv6;
    if (tail < authority.length)
    {
        if (authority[tail] != ':' || !parsePort(authority[tail + 1 .. $], parsed.port))
            return false;
    }
    if (ipAddress(host, ipv6, parsed.address))
    {
        parsed.family = ipv6 ? 6 : 4;
        return true;
    }
    return !ipv6 && nameHost(host, parsed);
}

package(flint.security) bool parseOrigin(scope const(char)[] text, out Origin origin) nothrow @nogc
{
    size_t prefix;
    if (text.length >= 8 && sameAscii(text[0 .. 8], "https://"))
    {
        origin.secure = true;
        origin.port = 443;
        prefix = 8;
    }
    else if (text.length >= 7 && sameAscii(text[0 .. 7], "http://"))
    {
        origin.port = 80;
        prefix = 7;
    }
    else
        return false;
    return parseAuthority(text[prefix .. $], origin);
}

package(flint.security) bool validJwksUrl(scope const(char)[] url) nothrow @nogc
{
    if (url.length <= 8 || url.length > 4096)
        return false;
    size_t end = url.length;
    foreach (index, item; url[8 .. $])
    {
        const absolute = index + 8;
        if (item <= ' ' || item >= 127 || item == '#' || item == '\\')
            return false;
        if (end == url.length && (item == '/' || item == '?'))
            end = absolute;
    }
    Origin origin;
    return parseOrigin(url[0 .. end], origin) && origin.secure;
}
