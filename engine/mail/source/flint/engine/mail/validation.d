/// Practical mailbox syntax and bounded MIME field validation.
module flint.engine.mail.validation;

import flint.arena : Error, Status;
import flint.engine.mail.types : MailAddress, MailMessage;

@safe:

pure nothrow @nogc:

package(flint.engine.mail) enum maximumRecipients = 100;
package(flint.engine.mail) enum maximumAttachments = 32;

private bool letterOrDigit(char value)
{
    return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || (value >= '0' && value <= '9');
}

private bool atom(char value)
{
    if (letterOrDigit(value))
        return true;
    foreach (symbol; "!#$%&'*+-/=?^_`{|}~")
        if (symbol == value)
            return true;
    return false;
}

private bool localPart(scope const(char)[] value)
{
    if (!value.length || value.length > 64)
        return false;
    bool dot = true;
    foreach (item; value)
    {
        if (item == '.')
        {
            if (dot)
                return false;
            dot = true;
        }
        else
        {
            if (!atom(item))
                return false;
            dot = false;
        }
    }
    return !dot;
}

package(flint.engine.mail) bool domain(scope const(char)[] value)
{
    if (!value.length || value.length > 253)
        return false;
    size_t label;
    foreach (index, item; value)
    {
        if (item == '.')
        {
            if (!label || value[index - 1] == '-')
                return false;
            label = 0;
        }
        else
        {
            if ((!letterOrDigit(item) && (item != '-' || label == 0)) || ++label > 63)
                return false;
        }
    }
    return label != 0 && value[$ - 1] != '-';
}

package(flint.engine.mail) bool mailbox(scope const(char)[] value)
{
    if (value.length > 254)
        return false;
    foreach (index, item; value)
        if (item == '@')
            return localPart(value[0 .. index]) && domain(value[index + 1 .. $]);
    return false;
}

private uint utfLength(ubyte first)
{
    if (first >= 0xc2 && first <= 0xdf)
        return 2;
    if (first >= 0xe0 && first <= 0xef)
        return 3;
    if (first >= 0xf0 && first <= 0xf4)
        return 4;
    return 0;
}

package(flint.engine.mail) bool headerText(scope const(char)[] text, size_t maximum, bool allowControls = false)
{
    if (text.length > maximum)
        return false;
    size_t cursor;
    while (cursor < text.length)
    {
        const first = cast(ubyte) text[cursor++];
        if (first < 0x80)
        {
            if (!allowControls && (first < ' ' || first == 0x7f))
                return false;
            continue;
        }
        const count = utfLength(first);
        if (!count || count - 1 > text.length - cursor)
            return false;
        if (!validContinuation(first, cast(const(ubyte)[]) text[cursor .. cursor + count - 1]))
            return false;
        cursor += count - 1;
    }
    return true;
}

private bool validContinuation(ubyte first, scope const(ubyte)[] tail)
{
    const second = tail[0];
    if ((first == 0xe0 && second < 0xa0) || (first == 0xed && second >= 0xa0) || (first == 0xf0
            && second < 0x90) || (first == 0xf4 && second > 0x8f))
        return false;
    foreach (byteValue; tail)
        if ((byteValue & 0xc0) != 0x80)
            return false;
    return true;
}

private bool validAddress(scope const ref MailAddress address)
{
    return mailbox(address.address) && headerText(address.displayName, 256);
}

private bool contentType(scope const(char)[] value)
{
    if (!value.length)
        return true;
    if (value.length > 127 || value[0] == '/' || value[$ - 1] == '/')
        return false;
    uint separators;
    foreach (item; value)
    {
        if (item == '/')
            ++separators;
        else if (!letterOrDigit(item) && item != '-' && item != '+' && item != '.')
            return false;
    }
    return separators == 1;
}

package(flint.engine.mail) Error validate(scope const ref MailMessage mail)
{
    static const Error invalid = Error(Status.invalidArgument, "invalid mail envelope or MIME field");
    if (!validAddress(mail.from) || !headerText(mail.subject, 1024)
            || !headerText(mail.idempotencyKey, 128)
            || mail.attachments.length > maximumAttachments || !validRecipients(mail))
        return invalid;
    foreach (ref file; mail.attachments)
        if (!file.fileName.length || !headerText(file.fileName, 256) || !contentType(file.contentType))
            return invalid;
    return Error.init;
}

private bool validRecipients(scope const ref MailMessage mail)
{
    if (mail.to.length > maximumRecipients || mail.cc.length > maximumRecipients || mail.bcc.length > maximumRecipients)
        return false;
    const count = mail.to.length + mail.cc.length + mail.bcc.length;
    if (!count || count > maximumRecipients)
        return false;
    foreach (group; [mail.to, mail.cc, mail.bcc])
        foreach (ref address; group)
            if (!validAddress(address))
                return false;
    return true;
}
