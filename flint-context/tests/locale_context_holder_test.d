// Ported from spring-framework v7.1.0: spring-context/src/test/java/org/springframework/context/i18n/LocaleContextHolderTests.java
/*
 * Copyright 2002-present the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by the Flint authors: ported from spring-framework v7.1.0,
 * spring-context/src/test/java/org/springframework/context/i18n/LocaleContextHolderTests.java.
 */

/++
`LocaleContextHolderTests`. Off a fiber the holder is thread-local, as Spring's is. The time-zone assertions, and the
`setLocale(null)`/`setDefaultLocale` steps, are gated inside the tests that otherwise pass; the tests built on a
time zone are gated whole.
+/
module flint.context.locale_context_holder_test;

import flint.context.i18n : LocaleContextHolder, SimpleLocaleContext;
import flint.java.util : Locale;

@safe:

// No time zones: TimeZone, TimeZoneAwareLocaleContext, SimpleTimeZoneAwareLocaleContext,
// LocaleContextHolder.getTimeZone/setTimeZone/setDefaultTimeZone.
version (FlintLocaleContextTimeZone)
{
    import flint.context.i18n : SimpleTimeZoneAwareLocaleContext, TimeZoneAwareLocaleContext;
    import flint.java.util : TimeZone;
}

unittest
{
    // setLocaleContext
    scope (exit)
        LocaleContextHolder.resetLocaleContext();
    auto lc = new SimpleLocaleContext(Locale.GERMAN);
    LocaleContextHolder.setLocaleContext(lc);
    assert(LocaleContextHolder.getLocaleContext() is lc);
    assert(LocaleContextHolder.getLocale() == Locale.GERMAN);
    version (FlintLocaleContextTimeZone)
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getDefault());

    lc = new SimpleLocaleContext(Locale.GERMANY);
    LocaleContextHolder.setLocaleContext(lc);
    assert(LocaleContextHolder.getLocaleContext() is lc);
    assert(LocaleContextHolder.getLocale() == Locale.GERMANY);
    version (FlintLocaleContextTimeZone)
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getDefault());

    LocaleContextHolder.resetLocaleContext();
    assert(LocaleContextHolder.getLocaleContext() is null);
    assert(LocaleContextHolder.getLocale() == Locale.getDefault());
    version (FlintLocaleContextTimeZone)
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getDefault());
}

version (FlintLocaleContextTimeZone)
{
    unittest
    {
        // setTimeZoneAwareLocaleContext
        scope (exit)
            LocaleContextHolder.resetLocaleContext();
        auto lc = new SimpleTimeZoneAwareLocaleContext(Locale.GERMANY, TimeZone.getTimeZone("GMT+1"));
        LocaleContextHolder.setLocaleContext(lc);
        assert(LocaleContextHolder.getLocaleContext() is lc);
        assert(LocaleContextHolder.getLocale() == Locale.GERMANY);
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getTimeZone("GMT+1"));

        LocaleContextHolder.resetLocaleContext();
        assert(LocaleContextHolder.getLocaleContext() is null);
        assert(LocaleContextHolder.getLocale() == Locale.getDefault());
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getDefault());
    }
}

unittest
{
    // setLocale
    scope (exit)
        LocaleContextHolder.resetLocaleContext();
    LocaleContextHolder.setLocale(Locale.GERMAN);
    assert(LocaleContextHolder.getLocale() == Locale.GERMAN);
    version (FlintLocaleContextTimeZone)
    {
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getDefault());
        assert(cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext() is null);
    }
    assert(LocaleContextHolder.getLocaleContext().getLocale() == Locale.GERMAN);

    LocaleContextHolder.setLocale(Locale.GERMANY);
    assert(LocaleContextHolder.getLocale() == Locale.GERMANY);
    version (FlintLocaleContextTimeZone)
    {
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getDefault());
        assert(cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext() is null);
    }
    assert(LocaleContextHolder.getLocaleContext().getLocale() == Locale.GERMANY);

    // No null locale to reset with (a D Locale is a value), and no LocaleContextHolder.setDefaultLocale.
    version (FlintLocaleContextDefaultLocale)
    {
        LocaleContextHolder.setLocale(null);
        assert(LocaleContextHolder.getLocaleContext() is null);
        assert(LocaleContextHolder.getLocale() == Locale.getDefault());
        version (FlintLocaleContextTimeZone)
            assert(LocaleContextHolder.getTimeZone() == TimeZone.getDefault());

        LocaleContextHolder.setDefaultLocale(Locale.GERMAN);
        assert(LocaleContextHolder.getLocale() == Locale.GERMAN);
        LocaleContextHolder.setDefaultLocale(null);
        assert(LocaleContextHolder.getLocale() == Locale.getDefault());
    }
}

version (FlintLocaleContextTimeZone)
{
    unittest
    {
        // setTimeZone
        scope (exit)
            LocaleContextHolder.resetLocaleContext();
        LocaleContextHolder.setTimeZone(TimeZone.getTimeZone("GMT+1"));
        assert(LocaleContextHolder.getLocale() == Locale.getDefault());
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getTimeZone("GMT+1"));
        assert(cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext() !is null);
        assert(LocaleContextHolder.getLocaleContext().getLocale() is null);
        assert((cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext())
                .getTimeZone() == TimeZone.getTimeZone("GMT+1"));

        LocaleContextHolder.setTimeZone(TimeZone.getTimeZone("GMT+2"));
        assert(LocaleContextHolder.getLocale() == Locale.getDefault());
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getTimeZone("GMT+2"));
        assert(cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext() !is null);
        assert(LocaleContextHolder.getLocaleContext().getLocale() is null);
        assert((cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext())
                .getTimeZone() == TimeZone.getTimeZone("GMT+2"));

        LocaleContextHolder.setTimeZone(null);
        assert(LocaleContextHolder.getLocaleContext() is null);
        assert(LocaleContextHolder.getLocale() == Locale.getDefault());
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getDefault());

        LocaleContextHolder.setDefaultTimeZone(TimeZone.getTimeZone("GMT+1"));
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getTimeZone("GMT+1"));
        LocaleContextHolder.setDefaultTimeZone(null);
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getDefault());
    }

    unittest
    {
        // setLocaleAndSetTimeZoneMixed
        scope (exit)
            LocaleContextHolder.resetLocaleContext();
        LocaleContextHolder.setLocale(Locale.GERMANY);
        assert(LocaleContextHolder.getLocale() == Locale.GERMANY);
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getDefault());
        assert(cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext() is null);
        assert(LocaleContextHolder.getLocaleContext().getLocale() == Locale.GERMANY);

        LocaleContextHolder.setTimeZone(TimeZone.getTimeZone("GMT+1"));
        assert(LocaleContextHolder.getLocale() == Locale.GERMANY);
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getTimeZone("GMT+1"));
        assert(cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext() !is null);
        assert(LocaleContextHolder.getLocaleContext().getLocale() == Locale.GERMANY);
        assert((cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext())
                .getTimeZone() == TimeZone.getTimeZone("GMT+1"));

        LocaleContextHolder.setLocale(Locale.GERMAN);
        assert(LocaleContextHolder.getLocale() == Locale.GERMAN);
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getTimeZone("GMT+1"));
        assert(cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext() !is null);
        assert(LocaleContextHolder.getLocaleContext().getLocale() == Locale.GERMAN);
        assert((cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext())
                .getTimeZone() == TimeZone.getTimeZone("GMT+1"));

        LocaleContextHolder.setTimeZone(null);
        assert(LocaleContextHolder.getLocale() == Locale.GERMAN);
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getDefault());
        assert(cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext() is null);
        assert(LocaleContextHolder.getLocaleContext().getLocale() == Locale.GERMAN);

        LocaleContextHolder.setTimeZone(TimeZone.getTimeZone("GMT+2"));
        assert(LocaleContextHolder.getLocale() == Locale.GERMAN);
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getTimeZone("GMT+2"));
        assert(cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext() !is null);
        assert(LocaleContextHolder.getLocaleContext().getLocale() == Locale.GERMAN);
        assert((cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext())
                .getTimeZone() == TimeZone.getTimeZone("GMT+2"));

        LocaleContextHolder.setLocale(null);
        assert(LocaleContextHolder.getLocale() == Locale.getDefault());
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getTimeZone("GMT+2"));
        assert(cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext() !is null);
        assert(LocaleContextHolder.getLocaleContext().getLocale() is null);
        assert((cast(TimeZoneAwareLocaleContext) LocaleContextHolder.getLocaleContext())
                .getTimeZone() == TimeZone.getTimeZone("GMT+2"));

        LocaleContextHolder.setTimeZone(null);
        assert(LocaleContextHolder.getLocale() == Locale.getDefault());
        assert(LocaleContextHolder.getTimeZone() == TimeZone.getDefault());
        assert(LocaleContextHolder.getLocaleContext() is null);
    }
}
