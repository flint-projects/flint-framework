// Ported from spring-framework v7.1.0: spring-context/src/main/java/org/springframework/context/i18n
// Copyright 2002-present the original author or authors.
// Licensed under the Apache License, Version 2.0.
// Modified by the Flint authors.
/*
 * Ported from spring-framework v7.1.0, spring-context/src/main/java/org/springframework/context/i18n/{LocaleContext,
 * SimpleLocaleContext,LocaleContextHolder}.java. Java's ThreadLocal is a FiberLocal, so each request fiber has its
 * own locale; the inheritable variant and the static default locale and time zone are not ported (no mutable
 * module state).
 */

/++
`org.springframework.context.i18n`: the current locale of the running request fiber.
+/
module flint.context.i18n;

import flint.engine.reactor : FiberLocal;
import flint.java.lang : IllegalStateException;
import flint.java.util : Locale;

@safe:

/// Exposes a locale (Spring's `LocaleContext`).
interface LocaleContext
{
    /// The current locale.
    Locale getLocale();
}

/// A `LocaleContext` holding one locale.
class SimpleLocaleContext : LocaleContext
{
    private Locale locale;

    /// A context for `locale`.
    this(Locale locale) pure nothrow @nogc
    {
        this.locale = locale;
    }

    /// The locale.
    Locale getLocale()
    {
        return locale;
    }

    /// The locale's `toString`.
    override string toString()
    {
        return locale.toString();
    }
}

private shared FiberLocal!LocaleContext localeContextHolder;

/// The locale context of the current fiber (Spring's `LocaleContextHolder`).
struct LocaleContextHolder
{
    /// Forget the current fiber's locale context.
    static void resetLocaleContext() nothrow @nogc
    {
        localeContextHolder.remove();
    }

    /// Set the current fiber's locale context; null resets it.
    static void setLocaleContext(LocaleContext localeContext)
    {
        if (localeContext is null)
        {
            resetLocaleContext();
            return;
        }
        const stored = localeContextHolder.set(localeContext);
        if (stored.code != 0)
            throw new IllegalStateException("Could not store the locale context: " ~ stored.message);
    }

    /// The current fiber's locale context, or null.
    static LocaleContext getLocaleContext() nothrow @nogc
    {
        return localeContextHolder.get();
    }

    /// Set the current fiber's locale.
    static void setLocale(Locale locale)
    {
        setLocaleContext(new SimpleLocaleContext(locale));
    }

    /// The current fiber's locale, else the system default (`Locale.getDefault()`).
    static Locale getLocale()
    {
        auto context = getLocaleContext();
        return context is null ? Locale.getDefault() : context.getLocale();
    }
}
