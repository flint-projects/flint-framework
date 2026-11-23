/++
`org.springframework.web.accept`: content negotiation from the `Accept` header.

Ported from spring-projects/spring-framework v7.1.0, spring-web/src/main/java/org/springframework/web/accept/
(ContentNegotiationStrategy.java, ContentNegotiationManager.java, HeaderContentNegotiationStrategy.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. Spring Boot's default manager has only the
header strategy, which is what is ported.
+/
module flint.web.accept;

import flint.http : HttpHeaders, InvalidMediaTypeException, MediaType;
import flint.util : InvalidMimeTypeException, MimeTypeUtils;
import flint.web : HttpMediaTypeNotAcceptableException;
import flint.web.context.request : NativeWebRequest;

@safe:

/// `ContentNegotiationStrategy`.
interface ContentNegotiationStrategy
{
    /// `*/*`, the result when a request states no preference.
    static MediaType[] MEDIA_TYPE_ALL_LIST() pure nothrow
    {
        return [MediaType.ALL];
    }

    /// The requested media types, most preferred first.
    MediaType[] resolveMediaTypes(NativeWebRequest webRequest);
}

/// `HeaderContentNegotiationStrategy`: the `Accept` header.
class HeaderContentNegotiationStrategy : ContentNegotiationStrategy
{
    MediaType[] resolveMediaTypes(NativeWebRequest request)
    {
        auto headerValueArray = request.getHeaderValues(HttpHeaders.ACCEPT);
        if (headerValueArray is null)
            return MEDIA_TYPE_ALL_LIST();
        try
        {
            auto mediaTypes = MediaType.parseMediaTypes(headerValueArray);
            MimeTypeUtils.sortBySpecificity(mediaTypes);
            return mediaTypes.length != 0 ? mediaTypes : MEDIA_TYPE_ALL_LIST();
        }
        catch (InvalidMediaTypeException ex)
            throw new HttpMediaTypeNotAcceptableException(
                    "Could not parse 'Accept' header " ~ headersText(headerValueArray) ~ ": " ~ ex.getMessage());
        catch (InvalidMimeTypeException ex)
            throw new HttpMediaTypeNotAcceptableException(
                    "Could not parse 'Accept' header " ~ headersText(headerValueArray) ~ ": " ~ ex.getMessage());
    }

    private static string headersText(string[] values) pure nothrow
    {
        string text = "[";
        foreach (i, v; values)
            text ~= (i == 0 ? "" : ", ") ~ v;
        return text ~ "]";
    }
}

/// `ContentNegotiationManager`: consults its strategies in order.
class ContentNegotiationManager : ContentNegotiationStrategy
{
    private ContentNegotiationStrategy[] strategies;

    /// With `strategies`; the header strategy when none are given.
    this(ContentNegotiationStrategy[] strategies...)
    {
        this.strategies = strategies.length != 0 ? strategies.dup
            : [cast(ContentNegotiationStrategy) new HeaderContentNegotiationStrategy];
    }

    /// The strategies.
    ContentNegotiationStrategy[] getStrategies() pure nothrow @nogc
    {
        return strategies;
    }

    MediaType[] resolveMediaTypes(NativeWebRequest request)
    {
        foreach (strategy; strategies)
        {
            auto mediaTypes = strategy.resolveMediaTypes(request);
            if (mediaTypes == MEDIA_TYPE_ALL_LIST())
                continue;
            return mediaTypes;
        }
        return MEDIA_TYPE_ALL_LIST();
    }
}
