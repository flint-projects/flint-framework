/++
`org.springframework.web.cors`: CORS configuration and request processing.

Ported from spring-projects/spring-framework v7.1.0, spring-web/src/main/java/org/springframework/web/cors/
(CorsConfiguration.java, CorsConfigurationSource.java, CorsProcessor.java, DefaultCorsProcessor.java,
CorsUtils.java, UrlBasedCorsConfigurationSource.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. Lists are D arrays (R10); `@Nullable Boolean`
and `Long` are `Nullable!T` (R5). Origin patterns are Spring's `OriginPattern`, matched without
`java.util.regex`.
+/
module flint.web.cors;

import flint.http : HttpHeaders, HttpMethod, HttpStatus;
import flint.http.server : ServletServerHttpRequest, ServletServerHttpResponse;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.java.lang : IllegalArgumentException;
import flint.web.util.pattern : PathPattern, PathPatternParser;
import std.typecons : Nullable, nullable;

@safe:

/++
`CorsConfiguration`: the CORS policy of a handler or path.

Java tells a `null` list apart from an empty one, and so does this port: a getter returns `null` for an unset list and a
non-null empty slice for an empty one. Spring's permit-default lists (`DEFAULT_PERMIT_ALL`, `DEFAULT_PERMIT_METHODS`),
which it compares by identity, are flags here. `@Nullable Boolean` and `Long` are `Nullable!T` (R5). An origin pattern
is Spring's `OriginPattern`: `*` matches any text and a trailing `:[*]` or `:[8080,8081]` port list is optional or
fixed, matched without `java.util.regex`.
+/
final class CorsConfiguration
{
    /// Wildcard representing all origins, methods, or headers.
    enum string ALL = "*";

    private string[] allowedOrigins;
    private bool hasAllowedOrigins;
    private bool originsPermitDefault;
    private OriginPattern[] allowedOriginPatterns;
    private bool hasAllowedOriginPatterns;
    private string[] allowedMethods;
    private bool hasAllowedMethods;
    private bool methodsPermitDefault;
    private HttpMethod[] resolvedMethods;
    /// Java's `resolvedMethods == null`: every method is allowed.
    private bool resolvedMethodsAll;
    private string[] allowedHeaders;
    private bool hasAllowedHeaders;
    private bool headersPermitDefault;
    private string[] exposedHeaders;
    private bool hasExposedHeaders;
    private Nullable!bool allowCredentials;
    private Nullable!bool allowPrivateNetwork;
    private Nullable!long maxAge;

    /// A configuration with nothing set: no origin is allowed, and GET and HEAD are the methods.
    this() pure nothrow
    {
        resolvedMethods = defaultMethods[].dup;
    }

    /// A copy of `other`.
    this(const CorsConfiguration other) pure nothrow
    {
        allowedOrigins = other.allowedOrigins.dup;
        hasAllowedOrigins = other.hasAllowedOrigins;
        originsPermitDefault = other.originsPermitDefault;
        allowedOriginPatterns = other.allowedOriginPatterns.dup;
        hasAllowedOriginPatterns = other.hasAllowedOriginPatterns;
        allowedMethods = other.allowedMethods.dup;
        hasAllowedMethods = other.hasAllowedMethods;
        methodsPermitDefault = other.methodsPermitDefault;
        resolvedMethods = other.resolvedMethods.dup;
        resolvedMethodsAll = other.resolvedMethodsAll;
        allowedHeaders = other.allowedHeaders.dup;
        hasAllowedHeaders = other.hasAllowedHeaders;
        headersPermitDefault = other.headersPermitDefault;
        exposedHeaders = other.exposedHeaders.dup;
        hasExposedHeaders = other.hasExposedHeaders;
        allowCredentials = other.allowCredentials;
        allowPrivateNetwork = other.allowPrivateNetwork;
        maxAge = other.maxAge;
    }

    /// Sets the origins to allow (`*` for all), each optionally a comma-delimited list; `null` unsets them.
    void setAllowedOrigins(const(string)[] origins) pure nothrow
    {
        allowedOrigins = null;
        hasAllowedOrigins = origins !is null;
        originsPermitDefault = false;
        foreach (origin; origins)
            addAllowedOrigin(origin);
    }

    /// The allowed origins, or `null`.
    const(string)[] getAllowedOrigins() const pure nothrow @nogc
    {
        return listOf(allowedOrigins, hasAllowedOrigins);
    }

    /// Adds an origin, or a comma-delimited list of them; a trailing `/` is removed.
    void addAllowedOrigin(string origin) pure nothrow
    {
        if (origin is null)
            return;
        // Spring copies DEFAULT_PERMIT_ALL before adding to it, so the list stops being the permit default.
        originsPermitDefault = false;
        hasAllowedOrigins = true;
        foreach (value; commaDelimitedOrigins(origin))
            allowedOrigins ~= trimTrailingSlash(value);
    }

    /// Sets the origin patterns, each optionally a comma-delimited list; `null` unsets them.
    CorsConfiguration setAllowedOriginPatterns(const(string)[] patterns) pure nothrow
    {
        allowedOriginPatterns = null;
        hasAllowedOriginPatterns = patterns !is null;
        foreach (pattern; patterns)
            addAllowedOriginPattern(pattern);
        return this;
    }

    /// The origin patterns as declared, or `null`.
    const(string)[] getAllowedOriginPatterns() const pure nothrow
    {
        if (!hasAllowedOriginPatterns)
            return null;
        string[] declared;
        foreach (ref pattern; allowedOriginPatterns)
            declared ~= pattern.declared;
        return listOf(declared, true);
    }

    /// Adds an origin pattern, or a comma-delimited list of them (a `[8080,8081]` port list is one pattern).
    void addAllowedOriginPattern(string originPattern) pure nothrow
    {
        if (originPattern is null)
            return;
        hasAllowedOriginPatterns = true;
        foreach (value; commaDelimitedOrigins(originPattern))
        {
            allowedOriginPatterns ~= OriginPattern(trimTrailingSlash(value));
            if (originsPermitDefault)
            {
                allowedOrigins = null;
                hasAllowedOrigins = false;
                originsPermitDefault = false;
            }
        }
    }

    /// Sets the methods to allow (`*` for all); `null` or empty means GET and HEAD.
    void setAllowedMethods(const(string)[] methods) pure nothrow
    {
        allowedMethods = methods.dup;
        hasAllowedMethods = methods !is null;
        methodsPermitDefault = false;
        resolvedMethodsAll = false;
        if (methods.length == 0)
        {
            resolvedMethods = defaultMethods[].dup;
            return;
        }
        resolvedMethods = null;
        foreach (method; methods)
        {
            if (method == ALL)
            {
                resolvedMethods = null;
                resolvedMethodsAll = true;
                return;
            }
            resolvedMethods ~= HttpMethod.valueOf(method);
        }
    }

    /// The allowed methods, or `null`.
    const(string)[] getAllowedMethods() const pure nothrow @nogc
    {
        return listOf(allowedMethods, hasAllowedMethods);
    }

    /// Adds a method to allow; blank names are ignored.
    void addAllowedMethod(string method) pure nothrow
    {
        if (trim(method).length == 0)
            return;
        if (!hasAllowedMethods)
        {
            allowedMethods = null;
            hasAllowedMethods = true;
            resolvedMethods = null;
            resolvedMethodsAll = false;
        }
        else if (methodsPermitDefault)
            setAllowedMethods(permitMethods[]);
        allowedMethods ~= method;
        if (method == ALL)
        {
            resolvedMethods = null;
            resolvedMethodsAll = true;
        }
        else if (!resolvedMethodsAll)
            resolvedMethods ~= HttpMethod.valueOf(method);
    }

    /// ditto
    void addAllowedMethod(HttpMethod method) pure nothrow
    {
        addAllowedMethod(method.name());
    }

    /// Sets the request headers a preflight may list (`*` for all); `null` unsets them.
    void setAllowedHeaders(const(string)[] headers) pure nothrow
    {
        allowedHeaders = headers.dup;
        hasAllowedHeaders = headers !is null;
        headersPermitDefault = false;
    }

    /// The allowed headers, or `null`.
    const(string)[] getAllowedHeaders() const pure nothrow @nogc
    {
        return listOf(allowedHeaders, hasAllowedHeaders);
    }

    /// Adds an allowed header.
    void addAllowedHeader(string header) pure nothrow
    {
        if (!hasAllowedHeaders || headersPermitDefault)
        {
            // A first header, or a copy of DEFAULT_PERMIT_ALL to add to.
            allowedHeaders = headersPermitDefault ? [ALL] : null;
            hasAllowedHeaders = true;
            headersPermitDefault = false;
        }
        allowedHeaders ~= header;
    }

    /// Sets the response headers to expose (`*` for all, without credentials); `null` unsets them.
    void setExposedHeaders(const(string)[] headers) pure nothrow
    {
        exposedHeaders = headers.dup;
        hasExposedHeaders = headers !is null;
    }

    /// The exposed headers, or `null`.
    const(string)[] getExposedHeaders() const pure nothrow @nogc
    {
        return listOf(exposedHeaders, hasExposedHeaders);
    }

    /// Adds an exposed header.
    void addExposedHeader(string header) pure nothrow
    {
        exposedHeaders ~= header;
        hasExposedHeaders = true;
    }

    /// Whether user credentials are supported; an unset value means no.
    void setAllowCredentials(Nullable!bool allowCredentials) pure nothrow @nogc
    {
        this.allowCredentials = allowCredentials;
    }

    /// ditto
    void setAllowCredentials(bool allowCredentials) pure nothrow @nogc
    {
        this.allowCredentials = allowCredentials;
    }

    /// Whether user credentials are supported, if set.
    Nullable!bool getAllowCredentials() const pure nothrow @nogc
    {
        return allowCredentials;
    }

    /// Whether private-network access is allowed; an unset value means no.
    void setAllowPrivateNetwork(Nullable!bool allowPrivateNetwork) pure nothrow @nogc
    {
        this.allowPrivateNetwork = allowPrivateNetwork;
    }

    /// ditto
    void setAllowPrivateNetwork(bool allowPrivateNetwork) pure nothrow @nogc
    {
        this.allowPrivateNetwork = allowPrivateNetwork;
    }

    /// Whether private-network access is allowed, if set.
    Nullable!bool getAllowPrivateNetwork() const pure nothrow @nogc
    {
        return allowPrivateNetwork;
    }

    /// How long, in seconds, a client may cache a preflight response; unset leaves it to the client.
    void setMaxAge(Nullable!long maxAge) pure nothrow @nogc
    {
        this.maxAge = maxAge;
    }

    /// ditto
    void setMaxAge(long maxAge) pure nothrow @nogc
    {
        this.maxAge = maxAge;
    }

    /// The preflight cache duration in seconds, if set.
    Nullable!long getMaxAge() const pure nothrow @nogc
    {
        return maxAge;
    }

    /// Spring's `applyPermitDefaultValues`: all origins (unless patterns are set), GET, HEAD and POST, all
    /// headers, and 1800 seconds, for whatever is unset. Later adds and combines replace these defaults.
    CorsConfiguration applyPermitDefaultValues() pure nothrow
    {
        if (!hasAllowedOrigins && !hasAllowedOriginPatterns)
        {
            allowedOrigins = [ALL];
            hasAllowedOrigins = true;
            originsPermitDefault = true;
        }
        if (!hasAllowedMethods)
        {
            setAllowedMethods(permitMethods[]);
            methodsPermitDefault = true;
        }
        if (!hasAllowedHeaders)
        {
            allowedHeaders = [ALL];
            hasAllowedHeaders = true;
            headersPermitDefault = true;
        }
        if (maxAge.isNull)
            maxAge = 1800L;
        return this;
    }

    /// Throws `IllegalArgumentException` when credentials are allowed together with the origin `*`.
    void validateAllowCredentials() const pure
    {
        if (!allowCredentials.isNull && allowCredentials.get && containsAll(allowedOrigins))// dfmt off
            throw new IllegalArgumentException("When allowCredentials is true, allowedOrigins cannot contain the "
                    ~ "special value \"*\" since that cannot be set on the \"Access-Control-Allow-Origin\" response "
                    ~ "header. To allow credentials to a set of origins, list them explicitly or consider using "
                    ~ "\"allowedOriginPatterns\" instead.");
            // dfmt on
    }

    /// Throws `IllegalArgumentException` when private-network access is allowed together with the origin `*`.
    void validateAllowPrivateNetwork() const pure
    {
        if (!allowPrivateNetwork.isNull && allowPrivateNetwork.get && containsAll(allowedOrigins))// dfmt off
            throw new IllegalArgumentException("When allowPrivateNetwork is true, allowedOrigins cannot contain the "
                    ~ "special value \"*\" as it is not recommended from a security perspective. To allow private "
                    ~ "network access to a set of origins, list them explicitly or consider using "
                    ~ "\"allowedOriginPatterns\" instead.");
            // dfmt on
    }

    /// Spring's `combine`: lists join without duplicates (`*` wins, permit defaults give way), and `other`'s
    /// credentials, private-network and max-age settings win when set. `null` returns this configuration.
    CorsConfiguration combine(const CorsConfiguration other) pure nothrow
    {
        if (other is null)
            return this;
        auto config = new CorsConfiguration(this);
        bool originsDefault = false;
        const origins = combineLists(getAllowedOrigins(), originsPermitDefault,
                other.getAllowedOrigins(), other.originsPermitDefault, originsDefault);
        const patterns = combinePatterns(other);
        if (originsDefault && patterns.length != 0)
        {
            config.allowedOrigins = null;
            config.hasAllowedOrigins = false;
            config.originsPermitDefault = false;
        }
        else
        {
            config.allowedOrigins = origins.dup;
            config.hasAllowedOrigins = true;
            config.originsPermitDefault = originsDefault;
        }
        // Spring's combinePatterns never returns null (an empty list when neither side has patterns).
        config.allowedOriginPatterns = patterns.dup;
        config.hasAllowedOriginPatterns = true;
        // The setters copy, so a combined method or header list is never the permit default by identity.
        bool unused;
        config.setAllowedMethods(nonNull(combineLists(getAllowedMethods(), methodsPermitDefault,
                other.getAllowedMethods(), other.methodsPermitDefault, unused)));
        config.setAllowedHeaders(nonNull(combineLists(getAllowedHeaders(), headersPermitDefault,
                other.getAllowedHeaders(), other.headersPermitDefault, unused)));
        config.setExposedHeaders(nonNull(combineLists(getExposedHeaders(), false,
                other.getExposedHeaders(), false, unused)));
        if (!other.allowCredentials.isNull)
            config.allowCredentials = other.allowCredentials;
        if (!other.allowPrivateNetwork.isNull)
            config.allowPrivateNetwork = other.allowPrivateNetwork;
        if (!other.maxAge.isNull)
            config.maxAge = other.maxAge;
        return config;
    }

    /// Spring's private `combine(List, List)`. `isDefault` reports that the result is a permit-default list.
    private static const(string)[] combineLists(const(string)[] source, bool sourceDefault,
            const(string)[] other, bool otherDefault, out bool isDefault) pure nothrow
    {
        if (other is null)
        {
            isDefault = sourceDefault;
            return source !is null ? source : emptyList;
        }
        if (source is null)
        {
            isDefault = otherDefault;
            return other;
        }
        if (sourceDefault)
        {
            isDefault = otherDefault;
            return other;
        }
        if (otherDefault)
            return source;
        if (containsAll(source) || containsAll(other))
            return [ALL];
        string[] combined;
        foreach (value; source ~ other)
        {
            bool seen;
            foreach (existing; combined)
                seen = seen || existing == value;
            if (!seen)
                combined ~= value;
        }
        return combined;
    }

    /// Spring's `combinePatterns`: patterns join without duplicates, and `*` wins.
    private const(OriginPattern)[] combinePatterns(const CorsConfiguration other) const pure nothrow
    {
        if (!other.hasAllowedOriginPatterns)
            return allowedOriginPatterns;
        if (!hasAllowedOriginPatterns)
            return other.allowedOriginPatterns;
        foreach (ref pattern; allowedOriginPatterns ~ other.allowedOriginPatterns)
            if (pattern.declared == ALL)
                return [OriginPattern(ALL)];
        OriginPattern[] combined;
        foreach (ref pattern; allowedOriginPatterns ~ other.allowedOriginPatterns)
        {
            bool seen;
            foreach (ref existing; combined)
                seen = seen || existing.declared == pattern.declared;
            if (!seen)
                combined ~= pattern;
        }
        return combined;
    }

    /// The origin to answer with for `origin`: `*`, the origin itself, or `null` when it is not allowed. Throws
    /// `IllegalArgumentException` when `*` meets allowed credentials or private-network access.
    string checkOrigin(string origin) const pure
    {
        if (trim(origin).length == 0)
            return null;
        const originToCheck = trimTrailingSlash(origin);
        if (allowedOrigins.length != 0)
        {
            if (containsAll(allowedOrigins))
            {
                validateAllowCredentials();
                validateAllowPrivateNetwork();
                return ALL;
            }
            foreach (allowed; allowedOrigins)
                if (equalsIgnoreCase(originToCheck, allowed))
                    return origin;
        }
        foreach (ref pattern; allowedOriginPatterns)
            if (pattern.declared == ALL || pattern.matches(originToCheck))
                return origin;
        return null;
    }

    /// The methods to list for a preflight of `requestMethod`, or `null` when it is not allowed.
    HttpMethod[] checkHttpMethod(Nullable!HttpMethod requestMethod) const pure nothrow
    {
        if (requestMethod.isNull)
            return null;
        if (resolvedMethodsAll)
            return [requestMethod.get];
        foreach (method; resolvedMethods)
            if (method == requestMethod.get)
                return resolvedMethods.dup;
        return null;
    }

    /// The headers to list for a preflight's `requestHeaders`, or `null` when none is allowed.
    string[] checkHeaders(const(string)[] requestHeaders) const pure nothrow
    {
        if (requestHeaders is null)
            return null;
        if (requestHeaders.length == 0)
            return (new string[1])[0 .. 0]; // non-null and empty, as Java's emptyList
        if (allowedHeaders.length == 0)
            return null;
        const allowAny = containsAll(allowedHeaders);
        string[] result;
        foreach (requestHeader; requestHeaders)
        {
            const header = trim(requestHeader);
            if (header.length == 0)
                continue;
            if (allowAny)
                result ~= header;
            else
                foreach (allowed; allowedHeaders)
                    if (equalsIgnoreCase(header, allowed))
                    {
                        result ~= header;
                        break;
                    }
        }
        return result.length == 0 ? null : result;
    }

    private static immutable HttpMethod[2] defaultMethods = [HttpMethod.GET, HttpMethod.HEAD];
    private static immutable string[3] permitMethods = ["GET", "HEAD", "POST"];
    private static immutable string[1] emptyStorage = [""];

    /// A non-null empty list, which Java tells apart from `null`.
    private static const(string)[] emptyList() pure nothrow @nogc
    {
        return emptyStorage[0 .. 0];
    }

    private static const(string)[] listOf(const(string)[] items, bool present) pure nothrow @nogc
    {
        return !present ? null : (items.length == 0 ? emptyList : items);
    }

    private static const(string)[] nonNull(const(string)[] items) pure nothrow @nogc
    {
        return items is null ? emptyList : items;
    }

    private static bool containsAll(scope const(string)[] values) pure nothrow @nogc
    {
        foreach (value; values)
            if (value == ALL)
                return true;
        return false;
    }
}

/// Spring's `CorsConfiguration.OriginPattern`: `*` matches any text, and a trailing `:[*]` makes a port optional
/// while `:[8080,8081]` requires one of the ports. Matching is case-sensitive, as Spring's regex is.
private struct OriginPattern
{
    string declared;
    private string base;
    private bool anyPort;
    private immutable(string)[] ports;

    this(string declared) pure nothrow
    {
        this.declared = declared;
        base = declared;
        // Spring's PORTS_PATTERN: (.*):\[(\*|\d+(,\d+)*)]
        if (declared.length < 4 || declared[$ - 1] != ']')
            return;
        size_t open = declared.length;
        foreach_reverse (index, c; declared)
            if (c == '[')
            {
                open = index;
                break;
            }
        if (open == declared.length || open == 0 || declared[open - 1] != ':')
            return;
        const list = declared[open + 1 .. $ - 1];
        if (list == "*")
            anyPort = true;
        else
        {
            foreach (port; splitComma(list))
            {
                if (port.length == 0)
                    return;
                foreach (c; port)
                    if (c < '0' || c > '9')
                        return;
            }
            ports = splitComma(list).idup;
        }
        base = declared[0 .. open - 1];
    }

    bool matches(string origin) const pure nothrow @nogc
    {
        if (!anyPort && ports is null)
            return wildcard(base, origin);
        // The text after the base must be empty (with `[*]`) or `:<port>`; try every split.
        foreach (cut; 0 .. origin.length + 1)
        {
            const rest = origin[cut .. $];
            bool acceptable;
            if (anyPort)
                acceptable = rest.length == 0 || (rest.length > 1 && rest[0] == ':' && allDigits(rest[1 .. $]));
            else
                foreach (port; ports)
                    acceptable = acceptable || (rest.length == port.length + 1 && rest[0] == ':' && rest[1 .. $] == port);
            if (acceptable && wildcard(base, origin[0 .. cut]))
                return true;
        }
        return false;
    }

    private static bool allDigits(scope const(char)[] text) pure nothrow @nogc
    {
        foreach (c; text)
            if (c < '0' || c > '9')
                return false;
        return true;
    }

    private static bool wildcard(scope const(char)[] pattern, scope const(char)[] text) pure nothrow @nogc
    {
        if (pattern.length == 0)
            return text.length == 0;
        if (pattern[0] == '*')
        {
            foreach (index; 0 .. text.length + 1)
                if (wildcard(pattern[1 .. $], text[index .. $]))
                    return true;
            return false;
        }
        return text.length != 0 && pattern[0] == text[0] && wildcard(pattern[1 .. $], text[1 .. $]);
    }
}

/// Spring's `parseCommaDelimitedOrigin`: split on commas outside a `[...]` port list, trimming each value.
private string[] commaDelimitedOrigins(string rawValue) pure nothrow
{
    bool comma;
    foreach (c; rawValue)
        comma = comma || c == ',';
    if (!comma)
        return [rawValue];
    string[] values;
    size_t start;
    bool withinPortRange;
    foreach (current, c; rawValue)
    {
        if (c == '[')
            withinPortRange = true;
        else if (c == ']')
            withinPortRange = false;
        else if (c == ',' && !withinPortRange)
        {
            values ~= trim(rawValue[start .. current]);
            start = current + 1;
        }
    }
    if (start < rawValue.length)
        values ~= trim(rawValue[start .. $]);
    return values;
}

private string trimTrailingSlash(string origin) pure nothrow @nogc
{
    return origin.length != 0 && origin[$ - 1] == '/' ? origin[0 .. $ - 1] : origin;
}

private string trim(string text) pure nothrow @nogc
{
    size_t start, end = text.length;
    while (start < end && text[start] <= ' ')
        start++;
    while (end > start && text[end - 1] <= ' ')
        end--;
    return text[start .. end];
}

private string[] splitComma(string text) pure nothrow
{
    string[] result;
    size_t start;
    foreach (i, c; text)
        if (c == ',')
        {
            result ~= text[start .. i];
            start = i + 1;
        }
    result ~= text[start .. $];
    return result;
}

/// `CorsConfigurationSource`.
interface CorsConfigurationSource
{
    /// The configuration for `request`, or `null`.
    CorsConfiguration getCorsConfiguration(HttpServletRequest request);
}

/// `CorsUtils`.
struct CorsUtils
{
    /// Whether the request carries an `Origin` other than its own.
    static bool isCorsRequest(HttpServletRequest request)
    {
        import std.conv : to;

        const origin = request.getHeader(HttpHeaders.ORIGIN);
        if (origin is null)
            return false;
        const scheme = request.getScheme();
        const port = request.getServerPort();
        const defaultPort = (scheme == "http" && port == 80) || (scheme == "https" && port == 443);
        const own = scheme ~ "://" ~ request.getServerName() ~ (defaultPort ? "" : ":" ~ port.to!string);
        return !equalsIgnoreCase(trimTrailingSlash(origin), own);
    }

    /// Whether the request is a CORS preflight.
    static bool isPreFlightRequest(HttpServletRequest request)
    {
        return request.getMethod() == "OPTIONS" && request.getHeader(HttpHeaders.ORIGIN) !is null
            && request.getHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD) !is null;
    }
}

/// `CorsProcessor`.
interface CorsProcessor
{
    /// Applies `config` to the response; `false` when the request was rejected.
    bool processRequest(CorsConfiguration config, HttpServletRequest request, HttpServletResponse response);
}

/// `DefaultCorsProcessor`.
class DefaultCorsProcessor : CorsProcessor
{
    package(flint.web) enum string ACCESS_CONTROL_REQUEST_PRIVATE_NETWORK = "Access-Control-Request-Private-Network";
    package(flint.web) enum string ACCESS_CONTROL_ALLOW_PRIVATE_NETWORK = "Access-Control-Allow-Private-Network";

    bool processRequest(CorsConfiguration config, HttpServletRequest request, HttpServletResponse response)
    {
        if (config is null)
            return true;
        auto varyHeaders = response.getHeaders(HttpHeaders.VARY);
        bool contains(string name)
        {
            foreach (v; varyHeaders)
                if (v == name)
                    return true;
            return false;
        }

        if (!contains(HttpHeaders.ORIGIN))
            response.addHeader(HttpHeaders.VARY, HttpHeaders.ORIGIN);
        if (!contains(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD))
            response.addHeader(HttpHeaders.VARY, HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD);
        if (!contains(HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS))
            response.addHeader(HttpHeaders.VARY, HttpHeaders.ACCESS_CONTROL_REQUEST_HEADERS);
        if (!CorsUtils.isCorsRequest(request))
            return true;
        if (response.getHeader(HttpHeaders.ACCESS_CONTROL_ALLOW_ORIGIN) !is null)
            return true;
        return handleInternal(new ServletServerHttpRequest(request),
                new ServletServerHttpResponse(response), config, CorsUtils.isPreFlightRequest(request));
    }

    /// 403 with `Invalid CORS request`.
    protected void rejectRequest(ServletServerHttpResponse response)
    {
        response.setStatusCode(HttpStatus.FORBIDDEN);
        response.writeBody(cast(const(ubyte)[]) "Invalid CORS request");
        response.flush();
    }

    /// The CORS response headers of an accepted request, in Spring's order.
    private void addCorsHeaders(ServletServerHttpRequest request, HttpHeaders responseHeaders, CorsConfiguration config,
            bool preFlightRequest, string allowOrigin, HttpMethod[] allowMethods, string[] allowHeaders)
    {
        responseHeaders.setAccessControlAllowOrigin(allowOrigin);
        if (preFlightRequest)
            responseHeaders.setAccessControlAllowMethods(allowMethods);
        if (preFlightRequest && allowHeaders.length != 0)
            responseHeaders.setAccessControlAllowHeaders(allowHeaders);
        if (config.getExposedHeaders().length != 0)
            responseHeaders.setAccessControlExposeHeaders(config.getExposedHeaders());
        if (!config.getAllowCredentials().isNull && config.getAllowCredentials().get)
            responseHeaders.setAccessControlAllowCredentials(true);
        // Private Network Access: answer a request that asks, when the configuration allows it.
        if (!config.getAllowPrivateNetwork().isNull && config.getAllowPrivateNetwork().get
                && equalsIgnoreCase(request.getHeaders().getFirst(ACCESS_CONTROL_REQUEST_PRIVATE_NETWORK), "true"))
            responseHeaders.set(ACCESS_CONTROL_ALLOW_PRIVATE_NETWORK, "true");
        if (preFlightRequest && !config.getMaxAge().isNull)
            responseHeaders.setAccessControlMaxAge(config.getMaxAge().get);
    }

    /// Spring's `handleInternal`.
    protected bool handleInternal(ServletServerHttpRequest request,
            ServletServerHttpResponse response, CorsConfiguration config, bool preFlightRequest)
    {
        const requestOrigin = request.getHeaders().getOrigin();
        const allowOrigin = config.checkOrigin(requestOrigin);
        auto responseHeaders = response.getHeaders();
        if (allowOrigin is null)
        {
            rejectRequest(response);
            return false;
        }
        Nullable!HttpMethod requestMethod;
        if (preFlightRequest)
        {
            if (auto m = request.getHeaders().getAccessControlRequestMethod())
                requestMethod = *m;
        }
        else
            requestMethod = request.getMethod();
        auto allowMethods = config.checkHttpMethod(requestMethod);
        if (allowMethods is null)
        {
            rejectRequest(response);
            return false;
        }
        auto requestHeaders = preFlightRequest ? request.getHeaders()
            .getAccessControlRequestHeaders() : request.getHeaders().headerNames();
        // Spring's header lists are never null: an absent or empty Access-Control-Request-Headers is an empty
        // list, which every configuration allows. D's empty array is null, so make it a non-null empty one.
        if (requestHeaders is null)
            requestHeaders = (new string[1])[0 .. 0];
        auto allowHeaders = config.checkHeaders(requestHeaders);
        if (preFlightRequest && allowHeaders is null)
        {
            rejectRequest(response);
            return false;
        }
        addCorsHeaders(request, responseHeaders, config, preFlightRequest, allowOrigin, allowMethods, allowHeaders);
        response.flush();
        return true;
    }
}

/// `UrlBasedCorsConfigurationSource`: configurations by path pattern (Boot's `CorsRegistry`).
class UrlBasedCorsConfigurationSource : CorsConfigurationSource
{
    private static struct Entry
    {
        PathPattern pattern;
        CorsConfiguration config;
    }

    private Entry[] entries;

    /// Registers `config` for `pattern`.
    void registerCorsConfiguration(string pattern, CorsConfiguration config)
    {
        entries ~= Entry(new PathPatternParser().parse(pattern), config);
    }

    /// Whether any configuration is registered.
    bool isEmpty() const pure nothrow @nogc
    {
        return entries.length == 0;
    }

    CorsConfiguration getCorsConfiguration(HttpServletRequest request)
    {
        auto path = request.getRequestURI();
        const contextPath = request.getContextPath();
        const underContext = contextPath.length != 0 && path.length >= contextPath.length
            && path[0 .. contextPath.length] == contextPath;
        if (underContext)
            path = path[contextPath.length .. $];
        foreach (entry; entries)
            if (entry.pattern.matches(path))
                return entry.config;
        return null;
    }
}

/// Java's `String.equalsIgnoreCase` for ASCII header and origin text.
private bool equalsIgnoreCase(scope const(char)[] a, scope const(char)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (index, c; a)
    {
        const x = c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
        const y = b[index] >= 'A' && b[index] <= 'Z' ? cast(char)(b[index] + 32) : b[index];
        if (x != y)
            return false;
    }
    return true;
}
