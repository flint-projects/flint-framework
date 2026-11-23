/++
`org.springframework.web.servlet.i18n`: locale resolution for `DispatcherServlet`.

Ported from spring-projects/spring-framework v7.1.0, spring-webmvc/src/main/java/org/springframework/web/servlet/i18n/
(AbstractLocaleResolver.java, AcceptHeaderLocaleResolver.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. `Locale` is a value struct (flint:java), so Java's
`@Nullable Locale` is `Locale.init` with a "has" flag kept by the resolver. `List<Locale>` is `Locale[]` (R10), and
the `Function` default-locale hook is a delegate (R6).
+/
module flint.web.servlet.i18n;

import flint.jakarta.servlet.http : HttpServletRequest, HttpServletResponse;
import flint.java.lang : UnsupportedOperationException;
import flint.java.util : Locale;
import flint.web.servlet : LocaleResolver;

@safe:

/// `AbstractLocaleResolver`: a resolver with an optional default locale.
abstract class AbstractLocaleResolver : LocaleResolver
{
    private Locale defaultLocale;
    private bool defaultLocaleSet;

    /// Sets the locale returned when no other is determined; `Locale.init` clears it.
    void setDefaultLocale(Locale defaultLocale) pure nothrow @nogc
    {
        this.defaultLocale = defaultLocale;
        defaultLocaleSet = defaultLocale != Locale.init;
    }

    /// The default locale, or `Locale.init` when none is set.
    Locale getDefaultLocale() const pure nothrow @nogc
    {
        return defaultLocaleSet ? defaultLocale : Locale.init;
    }

    /// Whether a default locale is set (Java's non-null `getDefaultLocale()`).
    protected bool hasDefaultLocale() const pure nothrow @nogc
    {
        return defaultLocaleSet;
    }
}

/++
`AcceptHeaderLocaleResolver`: the request's `Accept-Language` locale (`HttpServletRequest.getLocale()`), narrowed to
the supported locales when there are any. Spring MVC's default `LocaleResolver`. The locale cannot be changed,
because it comes from the client.
+/
class AcceptHeaderLocaleResolver : AbstractLocaleResolver
{
    private Locale[] supportedLocales;
    private Locale delegate(HttpServletRequest) @safe defaultLocaleFunction;

    /// Restricts resolution to `locales`, as a server-side list of the languages it supports.
    void setSupportedLocales(Locale[] locales) pure nothrow
    {
        supportedLocales = locales.dup;
    }

    /// The supported locales.
    Locale[] getSupportedLocales() pure nothrow
    {
        return supportedLocales.dup;
    }

    /// Computes the default locale per request, in place of the configured one; `Locale.init` means none.
    void setDefaultLocaleFunction(Locale delegate(HttpServletRequest) @safe defaultLocaleFunction) pure nothrow @nogc
    {
        this.defaultLocaleFunction = defaultLocaleFunction;
    }

    Locale resolveLocale(HttpServletRequest request)
    {
        const defaultLocale = defaultLocaleFunction !is null ? defaultLocaleFunction(request) : getDefaultLocale();
        const hasDefault = defaultLocale != Locale.init;
        if (hasDefault && request.getHeader("Accept-Language") is null)
            return defaultLocale;
        const requestLocale = request.getLocale();
        if (supportedLocales.length == 0 || contains(supportedLocales, requestLocale))
            return requestLocale;
        Locale supported;
        if (findSupportedLocale(request, supported))
            return supported;
        return hasDefault ? defaultLocale : requestLocale;
    }

    void setLocale(HttpServletRequest request, HttpServletResponse response, Locale locale)
    {
        throw new UnsupportedOperationException(
                "Cannot change HTTP Accept-Language header - use a different locale resolution strategy");
    }

    /// The first fully supported request locale, else a supported locale with only the language of one.
    private bool findSupportedLocale(HttpServletRequest request, out Locale found)
    {
        Locale languageMatch;
        bool languageMatched;
        foreach (candidate; request.getLocales())
        {
            if (contains(supportedLocales, candidate))
            {
                // A full match, possibly narrowing an earlier language-only match.
                if (!languageMatched || languageMatch.getLanguage() == candidate.getLanguage())
                {
                    found = candidate;
                    return true;
                }
            }
            else if (!languageMatched)
            {
                foreach (supported; supportedLocales)
                {
                    if (supported.getCountry().length == 0 && supported.getLanguage() == candidate.getLanguage())
                    {
                        languageMatch = supported;
                        languageMatched = true;
                        break;
                    }
                }
            }
        }
        found = languageMatch;
        return languageMatched;
    }

    private static bool contains(scope const(Locale)[] locales, const Locale locale) pure nothrow @nogc
    {
        foreach (candidate; locales)
            if (candidate == locale)
                return true;
        return false;
    }
}
