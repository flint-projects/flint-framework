module app;

import flint.arena : Buffer, RequestArena, Status;
import flint.conc : CancelSource, Context, Deadline;
import flint.mail : Attachment, MailAddress, MailMessage, MailOptions, MailSender;
import probe_workload : exercise;
import std.datetime.stopwatch : StopWatch, AutoStart;

@safe:

private long deliver(scope string endpoint, scope string ca, ref scope RequestArena arena, Buffer attachment)
{
    // Configuration is immutable and retained by the sender during this call.
    MailOptions options;
    options.endpoint = endpoint.idup;
    options.caBundle = ca.idup;
    options.username = "test-user";
    options.password = "fixture-only";
    options.maxMessageBytes = 16 * 1024 * 1024;
    MailSender sender;
    if (sender.open(options).code != Status.ok)
        return -1;
    MailMessage mail;
    mail.from = MailAddress("sender@example.test");
    mail.to = [MailAddress("visible@example.test")];
    mail.subject = "SMTP attachment size fixture";
    const text = arena.copyIn(cast(const(ubyte)[]) "benchmark");
    const html = arena.copyIn(cast(const(ubyte)[]) "<p>benchmark</p>");
    if (!text.ok() || !html.ok())
        return -1;
    mail.text = text.value;
    mail.html = html.value;
    mail.attachments = [Attachment("attachment.bin", "application/octet-stream", attachment)];
    auto source = CancelSource.create(Context.init, Deadline.afterMillis(10_000));
    auto context = source.value.context();
    const watch = StopWatch(AutoStart.yes);
    const sent = sender.send(mail, arena, context);
    const elapsed = watch.peek.total!"msecs";
    const closed = sender.close();
    return sent.ok() && sent.value.accepted && sent.value.providerId.length != 0
        && closed.code == Status.ok ? elapsed : -1;
}

int main(string[] args)
{
    return exercise(args, &deliver);
}
