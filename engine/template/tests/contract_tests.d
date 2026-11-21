module template_contract_tests;

import flint.arena : Buffer, RequestArena, Status;
import flint.templates : escapeHtml, render, validateUrl;

@safe:

private struct Item
{
    string name;
    int count;
}

private struct Card
{
    string title;
    string url;
    bool active;
    Item[] items;
}

private struct Raw
{
    Buffer value;
}

private struct Text
{
    string value;
}

private bool equals(ref scope RequestArena arena, Buffer content, scope const(char)[] expected) nothrow @nogc
{
    bool result;
    const status = arena.read(content, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        result = bytes == cast(const(ubyte)[]) expected;
    });
    return status == Status.ok && result;
}

@("Template renders nested fields, an include, typed blocks, and escaped URLs")
unittest
{
    enum original = "é<&>\"' &amp;";
    enum title = "é&lt;&amp;&gt;&quot;&#39; &amp;amp;";
    enum url = "/query?a=1&b=two";
    enum prefix = "<div title=\"" ~ title ~ "\"><a href=\"/query?a=1&amp;b=two\">" ~ title ~ "</a>";
    enum suffix = "<small>" ~ title ~ "</small>\n</div>\n";
    auto model = Card(original, url, true, [Item("x<&", int.min)]);
    ubyte[512] bytes;
    scope arena = RequestArena(bytes[]);
    const output = render!"card.html"(model, arena);
    assert(output.ok(), output.error.message);
    assert(equals(arena, output.value, prefix ~ "x&lt;&amp;=-2147483648" ~ suffix));
    model.active = false;
    const alternative = render!"card.html"(model, arena);
    assert(alternative.ok(), alternative.error.message);
    assert(equals(arena, alternative.value, prefix ~ "OFF" ~ suffix));
}

@("The count pass preserves arena capacity on short output and invalid input")
unittest
{
    enum escaped = "&lt;&amp;&gt;&quot;&#39;\n";
    ubyte[escaped.length] exact;
    scope good = RequestArena(exact[]);
    const text = Text("<&>\"'");
    const fit = render!"dynamic-text.html"(text, good);
    assert(fit.ok() && equals(good, fit.value, escaped));
    ubyte[cast(int) escaped.length - 1] small;
    scope arena = RequestArena(small[]);
    const rejected = render!"dynamic-text.html"(text, arena);
    assert(rejected.error.code == Status.outOfMemory && rejected.value.length() == 0);
    assert(arena.stats().used == 0);

    auto url = Card("title", "javascript:blocked");
    const refused = render!"card.html"(url, arena);
    assert(refused.error.code == Status.invalidArgument && arena.stats().used == 0);
    const encoding = Text("\xf0\x80");
    assert(render!"dynamic-text.html"(encoding, arena).error.code == Status.invalidArgument);
    assert(arena.stats().used == 0);
}

@("Arena-backed model values are escaped and expire at arena generation changes")
unittest
{
    ubyte[128] storage;
    scope arena = RequestArena(storage[]);
    auto model = Raw(arena.copyIn(cast(const(ubyte)[]) "abc<&").value);
    const before = render!"dynamic-text.html"(model, arena);
    assert(before.ok() && equals(arena, before.value, "abc&lt;&amp;\n"));
    assert(arena.reset() == Status.ok);
    assert(render!"dynamic-text.html"(model, arena).error.code == Status.invalidArgument);
    assert(!equals(arena, before.value, "abc&lt;&amp;\n"));
}

@("Canonical shared includes and the bounded loop are exercised")
unittest
{
    ubyte[128] storage;
    scope arena = RequestArena(storage[]);
    auto model = Card("name");
    const shared_ = render!"relative.html"(model, arena);
    assert(shared_.ok() && equals(arena, shared_.value, "<small>name</small>\n<small>name</small>\n\n"));
    struct Many
    {
        string[] values;
    }

    auto many = Many(new string[100_001]);
    const saturated = render!"loop-limit.html"(many, arena);
    assert(saturated.error.code == Status.resourceExhausted && saturated.value.length() == 0);
}

@("The URL policy allows a fixed scheme set and refuses control or malformed URLs")
unittest
{
    foreach (valid; [
        "", "./notes", "../guide", "/a?x=1&y=2", "#part", "?limit=1", "HTTP://example.test/a",
        "https://example.test", "mailto:help@example.test", "/caf%C3%A9", "/日本語"
    ])
        assert(validateUrl(valid).code == Status.ok, valid);
    foreach (invalid; [
        "javascript:blocked", "data:blocked", " javaScript:blocked", "http:/broken", "//host",
        "https://", "https:///host", "https://?host", "https://host\\path", "/a\t", "/a\0",
        "/a%0A", "/a%7f", "/a%5c", "/a%", "/a%x0", "/\xc2\x85", "/\xed\xa0\x80"
    ])
        assert(validateUrl(invalid).code == Status.invalidArgument, invalid);
}

@("Escaping preserves empty values, non-ASCII text and existing entity spelling as text")
unittest
{
    ubyte[128] storage;
    scope arena = RequestArena(storage[]);
    const empty = escapeHtml([], arena);
    assert(empty.ok() && equals(arena, empty.value, ""));
    const raw = escapeHtml(cast(const(ubyte)[]) "éf &lt; \"", arena);
    assert(raw.ok() && equals(arena, raw.value, "éf &amp;lt; &quot;"));
    const nul = escapeHtml(cast(const(ubyte)[]) "a\0b", arena);
    assert(nul.ok() && equals(arena, nul.value, "a&#xfffd;b"));
}
