/// Transactional submission over the verified, no-redirect HTTP client.
module flint.engine.mail.providers;

import flint.arena : Error, RequestArena, Result, Status;
import flint.conc : Context;
import flint.engine.http : ClientOptions, HttpAwsV4, HttpClient, HttpMethod, HttpRequestView,
    HttpResponse, HttpStreamField;
import flint.engine.mail.mime : Boundaries;
import flint.engine.mail.provider_payload : encodeProvider;
import flint.engine.mail.provider_reply : ProviderId, providerReply;
import flint.engine.mail.types : DeliveryReceipt, MailBackend, MailMessage, MailOptions;

@safe:

package(flint.engine.mail) struct Providers
{
    private HttpClient client;
    private ubyte[] payload;
    private ubyte[] response;
    private char[] bearer;
    private HttpStreamField[] fields;

    Error open(MailOptions options)
    {
        ClientOptions config;
        config.maxConnections = 1;
        config.maxConnectionsPerOrigin = 1;
        config.maxResponseBytes = 16_384;
        config.maxHeaderBytes = 16_384;
        config.caBundle = options.caBundle;
        const authorized = client.open(config);
        if (authorized.code != Status.ok)
            return authorized;
        payload = new ubyte[options.maxMessageBytes + options.maxMessageBytes / 2 + 8192];
        response = new ubyte[40_960];
        fields = [
            HttpStreamField("Content-Type", "application/json"),
            HttpStreamField("Accept", "application/json")
        ];
        if (options.backend == MailBackend.resend)
        {
            bearer = new char[7 + options.password.length];
            bearer[0 .. 7] = "Bearer ";
            bearer[7 .. $] = options.password[];
            fields ~= HttpStreamField("Authorization", bearer);
        }
        if (options.backend == MailBackend.postmark)
            fields ~= HttpStreamField("X-Postmark-Server-Token", options.password);
        if (options.backend == MailBackend.ses && options.sesSessionToken.length)
            fields ~= HttpStreamField("X-Amz-Security-Token", options.sesSessionToken);
        return Error.init;
    }

    Error close() nothrow @nogc
    {
        const closed = client.close();
        if (closed.code == Status.ok)
        {
            bearer[] = 0;
            bearer = null;
            fields = null;
            payload = null;
            response = null;
        }
        return closed;
    }

    Result!DeliveryReceipt send(scope const ref MailOptions options, scope const ref MailMessage message,
            scope const ref Boundaries parts, ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        if (message.idempotencyKey.length && options.backend != MailBackend.resend)
            return denied(Error(Status.unsupported, "mail provider does not accept an idempotency key"));
        size_t length;
        const ready = encodeProvider(options.backend, message, parts, arena, payload, options.maxMessageBytes, length);
        scope (exit)
            payload[0 .. length] = 0;
        if (ready.code != Status.ok)
            return denied(ready);
        scope request = HttpRequestView(HttpMethod.post, options.endpoint);
        request.body = payload[0 .. length];
        request.headers = fields;
        if (message.idempotencyKey.length)
            request.finalField = HttpStreamField("Idempotency-Key", message.idempotencyKey);
        if (options.backend == MailBackend.ses)
            request.awsV4 = HttpAwsV4(options.sesRegion, "ses", options.username, options.password);

        auto scratch = RequestArena(response);
        auto reply = client.sendView(request, scratch, context);
        if (reply.ok() && reply.value.status == 429 && context.check().code == Status.ok)
        {
            const reset = scratch.reset();
            if (reset != Status.ok)
                return denied(Error(reset, "cannot reset mail acknowledgement storage"));
            reply = client.sendView(request, scratch, context);
        }
        return receipt(reply, options.backend, scratch, arena);
    }
}

private Result!DeliveryReceipt denied(Error error) pure nothrow @nogc
{
    return Result!DeliveryReceipt(DeliveryReceipt.init, error);
}

private Error httpFailure(ushort status) pure nothrow @nogc
{
    switch (status)
    {
    case 401:
    case 403:
        return Error(Status.permissionDenied, "mail provider credentials rejected");
    case 429:
        return Error(Status.unavailable, "mail provider rate limited the submission");
    case 413:
        return Error(Status.resourceExhausted, "mail provider message size limit");
    case 400:
    case 409:
    case 422:
        return Error(Status.invalidArgument, "mail provider rejected the message");
    default:
        return Error(Status.unavailable, "mail provider did not confirm acceptance");
    }
}

private Result!DeliveryReceipt receipt(Result!HttpResponse reply, MailBackend backend,
        ref scope RequestArena response, ref scope RequestArena arena) nothrow @nogc
{
    if (!reply.ok())
    {
        if (reply.error.code == Status.ioError || reply.error.code == Status.unavailable)
            return denied(Error(Status.unavailable, "mail provider submission has an ambiguous outcome"));
        return denied(reply.error);
    }
    if (reply.value.status < 200 || reply.value.status > 299)
        return denied(httpFailure(reply.value.status));
    ProviderId id;
    Error parsed;
    const checked = response.read(reply.value.body, (scope const(ubyte)[] bytes) {
        parsed = providerReply(bytes, backend, id);
    });
    if (checked != Status.ok)
        return denied(Error(Status.unavailable, "mail provider acceptance acknowledgement unavailable"));
    if (parsed.code != Status.ok)
        return denied(parsed);
    const copied = arena.copyIn(id.data[0 .. id.length]);
    return Result!DeliveryReceipt(DeliveryReceipt(copied.value, true), copied.error);
}
