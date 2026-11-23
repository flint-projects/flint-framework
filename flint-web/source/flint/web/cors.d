/++
`org.springframework.web.cors`: CORS configuration and request processing.

Ported from spring-projects/spring-framework v7.1.0, spring-web/src/main/java/org/springframework/web/cors/
(CorsConfiguration.java, CorsConfigurationSource.java, CorsProcessor.java, DefaultCorsProcessor.java,
CorsUtils.java, UrlBasedCorsConfigurationSource.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. Lists are D arrays (R10); `@Nullable Boolean`
and `Long` are `Nullable!T` (R5). Origin patterns support `*` wildcards and `[port]` lists through a small matcher
instead of `java.util.regex`.
+/
module flint.web.cors;

import flint.http : HttpHeaders, HttpMethod, HttpStatus;
import flint.http.server : ServletServerHttpRequest, ServletServerHttpResponse;
import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.java.lang : IllegalArgumentException;
import flint.util : equalsIgnoreCase;
import flint.web.util.pattern : PathPattern, PathPatternParser;
import std.typecons : Nullable, nullable;

@safe:

/// `CorsConfiguration`.
final class CorsConfiguration
{
    /// `*`.
    enum string ALL = "*";

    private string[] allowedOrigins;
    private bool allowedOriginsSet;
    private string[] allowedOriginPatterns;
    private string[] allowedMethods;
    private bool allowedMethodsSet;
    private HttpMethod[] resolvedMethods;
    private bool resolvedMethodsAll;
    private string[] allowedHeaders;
    private bool allowedHeadersSet;
    private string[] exposedHeaders;
    private Nullable!bool allowCredentials;
    private Nullable!bool allowPrivateNetwork;
    private Nullable!long maxAge;
    private bool permitAllOrigins; // DEFAULT_PERMIT_ALL identity, as Spring compares it

    ///
    this() pure nothrow
    {
        resolvedMethods = [HttpMethod.GET, HttpMethod.HEAD];
    }

    /// A copy of `other`.
    this(const CorsConfiguration other) pure nothrow
    {
        allowedOrigins = other.allowedOrigins.dup;
        allowedOriginsSet = other.allowedOriginsSet;
        allowedOriginPatterns = other.allowedOriginPatterns.dup;
        allowedMethods = other.allowedMethods.dup;
        allowedMethodsSet = other.allowedMethodsSet;
        resolvedMethods = other.resolvedMethods.dup;
        resolvedMethodsAll = other.resolvedMethodsAll;
        allowedHeaders = other.allowedHeaders.dup;
        allowedHeadersSet = other.allowedHeadersSet;
        exposedHeaders = other.exposedHeaders.dup;
        allowCredentials = other.allowCredentials;
        allowPrivateNetwork = other.allowPrivateNetwork;
        maxAge = other.maxAge;
        permitAllOrigins = other.permitAllOrigins;
    }

    /// Sets the allowed origins (trailing slashes removed).
    void setAllowedOrigins(string[] origins) pure nothrow
    {
        allowedOrigins = null;
        foreach (o; origins)
            allowedOrigins ~= trimTrailingSlash(o);
        allowedOriginsSet = origins !is null;
        permitAllOrigins = false;
    }

    /// The allowed origins, or `null`.
    const(string)[] getAllowedOrigins() const pure nothrow @nogc
    {
        return allowedOriginsSet ? allowedOrigins : null;
    }

    /// Adds an allowed origin.
    void addAllowedOrigin(string origin) pure nothrow
    {
        if (permitAllOrigins)
        {
            allowedOrigins = null;
            permitAllOrigins = false;
        }
        allowedOrigins ~= trimTrailingSlash(origin);
        allowedOriginsSet = true;
    }

    /// Sets the allowed origin patterns.
    void setAllowedOriginPatterns(string[] patterns) pure nothrow
    {
        allowedOriginPatterns = null;
        foreach (p; patterns)
            allowedOriginPatterns ~= trimTrailingSlash(p);
    }

    /// The allowed origin patterns, or `null`.
    const(string)[] getAllowedOriginPatterns() const pure nothrow @nogc
    {
        return allowedOriginPatterns;
    }

    /// Sets the allowed methods; `*` allows every method.
    void setAllowedMethods(string[] methods) pure nothrow
    {
        allowedMethods = methods.dup;
        allowedMethodsSet = methods !is null;
        resolvedMethods = null;
        resolvedMethodsAll = false;
        if (methods.length == 0)
        {
            resolvedMethods = [HttpMethod.GET, HttpMethod.HEAD];
            return;
        }
        foreach (m; methods)
        {
            if (m == ALL)
            {
                resolvedMethodsAll = true;
                resolvedMethods = null;
                return;
            }
            resolvedMethods ~= HttpMethod.valueOf(m);
        }
    }

    /// Adds an allowed method.
    void addAllowedMethod(string method) pure nothrow
    {
        setAllowedMethods(allowedMethods ~ method);
    }

    /// The allowed methods, or `null`.
    const(string)[] getAllowedMethods() const pure nothrow @nogc
    {
        return allowedMethodsSet ? allowedMethods : null;
    }

    /// Sets the allowed request headers.
    void setAllowedHeaders(string[] headers) pure nothrow
    {
        allowedHeaders = headers.dup;
        allowedHeadersSet = headers !is null;
    }

    /// Adds an allowed header.
    void addAllowedHeader(string header) pure nothrow
    {
        allowedHeaders ~= header;
        allowedHeadersSet = true;
    }

    /// The allowed headers, or `null`.
    const(string)[] getAllowedHeaders() const pure nothrow @nogc
    {
        return allowedHeadersSet ? allowedHeaders : null;
    }

    /// Sets the exposed response headers.
    void setExposedHeaders(string[] headers) pure nothrow
    {
        exposedHeaders = headers.dup;
    }

    /// Adds an exposed header.
    void addExposedHeader(string header) pure nothrow
    {
        exposedHeaders ~= header;
    }

    /// The exposed headers, or `null`.
    const(string)[] getExposedHeaders() const pure nothrow @nogc
    {
        return exposedHeaders;
    }

    /// Sets whether credentials are supported.
    void setAllowCredentials(bool allowCredentials) pure nothrow @nogc
    {
        this.allowCredentials = allowCredentials;
    }

    /// Whether credentials are supported, if set.
    Nullable!bool getAllowCredentials() const pure nothrow @nogc
    {
        return allowCredentials;
    }

    /// Sets whether private-network access is allowed.
    void setAllowPrivateNetwork(bool allowPrivateNetwork) pure nothrow @nogc
    {
        this.allowPrivateNetwork = allowPrivateNetwork;
    }

    /// Sets the preflight cache duration in seconds.
    void setMaxAge(long maxAge) pure nothrow @nogc
    {
        this.maxAge = maxAge;
    }

    /// The preflight cache duration, if set.
    Nullable!long getMaxAge() const pure nothrow @nogc
    {
        return maxAge;
    }

    /// Spring's `applyPermitDefaultValues`: all origins, GET/HEAD/POST, all headers, 1800 seconds.
    CorsConfiguration applyPermitDefaultValues() pure nothrow
    {
        if (!allowedOriginsSet && allowedOriginPatterns is null)
        {
            allowedOrigins = [ALL];
            allowedOriginsSet = true;
            permitAllOrigins = true;
        }
        if (!allowedMethodsSet)
        {
            allowedMethods = ["GET", "HEAD", "POST"];
            allowedMethodsSet = true;
            resolvedMethods = [HttpMethod.GET, HttpMethod.HEAD, HttpMethod.POST];
            resolvedMethodsAll = false;
        }
        if (!allowedHeadersSet)
        {
            allowedHeaders = [ALL];
            allowedHeadersSet = true;
        }
        if (maxAge.isNull)
            maxAge = 1800L;
        return this;
    }

    /// Spring's `combine`: list values join (`*` wins), scalars from `other` override.
    CorsConfiguration combine(const CorsConfiguration other) const pure nothrow
    {
        if (other is null)
            return new CorsConfiguration(this);
        auto config = new CorsConfiguration(this);
        auto origins = combineLists(getAllowedOrigins(), other.getAllowedOrigins(), permitAllOrigins, other.permitAllOrigins);
        auto patterns = combineLists(allowedOriginPatterns, other.allowedOriginPatterns, false, false);
        if (origins.length == 1 && origins[0] == ALL && permitAllOrigins && patterns.length != 0)
        {
            config.allowedOrigins = null;
            config.allowedOriginsSet = false;
        }
        else
        {
            config.allowedOrigins = origins.dup;
            config.allowedOriginsSet = origins !is null;
        }
        config.permitAllOrigins = permitAllOrigins && other.permitAllOrigins;
        config.allowedOriginPatterns = patterns.dup;
        auto methods = combineLists(getAllowedMethods(), other.getAllowedMethods(), false, false);
        if (methods !is null)
            config.setAllowedMethods(methods.dup);
        auto headers = combineLists(getAllowedHeaders(), other.getAllowedHeaders(), false, false);
        config.allowedHeaders = headers.dup;
        config.allowedHeadersSet = headers !is null;
        config.exposedHeaders = combineLists(exposedHeaders, other.exposedHeaders, false, false).dup;
        if (!other.allowCredentials.isNull)
            config.allowCredentials = other.allowCredentials;
        if (!other.allowPrivateNetwork.isNull)
            config.allowPrivateNetwork = other.allowPrivateNetwork;
        if (!other.maxAge.isNull)
            config.maxAge = other.maxAge;
        return config;
    }

    private static const(string)[] combineLists(const(string)[] source, const(string)[] other, bool sourceDefault,
            bool otherDefault) pure nothrow
    {
        if (other is null)
            return source;
        if (source is null)
            return other;
        if (sourceDefault)
            return other;
        if (otherDefault)
            return source;
        foreach (s; source)
            if (s == ALL)
                return [ALL];
        foreach (o; other)
            if (o == ALL)
                return [ALL];
        string[] combined = source.dup;
        foreach (o; other)
        {
            bool seen;
            foreach (c; combined)
                seen = seen || c == o;
            if (!seen)
                combined ~= o;
        }
        return combined;
    }

    /// Rejects `allowCredentials` with origin `*`. Throws `IllegalArgumentException`.
    void validateAllowCredentials() const pure
    {
        if (!allowCredentials.isNull && allowCredentials.get)
            foreach (o; allowedOrigins)
                if (o == ALL)
                    throw new IllegalArgumentException("When allowCredentials is true, allowedOrigins cannot contain the "
                            ~ "special value \"*\" since that cannot be set on the \"Access-Control-Allow-Origin\" response "
                            ~ "header. To allow credentials to a set of origins, list them explicitly or consider using "
                            ~ "\"allowedOriginPatterns\" instead.");
    }

    /// The origin to answer for `origin`, or `null` when it is not allowed.
    string checkOrigin(string origin) const pure
    {
        if (origin.length == 0)
            return null;
        const originToCheck = trimTrailingSlash(origin);
        foreach (allowed; allowedOrigins)
            if (allowed == ALL)
            {
                validateAllowCredentials();
                return ALL;
            }
        foreach (allowed; allowedOrigins)
            if (equalsIgnoreCase(originToCheck, allowed))
                return origin;
        foreach (pattern; allowedOriginPatterns)
            if (pattern == ALL || originMatches(pattern, originToCheck))
                return origin;
        return null;
    }

    /// The methods to list for `requestMethod`, or `null` when it is not allowed.
    HttpMethod[] checkHttpMethod(Nullable!HttpMethod requestMethod) const pure nothrow
    {
        if (requestMethod.isNull)
            return null;
        if (resolvedMethodsAll)
            return [requestMethod.get];
        foreach (m; resolvedMethods)
            if (m == requestMethod.get)
                return resolvedMethods.dup;
        return null;
    }

    /// The headers to list for `requestHeaders`, or `null` when any is not allowed.
    string[] checkHeaders(const(string)[] requestHeaders) const pure nothrow
    {
        if (requestHeaders is null)
            return null;
        if (requestHeaders.length == 0)
            return [];
        if (allowedHeaders.length == 0)
            return null;
        bool allowAny;
        foreach (h; allowedHeaders)
            allowAny = allowAny || h == ALL;
        string[] result;
        foreach (requestHeader; requestHeaders)
        {
            auto header = trim(requestHeader);
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

    private static bool originMatches(string pattern, string origin) pure nothrow
    {
        // "https://*.example.com" and "http://localhost:[8080,8081]" / "[*]".
        string ports;
        string base = pattern;
        if (pattern.length != 0 && pattern[$ - 1] == ']')
        {
            foreach_reverse (i, c; pattern)
                if (c == '[')
                {
                    ports = pattern[i + 1 .. $ - 1];
                    base = pattern[0 .. i];
                    if (base.length != 0 && base[$ - 1] == ':')
                        base = base[0 .. $ - 1];
                    break;
                }
        }
        string originBase = origin;
        string originPort;
        if (ports !is null)
        {
            foreach_reverse (i, c; origin)
            {
                if (c == ':')
                {
                    originPort = origin[i + 1 .. $];
                    originBase = origin[0 .. i];
                    break;
                }
                if (c == '/')
                    break;
            }
            if (ports != "*")
            {
                bool found;
                foreach (p; splitComma(ports))
                    found = found || trim(p) == originPort;
                if (!found)
                    return false;
            }
        }
        return wildcardMatch(base, originBase);
    }

    private static bool wildcardMatch(string pattern, string text) pure nothrow @nogc
    {
        if (pattern.length == 0)
            return text.length == 0;
        if (pattern[0] == '*')
        {
            foreach (i; 0 .. text.length + 1)
                if (wildcardMatch(pattern[1 .. $], text[i .. $]))
                    return true;
            return false;
        }
        return text.length != 0 && (pattern[0] | 0x20) == (text[0] | 0x20) && wildcardMatch(pattern[1 .. $], text[1 .. $]);
    }
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
        return handleInternal(new ServletServerHttpRequest(request), new ServletServerHttpResponse(response), config,
                CorsUtils.isPreFlightRequest(request));
    }

    /// 403 with `Invalid CORS request`.
    protected void rejectRequest(ServletServerHttpResponse response)
    {
        response.setStatusCode(HttpStatus.FORBIDDEN);
        response.writeBody(cast(const(ubyte)[]) "Invalid CORS request");
        response.flush();
    }

    /// Spring's `handleInternal`.
    protected bool handleInternal(ServletServerHttpRequest request, ServletServerHttpResponse response,
            CorsConfiguration config, bool preFlightRequest)
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
        auto requestHeaders = preFlightRequest ? request.getHeaders().getAccessControlRequestHeaders()
            : request.getHeaders().headerNames();
        auto allowHeaders = config.checkHeaders(requestHeaders);
        if (preFlightRequest && allowHeaders is null)
        {
            rejectRequest(response);
            return false;
        }
        responseHeaders.setAccessControlAllowOrigin(allowOrigin);
        if (preFlightRequest)
            responseHeaders.setAccessControlAllowMethods(allowMethods);
        if (preFlightRequest && allowHeaders.length != 0)
            responseHeaders.setAccessControlAllowHeaders(allowHeaders);
        if (config.getExposedHeaders().length != 0)
            responseHeaders.setAccessControlExposeHeaders(config.getExposedHeaders());
        if (!config.getAllowCredentials().isNull && config.getAllowCredentials().get)
            responseHeaders.setAccessControlAllowCredentials(true);
        if (preFlightRequest && !config.getMaxAge().isNull)
            responseHeaders.setAccessControlMaxAge(config.getMaxAge().get);
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
        if (contextPath.length != 0 && path.length >= contextPath.length && path[0 .. contextPath.length] == contextPath)
            path = path[contextPath.length .. $];
        foreach (entry; entries)
            if (entry.pattern.matches(path))
                return entry.config;
        return null;
    }
}
