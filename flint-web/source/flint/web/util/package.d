/++
`org.springframework.web.util`: building, encoding and expanding URIs.

Ported from spring-projects/spring-framework v7.1.0, spring-web/src/main/java/org/springframework/web/util/
(UriComponentsBuilder.java, UriComponents.java, HierarchicalUriComponents.java, UriUtils.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: one `UriComponents` class covers Spring's hierarchical components (opaque URIs are
not ported). `UriComponentsBuilder` is a final class with Java's chained setters (R12). URI variables are
`string` (`Object...` values are rendered by the caller, R7). Encoding works on UTF-8 bytes, which is what Java's
`UriUtils.encode(source, UTF_8)` produces too, so encoded output is identical (R14); indices are UTF-8 bytes.
+/
module flint.web.util;

import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.java.net : URI;

@safe:

/// The component kinds of `HierarchicalUriComponents.Type`, with Spring's allowed characters.
enum UriComponentType
{
    SCHEME, ///
    AUTHORITY, ///
    USER_INFO, ///
    HOST_IPV4, ///
    HOST_IPV6, ///
    PORT, ///
    PATH, ///
    PATH_SEGMENT, ///
    QUERY, ///
    QUERY_PARAM, ///
    FRAGMENT, ///
    URI ///
}

private bool isAlpha(int c) pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

private bool isDigit(int c) pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

private bool isSubDelimiter(int c) pure nothrow @nogc
{
    return c == '!' || c == '$' || c == '&' || c == '\'' || c == '(' || c == ')' || c == '*' || c == '+' || c == ','
        || c == ';' || c == '=';
}

private bool isUnreserved(int c) pure nothrow @nogc
{
    return isAlpha(c) || isDigit(c) || c == '-' || c == '.' || c == '_' || c == '~';
}

private bool isPchar(int c) pure nothrow @nogc
{
    return isUnreserved(c) || isSubDelimiter(c) || c == ':' || c == '@';
}

/// Whether byte `c` may appear unencoded in a component of `type`.
bool isAllowed(UriComponentType type, int c) pure nothrow @nogc
{
    final switch (type)
    {
    case UriComponentType.SCHEME:
        return isAlpha(c) || isDigit(c) || c == '+' || c == '-' || c == '.';
    case UriComponentType.AUTHORITY:
        return isUnreserved(c) || isSubDelimiter(c) || c == ':' || c == '@';
    case UriComponentType.USER_INFO:
        return isUnreserved(c) || isSubDelimiter(c) || c == ':';
    case UriComponentType.HOST_IPV4:
        return isUnreserved(c) || isSubDelimiter(c);
    case UriComponentType.HOST_IPV6:
        return isUnreserved(c) || isSubDelimiter(c) || c == '[' || c == ']' || c == ':';
    case UriComponentType.PORT:
        return isDigit(c);
    case UriComponentType.PATH:
        return isPchar(c) || c == '/';
    case UriComponentType.PATH_SEGMENT:
        return isPchar(c);
    case UriComponentType.QUERY:
        return isPchar(c) || c == '/' || c == '?';
    case UriComponentType.QUERY_PARAM:
        return c != '=' && c != '&' && (isPchar(c) || c == '/' || c == '?');
    case UriComponentType.FRAGMENT:
        return isPchar(c) || c == '/' || c == '?';
    case UriComponentType.URI:
        return isUnreserved(c);
    }
}

/// `UriUtils`: encoding and decoding of URI components (UTF-8).
struct UriUtils
{
    /// Percent-encodes every byte of `source` that `type` does not allow.
    static string encodeUriComponent(string source, UriComponentType type) pure nothrow
    {
        static immutable hex = "0123456789ABCDEF";
        bool changed;
        foreach (char c; source)
            changed = changed || !isAllowed(type, c);
        if (!changed)
            return source;
        char[] result;
        foreach (char c; source)
        {
            if (isAllowed(type, c))
                result ~= c;
            else
            {
                result ~= '%';
                result ~= hex[c >> 4];
                result ~= hex[c & 15];
            }
        }
        return result.idup;
    }

    /// `encode(source, UTF_8)`: every byte but the unreserved ones.
    static string encode(string source) pure nothrow
    {
        return encodeUriComponent(source, UriComponentType.URI);
    }

    /// `encodePath`.
    static string encodePath(string path) pure nothrow
    {
        return encodeUriComponent(path, UriComponentType.PATH);
    }

    /// `encodePathSegment`.
    static string encodePathSegment(string segment) pure nothrow
    {
        return encodeUriComponent(segment, UriComponentType.PATH_SEGMENT);
    }

    /// `encodeQuery`.
    static string encodeQuery(string query) pure nothrow
    {
        return encodeUriComponent(query, UriComponentType.QUERY);
    }

    /// `encodeQueryParam`.
    static string encodeQueryParam(string queryParam) pure nothrow
    {
        return encodeUriComponent(queryParam, UriComponentType.QUERY_PARAM);
    }

    /// `encodeFragment`.
    static string encodeFragment(string fragment) pure nothrow
    {
        return encodeUriComponent(fragment, UriComponentType.FRAGMENT);
    }

    /// `decode(source, UTF_8)`: `%XX` to bytes. Throws `IllegalArgumentException` for an invalid sequence.
    static string decode(string source) pure
    {
        bool encoded;
        foreach (c; source)
            encoded = encoded || c == '%';
        if (!encoded)
            return source;
        char[] result;
        for (size_t i = 0; i < source.length; i++)
        {
            if (source[i] == '%')
            {
                if (i + 2 >= source.length || !isHex(source[i + 1]) || !isHex(source[i + 2]))
                    throw new IllegalArgumentException("Invalid encoded sequence \"" ~ source[i .. $] ~ "\"");
                result ~= cast(char)(hexValue(source[i + 1]) * 16 + hexValue(source[i + 2]));
                i += 2;
            }
            else
                result ~= source[i];
        }
        return result.idup;
    }

    private static bool isHex(char c) pure nothrow @nogc
    {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }

    private static int hexValue(char c) pure nothrow @nogc
    {
        return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;
    }
}

/// `UriComponents` (`HierarchicalUriComponents`): an immutable set of URI components.
final class UriComponents
{
    private string scheme;
    private string userInfo;
    private string host;
    private string port; // as text; "" when absent
    private string path;
    private string[2][] queryParams; // value null for a name without '='
    private string fragment;
    private bool encoded;

    private this() pure nothrow @nogc
    {
    }

    /// The scheme, or `null`.
    string getScheme() const pure nothrow @nogc
    {
        return scheme;
    }

    /// The user info, or `null`.
    string getUserInfo() const pure nothrow @nogc
    {
        return userInfo;
    }

    /// The host, or `null`.
    string getHost() const pure nothrow @nogc
    {
        return host;
    }

    /// The port, or `-1` when absent.
    int getPort() const pure
    {
        import std.conv : to;

        if (port.length == 0)
            return -1;
        if (port[0] == '{')
            throw new IllegalStateException("The port contains a URI variable but has not been expanded yet: " ~ port);
        return port.to!int;
    }

    /// The path, or `null`.
    string getPath() const pure nothrow @nogc
    {
        return path;
    }

    /// The path segments.
    string[] getPathSegments() const pure nothrow
    {
        string[] result;
        size_t start;
        foreach (i; 0 .. path.length + 1)
        {
            if (i == path.length || path[i] == '/')
            {
                if (i > start)
                    result ~= path[start .. i];
                start = i + 1;
            }
        }
        return result;
    }

    /// The query string, or `null`.
    string getQuery() const pure nothrow
    {
        if (queryParams.length == 0)
            return null;
        string text;
        foreach (i, pair; queryParams)
        {
            text ~= (i == 0 ? "" : "&") ~ pair[0];
            if (pair[1] !is null)
                text ~= "=" ~ pair[1];
        }
        return text;
    }

    /// The query parameters in order (Java's `MultiValueMap`; R10).
    const(string[2])[] getQueryParams() const pure nothrow @nogc
    {
        return queryParams;
    }

    /// The fragment, or `null`.
    string getFragment() const pure nothrow @nogc
    {
        return fragment;
    }

    /// A copy with every component encoded (Spring's `encode()`: the template's literal parts).
    UriComponents encode() const pure
    {
        if (encoded)
            return copy();
        auto result = new UriComponents;
        result.scheme = scheme is null ? null : UriUtils.encodeUriComponent(scheme, UriComponentType.SCHEME);
        result.userInfo = userInfo is null ? null : UriUtils.encodeUriComponent(userInfo, UriComponentType.USER_INFO);
        result.host = host is null ? null : UriUtils.encodeUriComponent(host,
                host.length != 0 && host[0] == '[' ? UriComponentType.HOST_IPV6 : UriComponentType.HOST_IPV4);
        result.port = port;
        result.path = path is null ? null : encodeTemplate(path, UriComponentType.PATH);
        foreach (pair; queryParams)
            result.queryParams ~= [encodeTemplate(pair[0], UriComponentType.QUERY_PARAM),
                pair[1] is null ? null : encodeTemplate(pair[1], UriComponentType.QUERY_PARAM)];
        result.fragment = fragment is null ? null : encodeTemplate(fragment, UriComponentType.FRAGMENT);
        result.encoded = true;
        return result;
    }

    // Encodes the literal parts and leaves {variables} for expansion, as Spring's encodeTemplate does.
    private static string encodeTemplate(string source, UriComponentType type) pure nothrow
    {
        string result;
        size_t i;
        while (i < source.length)
        {
            if (source[i] == '{')
            {
                size_t close = i;
                int depth;
                for (; close < source.length; close++)
                {
                    if (source[close] == '{')
                        depth++;
                    else if (source[close] == '}' && --depth == 0)
                        break;
                }
                if (close < source.length)
                {
                    result ~= source[i .. close + 1];
                    i = close + 1;
                    continue;
                }
            }
            size_t j = i;
            while (j < source.length && source[j] != '{')
                j++;
            result ~= UriUtils.encodeUriComponent(source[i .. j], type);
            i = j;
        }
        return result;
    }

    /// Expands `{variables}` in order with `values`, encoding each value for its component.
    UriComponents expand(string[] values...) const pure
    {
        size_t next;
        string[2][] named;
        return expandWith(values, next, named);
    }

    /// Expands `{variables}` by name.
    UriComponents expand(string[2][] namedValues) const pure
    {
        size_t next;
        return expandWith(null, next, namedValues);
    }

    private UriComponents expandWith(scope string[] values, ref size_t next, scope string[2][] named) const pure
    {
        auto result = new UriComponents;
        string expandOne(string source, UriComponentType type)
        {
            if (source is null)
                return null;
            string text;
            size_t i;
            while (i < source.length)
            {
                if (source[i] == '{')
                {
                    size_t close = i;
                    while (close < source.length && source[close] != '}')
                        close++;
                    if (close < source.length)
                    {
                        auto name = source[i + 1 .. close];
                        foreach (k, c; name)
                            if (c == ':')
                            {
                                name = name[0 .. k];
                                break;
                            }
                        string value;
                        bool found;
                        foreach (pair; named)
                            if (pair[0] == name)
                            {
                                value = pair[1];
                                found = true;
                            }
                        if (!found)
                        {
                            if (next >= values.length)
                                throw new IllegalArgumentException("Not enough variable values available to expand '"
                                        ~ name ~ "'");
                            value = values[next++];
                        }
                        text ~= encoded ? UriUtils.encodeUriComponent(value, type) : value;
                        i = close + 1;
                        continue;
                    }
                }
                text ~= source[i];
                i++;
            }
            return text;
        }

        result.scheme = expandOne(scheme, UriComponentType.SCHEME);
        result.userInfo = expandOne(userInfo, UriComponentType.USER_INFO);
        result.host = expandOne(host, UriComponentType.HOST_IPV4);
        result.port = port is null ? null : expandOne(port, UriComponentType.PORT);
        result.path = expandOne(path, UriComponentType.PATH_SEGMENT);
        foreach (pair; queryParams)
            result.queryParams ~= [expandOne(pair[0], UriComponentType.QUERY_PARAM),
                expandOne(pair[1], UriComponentType.QUERY_PARAM)];
        result.fragment = expandOne(fragment, UriComponentType.FRAGMENT);
        result.encoded = encoded;
        return result;
    }

    private UriComponents copy() const pure nothrow
    {
        auto result = new UriComponents;
        result.scheme = scheme;
        result.userInfo = userInfo;
        result.host = host;
        result.port = port;
        result.path = path;
        result.queryParams = queryParams.dup;
        result.fragment = fragment;
        result.encoded = encoded;
        return result;
    }

    /// The URI string.
    string toUriString() const pure nothrow
    {
        string text;
        if (scheme !is null)
            text ~= scheme ~ ":";
        if (userInfo !is null || host !is null)
        {
            text ~= "//";
            if (userInfo !is null)
                text ~= userInfo ~ "@";
            if (host !is null)
                text ~= host;
            if (port.length != 0)
                text ~= ":" ~ port;
        }
        if (path.length != 0)
        {
            if (text.length != 0 && path[0] != '/')
                text ~= "/";
            text ~= path;
        }
        const query = getQuery();
        if (query !is null)
            text ~= "?" ~ query;
        if (fragment !is null)
            text ~= "#" ~ fragment;
        return text;
    }

    /// A `URI` (Java's `toUri()`): encoded components are used as they are.
    URI toUri() const pure
    {
        return URI.create(encoded ? toUriString() : encode().toUriString());
    }

    override string toString() const pure nothrow
    {
        return toUriString();
    }

    override bool opEquals(Object other) const
    {
        auto that = cast(const UriComponents) other;
        return that !is null && that.toUriString() == toUriString();
    }

    override size_t toHash() const nothrow
    {
        return hashOf(toUriString());
    }
}

/// `UriComponentsBuilder`.
final class UriComponentsBuilder
{
    private string schemeValue;
    private string userInfoValue;
    private string hostValue;
    private string portValue;
    private string pathValue;
    private string[2][] queryParamsValue;
    private string fragmentValue;

    private this() pure nothrow @nogc
    {
    }

    /// An empty builder.
    static UriComponentsBuilder newInstance() pure nothrow
    {
        return new UriComponentsBuilder;
    }

    /// A builder with `path`.
    static UriComponentsBuilder fromPath(string path) pure nothrow
    {
        auto builder = new UriComponentsBuilder;
        builder.path(path);
        return builder;
    }

    /// A builder initialized from a URI or URI template. Throws `IllegalArgumentException` when it cannot be parsed.
    static UriComponentsBuilder fromUriString(string uri) pure
    {
        auto builder = new UriComponentsBuilder;
        string rest = uri;
        // fragment
        foreach (i, c; rest)
            if (c == '#')
            {
                builder.fragmentValue = rest[i + 1 .. $];
                rest = rest[0 .. i];
                break;
            }
        // query
        foreach (i, c; rest)
            if (c == '?')
            {
                builder.query(rest[i + 1 .. $]);
                rest = rest[0 .. i];
                break;
            }
        // scheme
        foreach (i, c; rest)
        {
            if (c == ':' && i > 0)
            {
                builder.schemeValue = rest[0 .. i];
                rest = rest[i + 1 .. $];
                break;
            }
            if (!(isAlpha(c) || (i > 0 && (isDigit(c) || c == '+' || c == '-' || c == '.'))))
                break;
        }
        // authority
        if (rest.length >= 2 && rest[0 .. 2] == "//")
        {
            rest = rest[2 .. $];
            size_t end = rest.length;
            foreach (i, c; rest)
                if (c == '/')
                {
                    end = i;
                    break;
                }
            auto authority = rest[0 .. end];
            rest = rest[end .. $];
            foreach_reverse (i, c; authority)
                if (c == '@')
                {
                    builder.userInfoValue = authority[0 .. i];
                    authority = authority[i + 1 .. $];
                    break;
                }
            if (authority.length != 0 && authority[0] == '[')
            {
                size_t close = authority.length;
                foreach (i, c; authority)
                    if (c == ']')
                    {
                        close = i;
                        break;
                    }
                if (close == authority.length)
                    throw new IllegalArgumentException("Invalid IPv6 host in [" ~ uri ~ "]");
                builder.hostValue = authority[0 .. close + 1];
                authority = authority[close + 1 .. $];
                if (authority.length != 0 && authority[0] == ':')
                    builder.portValue = authority[1 .. $];
            }
            else
            {
                foreach_reverse (i, c; authority)
                    if (c == ':')
                    {
                        builder.portValue = authority[i + 1 .. $];
                        authority = authority[0 .. i];
                        break;
                    }
                builder.hostValue = authority;
            }
            if (builder.portValue !is null)
                foreach (c; builder.portValue)
                    if (!isDigit(c) && builder.portValue[0] != '{')
                        throw new IllegalArgumentException("[" ~ uri ~ "] is not a valid URI");
        }
        if (rest.length != 0)
            builder.pathValue = rest;
        return builder;
    }

    /// Sets the scheme.
    UriComponentsBuilder scheme(string scheme) pure nothrow @nogc
    {
        schemeValue = scheme;
        return this;
    }

    /// Sets the user info.
    UriComponentsBuilder userInfo(string userInfo) pure nothrow @nogc
    {
        userInfoValue = userInfo;
        return this;
    }

    /// Sets the host.
    UriComponentsBuilder host(string host) pure nothrow @nogc
    {
        hostValue = host;
        return this;
    }

    /// Sets the port; `-1` clears it.
    UriComponentsBuilder port(int port) pure nothrow
    {
        import std.conv : to;

        portValue = port < 0 ? null : port.to!string;
        return this;
    }

    /// Sets the port as text (a URI variable allowed).
    UriComponentsBuilder port(string port) pure nothrow @nogc
    {
        portValue = port;
        return this;
    }

    /// Appends `path`, joining slashes as Spring's `FullPathComponentBuilder` does.
    UriComponentsBuilder path(string path) pure nothrow
    {
        if (path.length == 0)
            return this;
        if (pathValue.length == 0)
            pathValue = path;
        else
        {
            const endsWithSlash = pathValue[$ - 1] == '/';
            const startsWithSlash = path[0] == '/';
            pathValue = endsWithSlash && startsWithSlash ? pathValue ~ path[1 .. $]
                : !endsWithSlash && !startsWithSlash ? pathValue ~ "/" ~ path : pathValue ~ path;
        }
        return this;
    }

    /// Appends path segments, each as one segment.
    UriComponentsBuilder pathSegment(string[] pathSegments...) pure nothrow
    {
        foreach (segment; pathSegments)
        {
            if (segment.length == 0)
                continue;
            string trimmed = segment;
            while (trimmed.length != 0 && trimmed[0] == '/')
                trimmed = trimmed[1 .. $];
            while (trimmed.length != 0 && trimmed[$ - 1] == '/')
                trimmed = trimmed[0 .. $ - 1];
            path("/" ~ trimmed);
        }
        return this;
    }

    /// Replaces the path.
    UriComponentsBuilder replacePath(string path) pure nothrow @nogc
    {
        pathValue = path;
        return this;
    }

    /// Parses `query` into parameters and appends them.
    UriComponentsBuilder query(string query) pure nothrow
    {
        if (query is null)
            return this;
        size_t start;
        foreach (i; 0 .. query.length + 1)
        {
            if (i == query.length || query[i] == '&')
            {
                auto pair = query[start .. i];
                start = i + 1;
                if (pair.length == 0)
                    continue;
                ptrdiff_t eq = -1;
                foreach (k, c; pair)
                    if (c == '=')
                    {
                        eq = k;
                        break;
                    }
                queryParamsValue ~= eq < 0 ? [pair, cast(string) null] : [pair[0 .. eq], pair[eq + 1 .. $]];
            }
        }
        return this;
    }

    /// Replaces the query.
    UriComponentsBuilder replaceQuery(string query) pure nothrow
    {
        queryParamsValue = null;
        return this.query(query);
    }

    /// Appends a query parameter with each value (a name alone when there are none).
    UriComponentsBuilder queryParam(string name, string[] values...) pure nothrow
    {
        if (values.length == 0)
            queryParamsValue ~= [name, cast(string) null];
        foreach (value; values)
            queryParamsValue ~= [name, value];
        return this;
    }

    /// Replaces a query parameter's values.
    UriComponentsBuilder replaceQueryParam(string name, string[] values...) pure nothrow
    {
        string[2][] kept;
        foreach (pair; queryParamsValue)
            if (pair[0] != name)
                kept ~= pair;
        queryParamsValue = kept;
        if (values.length != 0)
            queryParam(name, values);
        return this;
    }

    /// Sets the fragment.
    UriComponentsBuilder fragment(string fragment) pure nothrow @nogc
    {
        fragmentValue = fragment;
        return this;
    }

    /// The components, not encoded.
    UriComponents build() const pure nothrow
    {
        return build(false);
    }

    /// The components; `encoded` declares them already encoded.
    UriComponents build(bool encoded) const pure nothrow
    {
        auto result = new UriComponents;
        result.scheme = schemeValue;
        result.userInfo = userInfoValue;
        result.host = hostValue;
        result.port = portValue;
        result.path = pathValue;
        result.queryParams = queryParamsValue.dup;
        result.fragment = fragmentValue;
        result.encoded = encoded;
        return result;
    }

    /// `build().expand(values)`.
    UriComponents buildAndExpand(string[] values...) const pure
    {
        return build().expand(values);
    }

    /// `encode()` as Spring's builder does: template literals encoded now, variables when expanded.
    UriComponents encodeAndBuild() const pure
    {
        return build().encode();
    }

    /// `build().encode().toUriString()`.
    string toUriString() const pure
    {
        return build().encode().toUriString();
    }

    /// A copy of this builder.
    UriComponentsBuilder cloneBuilder() const pure nothrow
    {
        auto copy = new UriComponentsBuilder;
        copy.schemeValue = schemeValue;
        copy.userInfoValue = userInfoValue;
        copy.hostValue = hostValue;
        copy.portValue = portValue;
        copy.pathValue = pathValue;
        copy.queryParamsValue = queryParamsValue.dup;
        copy.fragmentValue = fragmentValue;
        return copy;
    }
}
