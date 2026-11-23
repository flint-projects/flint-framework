module flint.engine.mail.provider_behavior;

version (FlintNativeCurl)
{
    import flint.arena : RequestArena, Status;
    import flint.conc : CancelSource, Context, Deadline;
    import flint.engine.http : ClientOptions, HttpAwsV4, HttpClient, HttpMethod, HttpRequestView, HttpStreamField;
    import flint.engine.mail : Attachment, MailAddress, MailBackend, MailMessage, MailOptions, MailSender;
    import std.conv : to;
    import std.file : readText;
    import std.process : environment;

@safe:

    private string fixture(string key)
    {
        return environment.get("FLINT_MAIL_" ~ key, "");
    }

    private int calls(string key)
    {
        return readText(fixture(key ~ "_PATH")).to!int;
    }

    private MailOptions config(MailBackend backend, string peer)
    {
        MailOptions result;
        result.backend = backend;
        result.endpoint = fixture(peer);
        result.caBundle = fixture("CA");
        result.maxMessageBytes = 8192;
        final switch (backend)
        {
        case MailBackend.smtp:
            assert(0);
        case MailBackend.resend:
            result.password = "fixture-resend";
            break;
        case MailBackend.postmark:
            result.password = "fixture-postmark";
            break;
        case MailBackend.ses:
            result.username = "FLINTFIXTURE000000001";
            result.password = "fixture-aws-sigv4-key-unused-outside-loopback";
            result.sesSessionToken = "fixture-session";
            break;
        }
        return result;
    }

    private void check(MailBackend backend, string peer, Status status, int expectedCalls,
            string id = "", string message = "")
    {
        MailSender sender;
        const opened = sender.open(config(backend, peer));
        assert(opened.code == Status.ok, opened.message);
        scope (exit)
            assert(sender.close().code == Status.ok);
        ubyte[2048] memory;
        auto arena = RequestArena(memory[]);
        MailMessage mail;
        mail.from = MailAddress("sender@example.test", "München");
        mail.to = [MailAddress("visible@example.test")];
        mail.bcc = [MailAddress("blind@example.test")];
        mail.subject = "Hello, 世界";
        mail.text = arena.copyIn(cast(const(ubyte)[]) "line\r\n. leading dot").value;
        mail.html = arena.copyIn(cast(const(ubyte)[]) "<strong>hello</strong>").value;
        mail.attachments = [Attachment("bytes.bin", "", arena.copyIn([0, 1, 2, 255]).value)];
        if (backend == MailBackend.resend)
            mail.idempotencyKey = "fixture-message-1";
        auto source = CancelSource.create(Context.init, Deadline.afterMillis(3000));
        assert(source.ok());
        auto context = source.value.context();
        const sent = sender.send(mail, arena, context);
        assert(sent.error.code == status, peer ~ " " ~ sent.error.code.to!string ~ " " ~ sent.error.message);
        assert(sent.value.accepted == (status == Status.ok));
        if (sent.ok())
            assert(arena.read(sent.value.providerId, (scope const(ubyte)[] bytes) {
                    assert(bytes == cast(const(ubyte)[]) id);
                }) == Status.ok);
        if (message.length)
            assert(sent.error.message == message);
        assert(calls(peer) == expectedCalls, peer);
    }

    @("Transactional providers verify distinct payloads, credentials and acceptance")
    unittest
    {
        if (!fixture("HTTP_SES_OK").length)
            return;
        check(MailBackend.resend, "HTTP_RESEND_OK", Status.ok, 1, "resend-fixture-id");
        check(MailBackend.postmark, "HTTP_POSTMARK_OK", Status.ok, 1, "postmark-fixture-id");
        check(MailBackend.ses, "HTTP_SES_OK", Status.ok, 1, "ses-fixture-id");
        check(MailBackend.resend, "HTTP_RESEND_RATE", Status.ok, 2, "resend-fixture-id");
        check(MailBackend.postmark, "HTTP_POSTMARK_RATE", Status.ok, 2, "postmark-fixture-id");
        check(MailBackend.ses, "HTTP_SES_RATE", Status.ok, 2, "ses-fixture-id");
        check(MailBackend.resend, "HTTP_RESEND_DENIED", Status.permissionDenied, 1);
        check(MailBackend.postmark, "HTTP_POSTMARK_DENIED", Status.permissionDenied, 1);
        check(MailBackend.ses, "HTTP_SES_DENIED", Status.permissionDenied, 1);
        check(MailBackend.postmark, "HTTP_POSTMARK_POSTMARK_ERROR", Status.invalidArgument, 1);
    }

    @("Ambiguous delivery is never repeated and signed requests never redirect")
    unittest
    {
        if (!fixture("HTTP_SES_OK").length)
            return;
        check(MailBackend.resend, "HTTP_RESEND_AMBIGUOUS", Status.unavailable, 1, "",
                "mail provider submission has an ambiguous outcome");
        check(MailBackend.resend, "HTTP_RESEND_INVALID_ID", Status.unavailable, 1);
        check(MailBackend.resend, "HTTP_RESEND_INVALID_JSON", Status.unavailable, 1);
        check(MailBackend.ses, "HTTP_SES_REDIRECT", Status.unavailable, 1);
        check(MailBackend.ses, "HTTP_SES_WRONG_HOST", Status.permissionDenied, 0);
        assert(calls("HTTP_SES_TARGET") == 0);
    }

    @("SigV4 rejects an unsigned authorization override and cleartext before a request")
    unittest
    {
        const endpoint = fixture("HTTP_SES_TARGET");
        if (!endpoint.length)
            return;
        ClientOptions options;
        options.caBundle = fixture("CA");
        HttpClient client;
        assert(client.open(options).code == Status.ok);
        scope (exit)
            assert(client.close().code == Status.ok);
        ubyte[2048] memory;
        auto arena = RequestArena(memory[]);
        Context context;
        scope request = HttpRequestView(HttpMethod.post, endpoint);
        request.awsV4 = HttpAwsV4("us-east-1", "ses", "FLINTFIXTURE000000001", "fixture-secret");
        request.finalField = HttpStreamField("Authorization", "forbidden override");
        assert(client.sendView(request, arena, context).error.code == Status.invalidArgument);
        request.finalField = HttpStreamField.init;
        request.url = "http" ~ endpoint[5 .. $];
        assert(client.sendView(request, arena, context).error.code == Status.invalidArgument);
        assert(calls("HTTP_SES_TARGET") == 0);
    }
}
