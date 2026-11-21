/// Fail-closed mail endpoint admission.
module flint.mail.endpoint;

import flint.arena : Error, Status;
import flint.mail.types : MailBackend, MailOptions;
import flint.mail.validation : domain, headerText;

@safe:

private bool port(scope const(char)[] value) pure nothrow @nogc
{
    if (!value.length || value.length > 5)
        return false;
    uint parsed;
    foreach (item; value)
    {
        if (item < '0' || item > '9')
            return false;
        parsed = parsed * 10 + item - '0';
    }
    return parsed >= 1 && parsed <= ushort.max;
}

private enum Authority
{
    invalid,
    dns,
    loopback
}

private Authority hostname(scope const(char)[] authority) pure nothrow @nogc
{
    size_t boundary;
    auto kind = Authority.dns;
    if (authority.length >= 5 && authority[0 .. 5] == "[::1]")
    {
        boundary = 5;
        kind = Authority.loopback;
    }
    else
    {
        while (boundary < authority.length && authority[boundary] != ':')
            ++boundary;
        if (!domain(authority[0 .. boundary]))
            return Authority.invalid;
        if (authority[0 .. boundary] == "127.0.0.1")
            kind = Authority.loopback;
    }
    if (boundary == authority.length || (authority[boundary] == ':' && port(authority[boundary + 1 .. $])))
        return kind;
    return Authority.invalid;
}

package(flint.mail) Error checkEndpoint(scope const ref MailOptions options) pure nothrow @nogc
{
    static const Error invalid = Error(Status.invalidArgument, "invalid mail endpoint, TLS policy or limit");
    if (options.backend > MailBackend.max || !options.maxMessageBytes
            || options.maxMessageBytes > 64 * 1024 * 1024 || !headerText(options.endpoint, 1024)
            || !headerText(options.caBundle, 4096) || !headerText(options.username, 512)
            || !headerText(options.password, 1024))
        return invalid;
    const allowed = options.backend == MailBackend.smtp ? smtpEndpoint(options) : providerEndpoint(options);
    return allowed ? Error.init : invalid;
}

private bool smtpEndpoint(scope const ref MailOptions options) pure nothrow @nogc
{
    const endpoint = options.endpoint;
    const smtp = endpoint.length > 7 && endpoint[0 .. 7] == "smtp://";
    const smtps = endpoint.length > 8 && endpoint[0 .. 8] == "smtps://";
    if (!smtp && !smtps)
        return false;
    const authority = hostname(endpoint[smtp ? 7 : 8 .. $]);
    if (authority == Authority.invalid || (!options.username.length != !options.password.length))
        return false;
    if (options.requireTls)
        return true;
    return smtp && authority == Authority.loopback && options.allowLoopbackCleartext && !options.username.length;
}

private bool providerEndpoint(scope const ref MailOptions options) pure nothrow @nogc
{
    if (!options.requireTls || options.allowLoopbackCleartext || !options.password.length)
        return false;
    const endpoint = options.endpoint;
    if (endpoint.length <= 8 || endpoint[0 .. 8] != "https://")
        return false;
    size_t start = 8;
    while (start < endpoint.length && endpoint[start] != '/')
        ++start;
    return hostname(endpoint[8 .. start]) != Authority.invalid && providerPath(options, endpoint[start .. $]);
}

private bool providerPath(scope const ref MailOptions options, scope const(char)[] path) pure nothrow @nogc
{
    switch (options.backend)
    {
    case MailBackend.resend:
        return !options.username.length && path == "/emails";
    case MailBackend.postmark:
        return !options.username.length && path == "/email";
    case MailBackend.ses:
        return options.username.length != 0 && options.username.length <= 128
            && options.password.length <= 256 && validRegion(options.sesRegion)
            && headerText(options.sesSessionToken, 2048) && path == "/v2/email/outbound-emails";
    default:
        return false;
    }
}

private bool validRegion(scope const(char)[] region) pure nothrow @nogc
{
    if (!region.length || region.length > 63)
        return false;
    foreach (item; region)
        if ((item < 'a' || item > 'z') && (item < '0' || item > '9') && item != '-')
            return false;
    return true;
}
