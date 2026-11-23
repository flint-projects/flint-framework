/// Endpoint policy and byte-preserving S3 object routes.
module flint.engine.storage.endpoint;

import flint.arena : Error, Status;
import flint.engine.storage.encoding : Writer, asciiAlpha, asciiDigit, lowerAscii, parseDecimal, sameAscii;
import flint.engine.storage.types : StorageOptions;

@safe:

package(flint.engine.storage) enum maximumKey = 1024;
package(flint.engine.storage) enum maximumUrl = 12_288;

package(flint.engine.storage) struct Endpoint
{
    bool secure;
    bool pathStyle;
    string authority;
}

private bool validPort(scope const(char)[] value) pure nothrow @nogc
{
    if (value.length > 5)
        return false;
    const port = parseDecimal(value);
    return port.ok && port.value > 0 && port.value <= ushort.max;
}

private bool loopback(scope const(char)[] host) pure nothrow @nogc
{
    return host == "127.0.0.1" || host == "[::1]";
}

private bool domain(scope const(char)[] host) pure nothrow @nogc
{
    if (!host.length || host.length > 253 || host[$ - 1] == '.')
        return false;
    size_t label;
    foreach (index, item; host)
    {
        if (item == '.')
        {
            if (!label || host[index - 1] == '-')
                return false;
            label = 0;
        }
        else
        {
            if (!asciiAlpha(item) && !asciiDigit(item) && (item != '-' || !label))
                return false;
            if (++label > 63)
                return false;
        }
    }
    return label != 0 && host[$ - 1] != '-';
}

private size_t boundary(scope const(char)[] authority, char delimiter) pure nothrow @nogc
{
    foreach (index, item; authority)
        if (item == delimiter)
            return index;
    return authority.length;
}

private size_t inspectAuthority(scope const(char)[] authority, bool pathStyle) pure nothrow @nogc
{
    if (!authority.length)
        return 0;
    const bracketed = authority[0] == '[';
    size_t hostLength = boundary(authority, bracketed ? ']' : ':');
    if (bracketed)
    {
        if (!pathStyle || hostLength == authority.length)
            return 0;
        ++hostLength;
        foreach (item; authority[1 .. hostLength - 1])
            if (!ipv6Character(item))
                return 0;
    }
    else if (!domain(authority[0 .. hostLength]))
        return 0;
    if (hostLength < authority.length && (authority[hostLength] != ':' || !validPort(authority[hostLength + 1 .. $])))
        return 0;
    return hostLength;
}

private bool ipv6Character(char item) pure nothrow @nogc
{
    const folded = lowerAscii(item);
    return item == ':' || item == '.' || asciiDigit(item) || (folded >= 'a' && folded <= 'f');
}

package(flint.engine.storage) Error configure(scope const ref StorageOptions options, out Endpoint endpoint)
{
    const value = options.endpoint;
    size_t prefix;
    if (value.length > 8 && sameAscii(value[0 .. 8], "https://"))
    {
        endpoint.secure = true;
        prefix = 8;
    }
    else if (value.length > 7 && sameAscii(value[0 .. 7], "http://"))
        prefix = 7;
    else
        return invalidEndpoint();

    auto authority = value[prefix .. $];
    if (authority.length && authority[$ - 1] == '/')
        authority = authority[0 .. $ - 1];
    const hostLength = inspectAuthority(authority, options.pathStyle);
    if (!options.verifyPeer || hostLength == 0)
        return invalidEndpoint();
    if (!endpoint.secure && (!options.allowLoopbackCleartext || !options.pathStyle
            || !loopback(authority[0 .. hostLength])))
        return invalidEndpoint();
    if (authority[hostLength .. $] == (endpoint.secure ? ":443" : ":80"))
        authority = authority[0 .. hostLength];

    auto normalized = new char[authority.length];
    foreach (index, item; authority)
        normalized[index] = lowerAscii(item);
    endpoint.authority = normalized.idup;
    endpoint.pathStyle = options.pathStyle;
    return Error.init;
}

private Error invalidEndpoint() pure nothrow @nogc
{
    return Error(Status.invalidArgument, "invalid S3 origin or TLS option");
}

package(flint.engine.storage) bool regionValid(scope const(char)[] region) pure nothrow @nogc
{
    if (!region.length || region.length > 63)
        return false;
    foreach (item; region)
        if ((item < 'a' || item > 'z') && !asciiDigit(item) && item != '-')
            return false;
    return true;
}

package(flint.engine.storage) bool objectValid(scope const(char)[] bucket, scope const(char)[] key) pure nothrow @nogc
{
    if (bucket.length < 3 || bucket.length > 63 || !domain(bucket) || !key.length || key.length > maximumKey)
        return false;
    foreach (item; bucket)
        if (item >= 'A' && item <= 'Z')
            return false;
    return true;
}

package(flint.engine.storage) void writeHost(scope ref Writer target, scope const ref Endpoint server,
        scope const(char)[] bucket) pure nothrow @nogc
{
    if (!server.pathStyle)
    {
        target.append(bucket);
        target.put('.');
    }
    target.append(server.authority);
}

package(flint.engine.storage) void writePath(scope ref Writer target, bool pathStyle,
        scope const(char)[] bucket, scope const(char)[] key) pure nothrow @nogc
{
    target.put('/');
    if (pathStyle)
    {
        target.append(bucket);
        target.put('/');
    }
    target.percent(key, true);
}
