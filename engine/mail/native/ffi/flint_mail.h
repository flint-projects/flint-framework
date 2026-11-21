#ifndef FLINT_MAIL_ABI_H
#define FLINT_MAIL_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct flint_mail_transfer flint_mail_transfer;
typedef struct flint_mail_span { const char *data; size_t length; } flint_mail_span;

typedef struct flint_mail_options {
    flint_mail_span endpoint, username, password, ca_bundle;
    unsigned require_tls;
} flint_mail_options;

typedef struct flint_mail_completion {
    int status;
    unsigned reply;
    unsigned retryable;
    unsigned ambiguous;
    size_t receipt_length;
    uint8_t receipt[256];
} flint_mail_completion;

enum { FLINT_MAIL_CHUNK = 16384, FLINT_MAIL_WAIT = 12 };

int flint_mail_available(void);
int flint_mail_begin(const flint_mail_options *options, flint_mail_span from, const flint_mail_span *recipients,
                     size_t recipient_count, size_t mime_size, flint_mail_transfer **output);
int flint_mail_push(flint_mail_transfer *job, const uint8_t *data, size_t length);
int flint_mail_step(flint_mail_transfer *job);
int flint_mail_poll(flint_mail_transfer *job, unsigned milliseconds);
int flint_mail_result(flint_mail_transfer *job, flint_mail_completion *output);
void flint_mail_release(flint_mail_transfer *job);

#ifdef __cplusplus
}
#endif
#endif
