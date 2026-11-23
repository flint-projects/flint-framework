/++
`org.springframework.web.servlet.mvc.method`: `RequestMappingInfo` and the handler mapping built on it.

Ported from spring-projects/spring-framework v7.1.0,
spring-webmvc/src/main/java/org/springframework/web/servlet/mvc/method/ (RequestMappingInfo.java,
RequestMappingInfoHandlerMapping.java), .../mvc/condition/ (PathPatternsRequestCondition.java,
RequestMethodsRequestCondition.java, ParamsRequestCondition.java, HeadersRequestCondition.java,
ConsumesRequestCondition.java, ProducesRequestCondition.java) and
.../handler/AbstractHandlerMethodMapping.java (lookup).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: the six request conditions are fields of one struct-like class with Spring's
match and compare rules; mappings come from Flint AOT's `HandlerMapping` rows (contract 1 section 4.5), whose
class and method paths are already combined. Ambiguous mappings fail at startup and at lookup, as in Spring.
+/
module flint.web.servlet.mvc.method;

import flint.engine.aot.any : Any;
import flint.http : HttpHeaders, HttpMethod, InvalidMediaTypeException, MediaType;
import flint.jakarta.servlet : DispatcherType;
import flint.jakarta.servlet.http : HttpServletRequest;
import flint.java.lang : IllegalStateException;
import flint.util : MimeTypeUtils;
import flint.web : HttpMediaTypeNotAcceptableException, HttpMediaTypeNotSupportedException,
    HttpRequestMethodNotSupportedException;
import flint.web.accept : ContentNegotiationManager;
import flint.web.context.request : ServletWebRequest;
import flint.web.method : HandlerMethod;
import flint.web.servlet : HandlerMapping;
import flint.web.cors : CorsConfiguration;
import flint.web.servlet.handler : AbstractHandlerMapping, lookupPath;
import flint.web.util.pattern : PathMatchInfo, PathPattern, PathPatternParser;
import std.typecons : Nullable, nullable;

@safe:

/// One `params` or `headers` expression: `name`, `!name`, `name=value` or `name!=value`.
private struct NameValueExpression
{
    string name;
    string value;
    bool isNegated;
    bool hasValue;

    static NameValueExpression parse(string expression) pure nothrow
    {
        NameValueExpression e;
        foreach (i, c; expression)
        {
            if (c == '=')
            {
                e.hasValue = true;
                if (i > 0 && expression[i - 1] == '!')
                {
                    e.isNegated = true;
                    e.name = expression[0 .. i - 1];
                }
                else
                    e.name = expression[0 .. i];
                e.value = expression[i + 1 .. $];
                return e;
            }
        }
        if (expression.length != 0 && expression[0] == '!')
        {
            e.isNegated = true;
            e.name = expression[1 .. $];
        }
        else
            e.name = expression;
        return e;
    }

    bool matchParam(HttpServletRequest request)
    {
        bool isMatch;
        if (hasValue)
        {
            foreach (v; request.getParameterValues(name))
                isMatch = isMatch || v == value;
        }
        else
            isMatch = request.getParameterValues(name) !is null;
        return isMatch != isNegated;
    }

    bool matchHeader(HttpServletRequest request)
    {
        import flint.util : equalsIgnoreCase;

        bool isMatch;
        if (hasValue)
        {
            foreach (v; request.getHeaders(name))
                isMatch = isMatch || v == value;
        }
        else
            isMatch = request.getHeader(name) !is null;
        return isMatch != isNegated;
    }

    string toString() const pure nothrow
    {
        if (!hasValue)
            return (isNegated ? "!" : "") ~ name;
        return name ~ (isNegated ? "!=" : "=") ~ value;
    }
}

private struct MediaTypeExpression
{
    MediaType mediaType;
    bool isNegated;

    static MediaTypeExpression parse(string expression)
    {
        MediaTypeExpression e;
        if (expression.length != 0 && expression[0] == '!')
        {
            e.isNegated = true;
            expression = expression[1 .. $];
        }
        e.mediaType = MediaType.parseMediaType(expression);
        return e;
    }
}

/// `RequestMappingInfo`: the request conditions of one mapping.
final class RequestMappingInfo
{
    private string name;
    private PathPattern[] patterns;
    private HttpMethod[] methods;
    private NameValueExpression[] params;
    private NameValueExpression[] headers;
    private MediaTypeExpression[] consumes;
    private MediaTypeExpression[] produces;

    /// From an AOT mapping row's conditions.
    this(string[] paths, string[] methods, string[] params = null, string[] headers = null,
            string[] consumes = null, string[] produces = null, string name = null)
    {
        auto parser = new PathPatternParser;
        foreach (path; paths.length != 0 ? paths : [""])
            patterns ~= parser.parse(path.length != 0 && path[0] != '/' ? "/" ~ path : path);
        foreach (m; methods)
            this.methods ~= HttpMethod.valueOf(m);
        foreach (p; params)
            this.params ~= NameValueExpression.parse(p);
        foreach (h; headers)
        {
            auto e = NameValueExpression.parse(h);
            import flint.util : equalsIgnoreCase;

            if (equalsIgnoreCase(e.name, "Accept") && !e.isNegated && e.hasValue)
                foreach (t; MediaType.parseMediaTypes(e.value))
                    this.produces ~= MediaTypeExpression(t, false);
            else if (equalsIgnoreCase(e.name, "Content-Type") && !e.isNegated && e.hasValue)
                foreach (t; MediaType.parseMediaTypes(e.value))
                    this.consumes ~= MediaTypeExpression(t, false);
            else
                this.headers ~= e;
        }
        foreach (c; consumes)
            this.consumes ~= MediaTypeExpression.parse(c);
        foreach (p; produces)
            this.produces ~= MediaTypeExpression.parse(p);
        this.name = name;
    }

    private this() pure nothrow @nogc
    {
    }

    /// The mapping name, or `null`.
    string getName() const pure nothrow @nogc
    {
        return name;
    }

    /// The path patterns.
    PathPattern[] getPatterns() pure nothrow @nogc
    {
        return patterns;
    }

    /// The methods; empty means all.
    HttpMethod[] getMethods() pure nothrow @nogc
    {
        return methods;
    }

    /// The consumable media types.
    MediaType[] getConsumableMediaTypes() pure nothrow
    {
        MediaType[] result;
        foreach (e; consumes)
            if (!e.isNegated)
                result ~= e.mediaType;
        return result;
    }

    /// The producible media types.
    MediaType[] getProducibleMediaTypes() pure nothrow
    {
        MediaType[] result;
        foreach (e; produces)
            if (!e.isNegated)
                result ~= e.mediaType;
        return result;
    }

    /// Whether every pattern is a plain path (Spring's "direct path" lookup).
    bool hasDirectPaths() const pure nothrow @nogc
    {
        foreach (p; patterns)
            if (p.hasPatternSyntax())
                return false;
        return true;
    }

    /++
    The conditions that match `request`, or `null`. Patterns narrow to the matching ones, sorted by
    specificity; methods narrow to the request's (HEAD matches GET).
    +/
    RequestMappingInfo getMatchingCondition(HttpServletRequest request)
    {
        auto matchedMethods = matchMethods(request);
        if (!matchedMethods.ok)
            return null;
        if (!matchParams(request) || !matchHeaders(request))
            return null;
        auto matchedConsumes = matchConsumes(request);
        if (!matchedConsumes.ok)
            return null;
        auto matchedProduces = matchProduces(request);
        if (!matchedProduces.ok)
            return null;
        auto matchedPatterns = matchPatterns(request);
        if (matchedPatterns.length == 0)
            return null;
        auto result = new RequestMappingInfo;
        result.name = name;
        result.patterns = matchedPatterns;
        result.methods = matchedMethods.value;
        result.params = params;
        result.headers = headers;
        result.consumes = matchedConsumes.value;
        result.produces = matchedProduces.value;
        return result;
    }

    package(flint) bool matchesPath(HttpServletRequest request)
    {
        return matchPatterns(request).length != 0;
    }

    package(flint) PathPattern[] matchPatterns(HttpServletRequest request)
    {
        const path = lookupPath(request);
        PathPattern[] matched;
        foreach (p; patterns)
            if (p.matches(path))
                matched ~= p;
        // Sort by specificity (Spring's PathPatternsRequestCondition keeps a sorted set).
        for (size_t i = 1; i < matched.length; i++)
        {
            auto p = matched[i];
            size_t j = i;
            while (j > 0 && matched[j - 1].compareTo(p) > 0)
            {
                matched[j] = matched[j - 1];
                j--;
            }
            matched[j] = p;
        }
        return matched;
    }

    // RequestMethodsRequestCondition.getMatchingCondition
    package(flint) Matched!HttpMethod matchMethods(HttpServletRequest request)
    {
        const method = request.getMethod();
        if (isPreFlightRequest(request))
            return matchPreFlight(request);
        if (methods.length == 0)
        {
            if (method == "OPTIONS" && request.getDispatcherType() != DispatcherType.ERROR)
                return Matched!HttpMethod.init; // let the OPTIONS handler answer
            return found!HttpMethod(null);
        }
        foreach (m; methods)
            if (m.matches(method))
                return found!HttpMethod([cast(HttpMethod) m]);
        if (method == "HEAD")
            foreach (m; methods)
                if (m == HttpMethod.GET)
                    return found!HttpMethod([cast(HttpMethod) HttpMethod.GET]);
        return Matched!HttpMethod.init;
    }

    private Matched!HttpMethod matchPreFlight(HttpServletRequest request)
    {
        if (methods.length == 0)
            return found!HttpMethod(null);
        const expected = request.getHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD);
        foreach (m; methods)
            if (m.matches(expected))
                return found!HttpMethod([cast(HttpMethod) m]);
        return Matched!HttpMethod.init;
    }

    private bool matchParams(HttpServletRequest request)
    {
        foreach (e; params)
            if (!e.matchParam(request))
                return false;
        return true;
    }

    private bool matchHeaders(HttpServletRequest request)
    {
        if (isPreFlightRequest(request))
            return true;
        foreach (e; headers)
            if (!e.matchHeader(request))
                return false;
        return true;
    }

    // ConsumesRequestCondition.getMatchingCondition
    package(flint) Matched!MediaTypeExpression matchConsumes(HttpServletRequest request)
    {
        if (isPreFlightRequest(request) || consumes.length == 0)
            return found(consumes);
        // A request without a body matches when the body is not required (Spring: no Content-Length,
        // no Transfer-Encoding).
        if (request.getContentLengthLong() <= 0 && request.getHeader("Transfer-Encoding") is null
                && request.getContentType() is null)
            return found(consumes);
        MediaType contentType;
        try
            contentType = request.getContentType().length != 0 ? MediaType.parseMediaType(request.getContentType())
                : MediaType.APPLICATION_OCTET_STREAM;
        catch (InvalidMediaTypeException)
            return Matched!MediaTypeExpression.init;
        MediaTypeExpression[] matched;
        foreach (e; consumes)
            if (e.mediaType.includes(contentType) != e.isNegated)
                matched ~= e;
        return matched.length == 0 ? Matched!MediaTypeExpression.init : found(matched);
    }

    // ProducesRequestCondition.getMatchingCondition
    package(flint) Matched!MediaTypeExpression matchProduces(HttpServletRequest request)
    {
        if (isPreFlightRequest(request) || produces.length == 0)
            return found(produces);
        MediaType[] acceptedMediaTypes;
        try
            acceptedMediaTypes = new ContentNegotiationManager().resolveMediaTypes(new ServletWebRequest(request));
        catch (HttpMediaTypeNotAcceptableException)
            return found(produces);
        MediaTypeExpression[] matched;
        foreach (e; produces)
        {
            bool compatible;
            foreach (accepted; acceptedMediaTypes)
                compatible = compatible || e.mediaType.isCompatibleWith(accepted);
            if (compatible != e.isNegated)
                matched ~= e;
        }
        return matched.length == 0 ? Matched!MediaTypeExpression.init : found(matched);
    }

    /// Spring's `compareTo(other, request)`: patterns, params, headers, consumes, produces, methods.
    int compareTo(RequestMappingInfo other, HttpServletRequest request)
    {
        int result = comparePatterns(other);
        if (result != 0)
            return result;
        result = cast(int) other.params.length - cast(int) params.length;
        if (result != 0)
            return result;
        result = cast(int) other.headers.length - cast(int) headers.length;
        if (result != 0)
            return result;
        result = compareMediaTypes(consumes, other.consumes);
        if (result != 0)
            return result;
        result = compareProduces(other, request);
        if (result != 0)
            return result;
        // Methods: an explicit method beats none; HEAD request prefers an explicit HEAD mapping.
        if (methods.length != other.methods.length)
            return other.methods.length == 0 ? -1 : methods.length == 0 ? 1 : 0;
        return 0;
    }

    private int comparePatterns(RequestMappingInfo other)
    {
        foreach (i; 0 .. patterns.length < other.patterns.length ? patterns.length : other.patterns.length)
        {
            const result = patterns[i].compareTo(other.patterns[i]);
            if (result != 0)
                return result;
        }
        return cast(int) other.patterns.length - cast(int) patterns.length;
    }

    private static int compareMediaTypes(MediaTypeExpression[] a, MediaTypeExpression[] b)
    {
        if (a.length == 0 || b.length == 0)
            return a.length == 0 ? (b.length == 0 ? 0 : 1) : -1;
        if (a[0].mediaType.isMoreSpecific(b[0].mediaType))
            return -1;
        if (b[0].mediaType.isMoreSpecific(a[0].mediaType))
            return 1;
        return 0;
    }

    private int compareProduces(RequestMappingInfo other, HttpServletRequest request)
    {
        if (produces.length == 0 && other.produces.length == 0)
            return 0;
        if (produces.length == 0 || other.produces.length == 0)
            return produces.length == 0 ? 1 : -1;
        return compareMediaTypes(produces, other.produces);
    }

    override string toString() const
    {
        string text = "{";
        if (methods.length != 0)
        {
            foreach (i, m; methods)
                text ~= (i == 0 ? "" : ", ") ~ m.name();
            text ~= " ";
        }
        if (patterns.length == 1)
            text ~= patterns[0].getPatternString();
        else
        {
            text ~= "[";
            foreach (i, p; patterns)
                text ~= (i == 0 ? "" : ", ") ~ p.getPatternString();
            text ~= "]";
        }
        foreach (e; params)
            text ~= ", params " ~ e.toString();
        if (produces.length != 0)
        {
            text ~= ", produces [";
            foreach (i, e; produces)
                text ~= (i == 0 ? "" : ", ") ~ (e.isNegated ? "!" : "") ~ e.mediaType.toString();
            text ~= "]";
        }
        return text ~ "}";
    }
}

private struct Matched(T)
{
    bool ok;
    T[] value;
}

private Matched!T found(T)(T[] value) pure nothrow @nogc
{
    return Matched!T(true, value);
}

private bool isPreFlightRequest(HttpServletRequest request)
{
    return request.getMethod() == "OPTIONS" && request.getHeader(HttpHeaders.ORIGIN) !is null
        && request.getHeader(HttpHeaders.ACCESS_CONTROL_REQUEST_METHOD) !is null;
}

/// `RequestMappingInfoHandlerMapping` with `AbstractHandlerMethodMapping`'s lookup.
abstract class RequestMappingInfoHandlerMapping : AbstractHandlerMapping
{
    private static struct Registration
    {
        RequestMappingInfo info;
        HandlerMethod handlerMethod;
    }

    private Registration[] registrations;
    private CorsConfiguration[HandlerMethod] corsLookup;

    /// Registers `handlerMethod` under `info` with its CORS configuration (or `null`).
    void registerMapping(RequestMappingInfo info, HandlerMethod handlerMethod, CorsConfiguration corsConfig)
    {
        registerMapping(info, handlerMethod);
        if (corsConfig !is null)
            corsLookup[handlerMethod] = corsConfig;
    }

    protected override bool hasCorsConfigurationSource(Object handler)
    {
        if (super.hasCorsConfigurationSource(handler))
            return true;
        auto method = cast(HandlerMethod) handler;
        return method !is null && (method in corsLookup) !is null;
    }

    protected override CorsConfiguration getCorsConfiguration(Object handler, HttpServletRequest request)
    {
        auto config = super.getCorsConfiguration(handler, request);
        if (auto method = cast(HandlerMethod) handler)
            if (auto found = method in corsLookup)
                return config !is null ? config.combine(*found) : *found;
        return config;
    }

    /// Registers `handlerMethod` under `info`. Throws `IllegalStateException` for an ambiguous mapping.
    void registerMapping(RequestMappingInfo info, HandlerMethod handlerMethod)
    {
        foreach (existing; registrations)
            if (existing.info.toString() == info.toString() && existing.handlerMethod !is handlerMethod)
                throw new IllegalStateException("Ambiguous mapping. Cannot map '" ~ handlerMethod.getBeanName()
                        ~ "' method \n" ~ handlerMethod.toString() ~ "\nto " ~ info.toString()
                        ~ ": There is already '" ~ existing.handlerMethod.getBeanName() ~ "' bean method\n"
                        ~ existing.handlerMethod.toString() ~ " mapped.");
        registrations ~= Registration(info, handlerMethod);
    }

    /// Every registered mapping.
    RequestMappingInfo[] getHandlerMethods() pure nothrow
    {
        RequestMappingInfo[] result;
        foreach (r; registrations)
            result ~= r.info;
        return result;
    }

    protected override Object getHandlerInternal(HttpServletRequest request)
    {
        request.removeAttribute(HandlerMapping.PRODUCIBLE_MEDIA_TYPES_ATTRIBUTE);
        const path = lookupPath(request);
        request.setAttribute(HandlerMapping.LOOKUP_PATH, Any.of(path));
        return lookupHandlerMethod(path, request);
    }

    /// Spring's `lookupHandlerMethod`: the best match, or the no-match handling.
    protected HandlerMethod lookupHandlerMethod(string lookupPath, HttpServletRequest request)
    {
        static struct Match
        {
            RequestMappingInfo info;
            HandlerMethod handlerMethod;
        }

        Match[] matches;
        // Direct path matches first, then every mapping (Spring's directPathMappings shortcut).
        foreach (r; registrations)
            if (r.info.hasDirectPaths())
                if (auto matched = r.info.getMatchingCondition(request))
                    matches ~= Match(matched, r.handlerMethod);
        if (matches.length == 0)
            foreach (r; registrations)
                if (!r.info.hasDirectPaths())
                    if (auto matched = r.info.getMatchingCondition(request))
                        matches ~= Match(matched, r.handlerMethod);
        if (matches.length == 0)
        {
            RequestMappingInfo[] infos;
            foreach (r; registrations)
                infos ~= r.info;
            return handleNoMatch(infos, lookupPath, request);
        }
        for (size_t i = 1; i < matches.length; i++)
        {
            auto m = matches[i];
            size_t j = i;
            while (j > 0 && matches[j - 1].info.compareTo(m.info, request) > 0)
            {
                matches[j] = matches[j - 1];
                j--;
            }
            matches[j] = m;
        }
        auto best = matches[0];
        if (matches.length > 1 && !isPreFlightRequest(request))
        {
            auto second = matches[1];
            if (best.info.compareTo(second.info, request) == 0)
                throw new IllegalStateException("Ambiguous handler methods mapped for '" ~ lookupPath ~ "': {"
                        ~ best.handlerMethod.toString() ~ ", " ~ second.handlerMethod.toString() ~ "}");
        }
        request.setAttribute(HandlerMapping.BEST_MATCHING_HANDLER_ATTRIBUTE, Any.of(cast(Object) best.handlerMethod));
        handleMatch(best.info, lookupPath, request);
        return best.handlerMethod;
    }

    /// Exposes the best pattern, URI variables and producible media types.
    protected void handleMatch(RequestMappingInfo info, string lookupPath, HttpServletRequest request)
    {
        auto pattern = info.getPatterns()[0];
        request.setAttribute(HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE, Any.of(pattern.getPatternString()));
        auto matchInfo = pattern.matchAndExtract(lookupPath);
        string[2][] variables = matchInfo is null ? null : matchInfo.getUriVariables();
        request.setAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE, Any.of(variables));
        auto producible = info.getProducibleMediaTypes();
        if (producible.length != 0)
            request.setAttribute(HandlerMapping.PRODUCIBLE_MEDIA_TYPES_ATTRIBUTE, Any.of(producible));
    }

    /// Spring's `handleNoMatch`: 405 (or the OPTIONS handler), 415, 406, unsatisfied params, or `null`.
    protected HandlerMethod handleNoMatch(RequestMappingInfo[] infos, string lookupPath, HttpServletRequest request)
    {
        RequestMappingInfo[] partial;
        foreach (info; infos)
            if (info.matchesPath(request))
                partial ~= info;
        if (partial.length == 0)
            return null;

        bool methodsMatch(RequestMappingInfo info)
        {
            return info.matchMethods(request).ok;
        }

        bool anyMethodMatch;
        foreach (info; partial)
            anyMethodMatch = anyMethodMatch || methodsMatch(info);
        if (!anyMethodMatch)
        {
            string[] allowed;
            foreach (info; partial)
                foreach (m; info.getMethods())
                {
                    bool seen;
                    foreach (a; allowed)
                        seen = seen || a == m.name();
                    if (!seen)
                        allowed ~= m.name();
                }
            if (request.getMethod() == "OPTIONS")
            {
                MediaType[] patchTypes, queryTypes;
                foreach (info; partial)
                    foreach (m; info.getMethods())
                    {
                        if (m == HttpMethod.PATCH)
                            patchTypes ~= info.getConsumableMediaTypes();
                        if (m == HttpMethod.QUERY)
                            queryTypes ~= info.getConsumableMediaTypes();
                    }
                return createOptionsHandler(allowed, patchTypes, queryTypes);
            }
            throw new HttpRequestMethodNotSupportedException(request.getMethod(), allowed);
        }
        RequestMappingInfo[] methodMatched;
        foreach (info; partial)
            if (methodsMatch(info))
                methodMatched ~= info;
        bool consumesMatch;
        foreach (info; methodMatched)
            consumesMatch = consumesMatch || info.matchConsumes(request).ok;
        if (!consumesMatch)
        {
            MediaType[] mediaTypes;
            foreach (info; methodMatched)
                mediaTypes ~= info.getConsumableMediaTypes();
            Nullable!MediaType contentType;
            if (request.getContentType().length != 0)
            {
                try
                    contentType = nullable(MediaType.parseMediaType(request.getContentType()));
                catch (InvalidMediaTypeException ex)
                    throw new HttpMediaTypeNotSupportedException(ex.getMessage(), mediaTypes);
            }
            throw new HttpMediaTypeNotSupportedException(contentType, mediaTypes,
                    nullable(HttpMethod.valueOf(request.getMethod())));
        }
        bool producesMatch;
        foreach (info; methodMatched)
            producesMatch = producesMatch || info.matchProduces(request).ok;
        if (!producesMatch)
        {
            MediaType[] mediaTypes;
            foreach (info; methodMatched)
                mediaTypes ~= info.getProducibleMediaTypes();
            throw new HttpMediaTypeNotAcceptableException(mediaTypes);
        }
        return null;
    }

    /// The handler for an unmapped OPTIONS request; supplied by the annotation-based subclass.
    protected abstract HandlerMethod createOptionsHandler(string[] declaredMethods, MediaType[] acceptPatch,
            MediaType[] acceptQuery);
}
