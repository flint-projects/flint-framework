module flint.mail.mail_behavior;

import flint.arena : Error, RequestArena, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.mail : Attachment, MailAddress, MailBackend, MailMessage, MailOptions, MailSender;
import flint.mail.mime : Boundaries, emitMime;
import flint.mail.validation : validate;
import std.algorithm.searching : canFind;
import std.file : readText;
import std.json : parseJSON;
import std.process : environment;

@safe:

private MailMessage testMessage(ref scope RequestArena arena) nothrow @nogc
{
    MailMessage message;
    message.from = MailAddress("sender@example.test", "München");
    message.subject = "Hello, 世界";
    message.text = arena.copyIn(cast(const(ubyte)[]) "line\r\n. leading dot").value;
    message.html = arena.copyIn(cast(const(ubyte)[]) "<strong>hello</strong>").value;
    return message;
}

private string fixture(string name)
{
    return environment.get("FLINT_MAIL_" ~ name, "");
}

@("MIME uses canonical line wraps, encoded fields and private BCC")
unittest
{
    ubyte[1024] memory;
    auto arena = RequestArena(memory[]);
    auto message = testMessage(arena);
    message.to = [MailAddress("visible@example.test")];
    message.bcc = [MailAddress("blind@example.test")];
    immutable ubyte[] binary = [0, 1, 2, 255];
    message.attachments = [
        Attachment("outer/資料.bin", "", arena.copyIn(binary).value),
        Attachment("empty", "application/octet-stream")
    ];
    assert(validate(message).code == Status.ok);
    Boundaries parts;
    parts.mixed[] = "flint-mx-0123456789abcdef0123456789abcdef";
    parts.alternative[] = "flint-al-0123456789abcdef0123456789abcdef";
    size_t limit;
    assert(emitMime(message, parts, arena, 4096, null, limit).code == Status.ok);
    char[4096] data;
    size_t used;
    size_t encoded;
    const outcome = emitMime(message, parts, arena, limit, (scope const(ubyte)[] bytes) {
        data[used .. used + bytes.length] = cast(const(char)[]) bytes[];
        used += bytes.length;
        return Error.init;
    }, encoded);
    assert(outcome.code == Status.ok && encoded == used && limit == used);
    const result = data[0 .. used];
    assert(result.canFind("Subject: =?UTF-8?B?SGVsbG8sIOS4lueVjA==?=\r\n"));
    assert(result.canFind("multipart/mixed") && result.canFind("multipart/alternative"));
    assert(result.canFind("filename*=UTF-8''outer%E8%B3%87%E6%96%99.bin"));
    assert(result.canFind("AAEC/w==\r\n") && !result.canFind("blind@example.test") && !result.canFind("Bcc:"));
    assert(emitMime(message, parts, arena, limit - 1, null, encoded).code == Status.resourceExhausted);
    assert(arena.reset() == Status.ok);
    assert(emitMime(message, parts, arena, limit, null, encoded).code == Status.invalidArgument);
}

@("SMTP labels reject injection and malformed UTF-8")
unittest
{
    ubyte[1024] memory;
    auto arena = RequestArena(memory[]);
    auto message = testMessage(arena);
    message.to = [MailAddress("valid@example.test")];
    foreach (test; ["line\r\nBcc: other", "inject\n", "invalid\xc0\x80"])
    {
        message.subject = test;
        assert(validate(message).code == Status.invalidArgument);
    }
    message.subject = "normal";
    message.to[0].displayName = "display\r\n";
    assert(validate(message).code == Status.invalidArgument);
    message.to[0] = MailAddress("valid@example.test\r\nMAIL FROM: bad");
    assert(validate(message).code == Status.invalidArgument);
}

version (FlintNativeCurl)
{
    private MailOptions options(string peer)
    {
        MailOptions result;
        result.endpoint = fixture(peer);
        result.caBundle = fixture("CA");
        result.username = "test-user";
        result.password = "fixture-only";
        return result;
    }

    private long count(string mode, string field)
    {
        const current = parseJSON(readText(fixture(mode ~ "_PATH") ~ ".json"));
        return current[field].integer;
    }

    @("Pinned SMTP negotiates TLS before auth and preserves BCC only in recipient commands")
    unittest
    {
        if (!fixture("NORMAL").length)
            return;
        foreach (mode; ["NORMAL", "IMPLICIT"])
        {
            MailSender sender;
            const opened = sender.open(options(mode));
            assert(opened.code == Status.ok, opened.message);
            scope (exit)
                assert(sender.close().code == Status.ok);
            ubyte[2048] memory;
            auto arena = RequestArena(memory[]);
            auto message = testMessage(arena);
            message.to = [MailAddress("visible@example.test")];
            message.cc = [MailAddress("copy@example.test")];
            message.bcc = [MailAddress("blind@example.test")];
            const byteContent = arena.copyIn([0, 1, 2, 255]);
            message.attachments = [Attachment("bytes.bin", "", byteContent.value)];

            auto deadline = CancelSource.create(Context.init, Deadline.afterMillis(3_000));
            auto context = deadline.value.context();
            const accepted = sender.send(message, arena, context);
            assert(accepted.ok() && accepted.value.accepted, accepted.error.message);
            assert(arena.read(accepted.value.providerId, (scope const(ubyte)[] value) {
                    assert(value == cast(const(ubyte)[]) "local-receipt");
                }) == Status.ok);
            assert(count(mode, "tls_auth") == 1 && count(mode, "clear_auth") == 0);
            const recorded = readText(fixture(mode ~ "_PATH") ~ ".mime");
            assert(recorded.canFind("multipart/mixed") && recorded.canFind("multipart/alternative"));
            assert(recorded.canFind("AAEC/w==\r\n") && !recorded.canFind("blind@example.test"));
            const envelope = readText(fixture(mode ~ "_PATH") ~ ".json");
            assert(envelope.canFind("blind@example.test"));
        }
    }

    private final class FiberMail
    {
        MailSender sender;
        Status result = Status.unavailable;
        bool ticked;
        bool observedTick;
        ubyte[2048] bytes;
        MailAddress[1] recipients = [MailAddress("visible@example.test")];

        void pulse() @safe nothrow @nogc
        {
            ticked = true;
        }

        void deliver() @safe nothrow @nogc
        {
            import flint.reactor : Reactor;

            scope arena = RequestArena(bytes[]);
            auto message = testMessage(arena);
            message.to = recipients[];
            auto source = CancelSource.create(Context.init, Deadline.afterMillis(3000));
            auto context = source.value.context();
            const sent = sender.send(message, arena, context);
            result = sent.error.code;
            observedTick = ticked;
            assert(sender.close().code == Status.ok);
            auto reactor = Reactor.current();
            reactor.stop();
        }
    }

    @("SMTP uses the reactor fiber without blocking another task")
    unittest
    {
        import flint.reactor : Backend, Reactor, ReactorOptions;

        if (!fixture("FIBER").length)
            return;
        auto mail = new FiberMail;
        assert(mail.sender.open(options("FIBER")).code == Status.ok);
        ReactorOptions config;
        config.backend = Backend.epoll;
        config.cores = 1;
        config.fiberPoolSize = 2;
        auto reactor = Reactor.create(config);
        assert(reactor.ok());
        assert(reactor.value.postStartup(0, &mail.deliver).code == Status.ok);
        assert(reactor.value.postStartup(0, &mail.pulse).code == Status.ok);
        assert(reactor.value.run().code == Status.ok);
        assert(mail.result == Status.ok && mail.observedTick);
        const stats = reactor.value.workerStats(0);
        assert(stats.ok() && stats.value.gcAllocated == 0);
        assert(count("FIBER", "messages") == 1);
    }

    @("TLS, degraded EHLO, invalid reply and cleartext credential policy")
    unittest
    {
        if (!fixture("NORMAL").length)
            return;
        foreach (mode; ["MISSING", "WRONG", "DOWNGRADE", "MALFORMED", "ORDER", "SMALL", "BAD_EHLO"])
        {
            MailSender sender;
            assert(sender.open(options(mode)).code == Status.ok);
            scope (exit)
                assert(sender.close().code == Status.ok);
            ubyte[1024] memory;
            auto arena = RequestArena(memory[]);
            auto message = testMessage(arena);
            message.to = [MailAddress("visible@example.test")];
            auto deadline = CancelSource.create(Context.init, Deadline.afterMillis(3_000));
            auto context = deadline.value.context();
            const result = sender.send(message, arena, context);
            auto expected = Status.permissionDenied;
            if (mode == "MALFORMED" || mode == "ORDER" || mode == "BAD_EHLO")
                expected = Status.ioError;
            if (mode == "SMALL")
                expected = Status.resourceExhausted;
            assert(result.error.code == expected, mode ~ ": " ~ result.error.message);
            assert(count(mode, "clear_auth") == 0 && count(mode, "messages") == 0);
            if (mode == "DOWNGRADE" || mode == "SMALL")
                assert(count(mode, "envelopes") == 0);
            if (mode != "ORDER")
                assert(count(mode, "tls_auth") == 0);
        }

        MailSender local;
        auto policy = options("CLEAR");
        policy.requireTls = false;
        policy.allowLoopbackCleartext = true;
        assert(local.open(policy).code == Status.invalidArgument);
        assert(count("CLEAR", "connections") == 0);
        policy.username = null;
        policy.password = null;
        assert(local.open(policy).code == Status.ok);
        assert(local.close().code == Status.ok);
    }

    @("SMTP retries definite transient refusal and preserves ambiguous post-DATA outcome")
    unittest
    {
        if (!fixture("NORMAL").length)
            return;
        foreach (mode; ["TRANSIENT", "DENIED", "AMBIGUOUS", "STALL"])
        {
            MailSender sender;
            assert(sender.open(options(mode)).code == Status.ok);
            scope (exit)
                assert(sender.close().code == Status.ok);
            ubyte[1024] memory;
            auto arena = RequestArena(memory[]);
            auto message = testMessage(arena);
            message.to = [MailAddress("visible@example.test")];
            auto deadline = CancelSource.create(Context.init, Deadline.afterMillis(mode == "STALL" ? 40 : 3_000));
            auto context = deadline.value.context();
            const result = sender.send(message, arena, context);
            if (mode == "TRANSIENT")
                assert(result.ok() && result.value.accepted && count(mode, "connections") == 2);
            else if (mode == "DENIED")
                assert(result.error.code == Status.permissionDenied && count(mode, "connections") == 1);
            else if (mode == "AMBIGUOUS")
            {
                assert(result.error.code == Status.unavailable
                        && result.error.message == "SMTP delivery is ambiguous after DATA");
                assert(count(mode, "connections") == 1 && count(mode, "messages") == 1);
            }
            else
                assert(result.error.code == Status.timedOut);
        }
    }

    @("Message validation and size preflight never open the loopback socket")
    unittest
    {
        if (!fixture("NORMAL").length)
            return;
        MailSender sender;
        auto config = options("NORMAL");
        config.maxMessageBytes = 100;
        assert(sender.open(config).code == Status.ok);
        scope (exit)
            assert(sender.close().code == Status.ok);
        ubyte[1024] memory;
        auto arena = RequestArena(memory[]);
        auto message = testMessage(arena);
        message.to = [MailAddress("visible@example.test")];
        const before = count("NORMAL", "connections");
        Context context;
        assert(sender.send(message, arena, context).error.code == Status.resourceExhausted);
        message.from.displayName = "Display\nBcc: leak@example.test";
        assert(sender.send(message, arena, context).error.code == Status.invalidArgument);

        ubyte[257] narrowStorage;
        auto narrow = RequestArena(narrowStorage[]);
        assert(narrow.allocate(1, 1).ok());
        message.from.displayName = "";
        message.text = message.html = typeof(message.text).init;
        assert(sender.send(message, narrow, context).error.code == Status.outOfMemory);
        assert(count("NORMAL", "connections") == before);
    }
}

@("Structured provider JSON fits any text body that fits the MIME limit")
unittest
{
    import flint.mail.provider_payload : encodeProvider;

    // Providers reserve 1.5 times the MIME limit for JSON. A line-oriented body that passes the
    // MIME check must not be refused because every line break expanded into a six-byte escape.
    enum limit = 4 * 1024 * 1024;
    auto storage = new ubyte[3 * 1024 * 1024];
    auto arena = RequestArena(storage);
    auto lines = new ubyte[2 * 1024 * 1024 + 512 * 1024];
    foreach (index, ref value; lines)
        value = index % 2 ? '\n' : '\r';
    MailMessage message;
    message.from = MailAddress("sender@example.test");
    message.to = [MailAddress("visible@example.test")];
    message.subject = "lines";
    message.text = arena.copyIn(lines).value;
    assert(validate(message).code == Status.ok);
    Boundaries parts;
    size_t mime;
    assert(emitMime(message, parts, arena, limit, null, mime).code == Status.ok && mime <= limit);

    auto target = new ubyte[limit + limit / 2 + 8192];
    foreach (backend; [MailBackend.resend, MailBackend.postmark])
    {
        size_t length;
        const encoded = encodeProvider(backend, message, parts, arena, target, limit, length);
        assert(encoded.code == Status.ok, encoded.message);
        const document = parseJSON(cast(const(char)[]) target[0 .. length]);
        const text = document[backend == MailBackend.resend ? "text" : "TextBody"].str;
        assert(text.length == lines.length && text[0 .. 4] == "\r\n\r\n");
        assert(document[backend == MailBackend.resend ? "subject" : "Subject"].str == "lines");
    }
}
