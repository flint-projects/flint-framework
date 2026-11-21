/* AddressSanitizer/UBSan boundary corpus. No network work is started here. */
#include "flint_mail.h"

#include <assert.h>
#include <stdint.h>
#include <string.h>

enum {
    status_ok = 0, status_argument = 1
};

#define SPAN(s) ((flint_mail_span){(s), sizeof(s) - 1})

int main(void)
{
    flint_mail_options options = {
        .endpoint = SPAN("smtp://127.0.0.1:1"),
        .require_tls = 0,
    };
    const flint_mail_span sender = SPAN("sender@example.test");
    flint_mail_span recipients[100];
    for (size_t i = 0; i < 100; ++i)
        recipients[i] = SPAN("mailbox@example.test");
    flint_mail_transfer *job = NULL;
    assert(flint_mail_available() == status_ok);
    assert(flint_mail_begin(NULL, sender, recipients, 1, 1, &job) == status_argument && !job);
    assert(flint_mail_begin(&options, sender, recipients, 0, 1, &job) == status_argument && !job);
    assert(flint_mail_begin(&options, sender, recipients, 101, 1, &job) == status_argument && !job);
    assert(flint_mail_begin(&options, sender, recipients, 1, SIZE_MAX, &job) == status_argument && !job);
    assert(flint_mail_begin(&options, sender, recipients, 1, 0, &job) == status_argument && !job);
    assert(flint_mail_begin(&options, sender, recipients, 1, 1, NULL) == status_argument);
    options.username = SPAN("fixture-user");
    options.password = SPAN("fixture-password");
    assert(flint_mail_begin(&options, sender, recipients, 1, 1, &job) == status_argument && !job);
    options.username = SPAN("");
    options.password = SPAN("");
    options.endpoint = SPAN("smtp://127.0.0.1:1/path");
    assert(flint_mail_begin(&options, sender, recipients, 1, 1, &job) == status_argument && !job);
    options.endpoint = SPAN("smtp://127.0.0.1:1");
    recipients[0] = SPAN("mailbox@example.test\r\nsecret");
    assert(flint_mail_begin(&options, sender, recipients, 1, 1, &job) == status_argument && !job);
    recipients[0] = SPAN("mailbox@example.test");
    for (unsigned pass = 0; pass < 64; ++pass) {
        assert(flint_mail_begin(&options, sender, recipients, 100, FLINT_MAIL_CHUNK + 1, &job) == status_ok);
        uint8_t data[FLINT_MAIL_CHUNK];
        memset(data, pass, sizeof(data));
        assert(flint_mail_push(job, NULL, 1) == status_argument);
        assert(flint_mail_push(job, data, 0) == status_argument);
        assert(flint_mail_push(job, data, FLINT_MAIL_CHUNK + 1) == status_argument);
        assert(flint_mail_push(job, data, FLINT_MAIL_CHUNK) == status_ok);
        assert(flint_mail_push(job, data, 1) == FLINT_MAIL_WAIT);
        assert(flint_mail_poll(job, 11) == status_argument);
        flint_mail_completion outcome;
        assert(flint_mail_result(job, &outcome) == FLINT_MAIL_WAIT && !outcome.ambiguous);
        flint_mail_release(job);
    }
    flint_mail_release(NULL);
    return 0;
}
