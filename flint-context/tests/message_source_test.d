// Ported from spring-framework v7.1.0: spring-context/src/test/java/org/springframework/context/support/StaticMessageSourceTests.java
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
 * spring-context/src/test/java/org/springframework/context/support/{StaticMessageSourceTests,
 * ResourceBundleMessageSourceTests}.java and the messages*.properties files beside them.
 */

/++
Message sources. StaticMessageSourceTests (7 of 10): count and messageSource are AbstractApplicationContextTests'
bean-count checks over a StaticApplicationContext Flint does not have, and getMessageWithMessageAlreadyLookedFor
checks a MessageFormat cache Flint does not keep; the messages are registered on a StaticMessageSource directly.
ResourceBundleMessageSourceTests (11 of 33): the five non-reloadable doTestMessageAccess variants, the standalone,
whitespace and charset tests, and the context's default message source; the 22 others need
ReloadableResourceBundleMessageSource, XML bundles or `java.util.ResourceBundle`. Java's `Locale.setDefault` becomes
`setDefaultLocale` on the source, and the bundles are embedded resources, as `flint build` embeds them.
+/
module flint.context.message_source_test;

import flint.context : MessageSourceResolvable, NoSuchMessageException;
import flint.context.i18n : LocaleContextHolder;
import flint.context.support : DefaultMessageSourceResolvable, GenericApplicationContext,
    MessageSourceAccessor, ResourceBundleMessageSource, StaticMessageSource;
import flint.engine.aot.any : Any;
import flint.java.nio.charset : UnsupportedCharsetException;
import flint.java.util : Locale;
import std.exception : collectException;

@safe:

private enum MSG_TXT1_US = `At '{1,time}' on "{1,date}", there was "{2}" on planet {0,number,integer}.`;
private enum MSG_TXT1_UK = `At '{1,time}' on "{1,date}", there was "{2}" on station number {0,number,integer}.`;
private enum MSG_TXT2_US = "This is a test message in the message catalog with no args.";
private enum MSG_TXT3_US = "This is another test message in the message catalog with no args.";

private StaticMessageSource staticSource()
{
    auto source = new StaticMessageSource;
    source.addMessages([
        "message.format.example1": MSG_TXT1_US,
        "message.format.example2": MSG_TXT2_US,
        "message.format.example3": MSG_TXT3_US
    ], Locale.US);
    source.addMessage("message.format.example1", Locale.UK, MSG_TXT1_UK);
    return source;
}

private bool contains(string text, string part)
{
    foreach (i; 0 .. text.length >= part.length ? text.length - part.length + 1 : 0)
        if (text[i .. i + part.length] == part)
            return true;
    return false;
}

unittest
{
    // getMessageWithDefaultPassedInAndFoundInMsgCatalog, getMessageWithDefaultPassedInAndNotFoundInMsgCatalog
    auto sac = staticSource();
    assert(sac.getMessage("message.format.example2", null,
            "This is a default msg if not found in MessageSource.", Locale.US) == MSG_TXT2_US);
    assert(sac.getMessage("bogus.message", null, "This is a default msg if not found in MessageSource.",
            Locale.US) == "This is a default msg if not found in MessageSource.");
}

unittest
{
    // getMessageWithNoDefaultPassedInAndFoundInMsgCatalog, getMessageWithNoDefaultPassedInAndNotFoundInMsgCatalog
    auto sac = staticSource();
    auto arguments = [Any.of(7), Any.of("now"), Any.of("a disturbance in the Force")];
    assert(contains(sac.getMessage("message.format.example1", arguments, Locale.US),
            `there was "a disturbance in the Force" on planet 7.`));
    assert(contains(sac.getMessage("message.format.example1", arguments, Locale.UK),
            `there was "a disturbance in the Force" on station number 7.`));
    assert(sac.getMessage("message.format.example2", null, Locale.US) == MSG_TXT2_US);
    const e = collectException!NoSuchMessageException(sac.getMessage("bogus.message", null, Locale.US));
    assert(e !is null && e.msg == "No message found under code 'bogus.message' for locale 'en_US'.");
}

unittest
{
    // messageSourceResolvable
    auto sac = staticSource();
    string[] codes1 = ["message.format.example3", "message.format.example2"];
    string[] codes2 = ["message.format.example99", "message.format.example2"];
    string[] codes3 = ["message.format.example99", "message.format.example98"];
    assert(sac.getMessage(new DefaultMessageSourceResolvable(codes1, null, "default"), Locale.US) == MSG_TXT3_US);
    assert(sac.getMessage(new DefaultMessageSourceResolvable(codes2, null, "default"), Locale.US) == MSG_TXT2_US);
    assert(sac.getMessage(new DefaultMessageSourceResolvable(codes3, null, "default"), Locale.US) == "default");
    auto noDefault = new DefaultMessageSourceResolvable(codes3);
    assert(collectException!NoSuchMessageException(sac.getMessage(noDefault, Locale.US)) !is null);
}

unittest
{
    // nestedMessageSourceWithParamInChild, nestedMessageSourceWithParamInParent
    foreach (paramInChild; [true, false])
    {
        auto source = new StaticMessageSource;
        auto parent = new StaticMessageSource;
        source.setParentMessageSource(parent);
        (paramInChild ? source : parent).addMessage("param", Locale.ENGLISH, "value");
        (paramInChild ? parent : source).addMessage("with.param", Locale.ENGLISH, "put {0} here");
        auto resolvable = new DefaultMessageSourceResolvable(["with.param"],
                [Any.of(cast(MessageSourceResolvable) new DefaultMessageSourceResolvable("param"))]);
        assert(source.getMessage(resolvable, Locale.ENGLISH) == "put value here");
    }
}

// ---- ResourceBundleMessageSourceTests

private immutable(ubyte)[] bundle(string path) @safe nothrow
{
    enum base = "org/springframework/context/support/";
    switch (path)
    {
    case base ~ "messages.properties":
        return cast(immutable(ubyte)[])(
                "  code1\t = \tmess\\\n            age1\ncode2=message2\nhello={0}, {1}\n" ~ "escaped=I''m\n");
    case base ~ "messages_de.properties":
        return cast(immutable(ubyte)[]) "code2=nachricht2\n";
    case base ~ "messages_de_AT.properties":
        return cast(immutable(ubyte)[]) "code2=nochricht2\n";
    case base ~ "messages_de_AT_oo.properties":
        return cast(immutable(ubyte)[]) "code2=noochricht2\n";
    case base ~ "more-messages.properties":
        return cast(immutable(ubyte)[]) "code3=message3\n";
    default:
        return null;
    }
}

private void installBundles()
{
    import flint.core.io : installEmbeddedResources;

    installEmbeddedResources(&bundle);
}

/// Java's doTestMessageAccess for ResourceBundleMessageSource (`reloadable` false).
private void doTestMessageAccess(bool fallbackToSystemLocale, bool expectGermanFallback,
        bool useCodeAsDefaultMessage, bool alwaysUseMessageFormat)
{
    installBundles();
    auto ms = new ResourceBundleMessageSource;
    enum base = "org/springframework/context/support/";
    ms.setBasenames(base ~ "messages", base ~ "more-messages");
    ms.setFallbackToSystemLocale(fallbackToSystemLocale);
    ms.setUseCodeAsDefaultMessage(useCodeAsDefaultMessage);
    ms.setAlwaysUseMessageFormat(alwaysUseMessageFormat);
    if (fallbackToSystemLocale) // Java's Locale.setDefault(GERMAN or CANADA)
        ms.setDefaultLocale(expectGermanFallback ? Locale.GERMAN : Locale.CANADA);
    auto ac = new GenericApplicationContext;
    ac.getBeanFactory().registerSingleton("messageSource", ms);
    ac.refresh();
    scope (exit)
        ac.close();

    assert(ac.getMessage("code1", null, Locale.ENGLISH) == "message1");
    const expected = fallbackToSystemLocale && expectGermanFallback ? "nachricht2" : "message2";
    assert(ac.getMessage("code2", null, Locale.ENGLISH) == expected);
    assert(ac.getMessage("code2", null, Locale.GERMAN) == "nachricht2");
    assert(ac.getMessage("code2", null, Locale("DE", "at")) == "nochricht2");
    assert(ac.getMessage("code2", null, Locale("DE", "at", "oo")) == "noochricht2");

    auto accessor = new MessageSourceAccessor(ac);
    LocaleContextHolder.setLocale(Locale("DE", "at"));
    scope (exit)
        LocaleContextHolder.resetLocaleContext();
    assert(accessor.getMessage("code2") == "nochricht2");

    assert(ac.getMessage("code3", null, Locale.ENGLISH) == "message3");
    assert(ac.getMessage(new DefaultMessageSourceResolvable("code3"), Locale.ENGLISH) == "message3");
    assert(ac.getMessage(new DefaultMessageSourceResolvable(["code4", "code3"]), Locale.ENGLISH) == "message3");

    auto args = [
        Any.of("Hello"),
        Any.of(cast(MessageSourceResolvable) new DefaultMessageSourceResolvable(["code1"]))
    ];
    assert(ac.getMessage("hello", args, Locale.ENGLISH) == "Hello, message1");

    // default message without and with args
    assert(ac.getMessage(null, null, null, Locale.ENGLISH) is null);
    assert(ac.getMessage(null, null, "default", Locale.ENGLISH) == "default");
    assert(ac.getMessage(null, args, "default", Locale.ENGLISH) == "default");
    assert(ac.getMessage(null, null, "{0}, default", Locale.ENGLISH) == "{0}, default");
    assert(ac.getMessage(null, args, "{0}, default", Locale.ENGLISH) == "Hello, default");

    // resolvable with default message, without and with args
    assert(ac.getMessage(new DefaultMessageSourceResolvable(null, null, "default"), Locale.ENGLISH) == "default");
    assert(ac.getMessage(new DefaultMessageSourceResolvable(null, args, "default"), Locale.ENGLISH) == "default");
    assert(ac.getMessage(new DefaultMessageSourceResolvable(null, null, "{0}, default"),
            Locale.ENGLISH) == "{0}, default");
    assert(ac.getMessage(new DefaultMessageSourceResolvable(null, args, "{0}, default"),
            Locale.ENGLISH) == "Hello, default");

    // message args
    assert(ac.getMessage("hello", [Any.of("Arg1"), Any.of("Arg2")], Locale.ENGLISH) == "Arg1, Arg2");
    assert(ac.getMessage("hello", null, Locale.ENGLISH) == "{0}, {1}");
    assert(ac.getMessage("escaped", null, Locale.ENGLISH) == (alwaysUseMessageFormat ? "I'm" : "I''m"));
    assert(ac.getMessage("escaped", [Any.of("some arg")], Locale.ENGLISH) == "I'm");

    if (useCodeAsDefaultMessage)
        assert(ac.getMessage("code4", null, Locale.GERMAN) == "code4");
    else
        assert(collectException!NoSuchMessageException(ac.getMessage("code4", null, Locale.GERMAN)) !is null);
}

unittest
{
    // messageAccessWithDefaultMessageSource, ...AndMessageFormat, ...AndFallbackToGerman, ...AndFallbackTurnedOff,
    // ...AndFallbackTurnedOffAndFallbackToGerman
    doTestMessageAccess(true, false, false, false);
    doTestMessageAccess(true, false, false, true);
    doTestMessageAccess(true, true, true, false);
    doTestMessageAccess(false, false, false, false);
    doTestMessageAccess(false, true, false, false);
}

unittest
{
    // resourceBundleMessageSourceStandalone, resourceBundleMessageSourceWithWhitespaceInBasename,
    // resourceBundleMessageSourceWithInvalidDefaultCharsetName, resourceBundleMessageSourceWithDefaultCharsetName
    installBundles();
    foreach (basename; [
        "org/springframework/context/support/messages",
        "  org/springframework/context/support/messages  "
    ])
    {
        auto ms = new ResourceBundleMessageSource;
        ms.setBasename(basename);
        assert(ms.getMessage("code1", null, Locale.ENGLISH) == "message1");
        assert(ms.getMessage("code2", null, Locale.GERMAN) == "nachricht2");
    }
    assert(collectException!UnsupportedCharsetException(new ResourceBundleMessageSource()
            .setDefaultEncoding("BOGUS")) !is null);
    auto ms = new ResourceBundleMessageSource;
    ms.setBasename("org/springframework/context/support/messages");
    ms.setDefaultEncoding("ISO-8859-1");
    assert(ms.getMessage("code1", null, Locale.ENGLISH) == "message1");
    assert(ms.getMessage("code2", null, Locale.GERMAN) == "nachricht2");
}

unittest
{
    // defaultApplicationContextMessageSource: without a messageSource bean, the context delegates to nothing.
    auto ac = new GenericApplicationContext;
    ac.refresh();
    scope (exit)
        ac.close();
    assert(ac.getMessage("code1", null, "default", Locale.ENGLISH) == "default");
    assert(ac.getMessage("code1", [Any.of("value")], "default {0}", Locale.ENGLISH) == "default value");
    assert(collectException!NoSuchMessageException(ac.getMessage("code1", null, Locale.ENGLISH)) !is null);
}

unittest
{
    // MessageFormat: quoting, numbers with the locale's grouping, unknown indexes kept.
    import flint.java.text : MessageFormat, NumberFormat;

    assert(MessageFormat.format("I''m {0}", Any.of("here")) == "I'm here");
    assert(MessageFormat.format("'{0}' is {0}", Any.of(1)) == "{0} is 1");
    assert(new MessageFormat("{0} and {1}", Locale.US).format([Any.of(1_234_567)]) == "1,234,567 and {1}");
    assert(new MessageFormat("{0}", Locale.GERMANY).format([Any.of(1_234.5)]) == "1.234,5");
    assert(new MessageFormat("{0,number,integer}", Locale.US).format([Any.of(2.5)]) == "2");
    assert(NumberFormat.getInstance(Locale.US).format(0.1236) == "0.124"
            && NumberFormat.getInstance(Locale.US).format(-3L) == "-3");
    assert(MessageFormat.format("{0}", Any.init) == "null");
}

unittest
{
    // LocaleContextHolder off a fiber: thread-local, reset to the system default.
    LocaleContextHolder.setLocale(Locale.GERMANY);
    assert(LocaleContextHolder.getLocale() == Locale.GERMANY);
    LocaleContextHolder.resetLocaleContext();
    assert(LocaleContextHolder.getLocaleContext() is null && LocaleContextHolder.getLocale() == Locale.getDefault());
}
