#define _POSIX_C_SOURCE 200809L
#include "flint_mail.h"

#if defined(__linux__) && defined(FLINT_HAS_CURL)

#include <curl/curl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

enum {
    MAIL_OK, MAIL_ARGUMENT, MAIL_MEMORY, MAIL_CANCELLED, MAIL_TIMEOUT, MAIL_NOT_FOUND, MAIL_CONFLICT,
    MAIL_IO, MAIL_UNAVAILABLE, MAIL_UNSUPPORTED, MAIL_DENIED, MAIL_EXHAUSTED
};

struct flint_mail_transfer {
    CURLM *multi;
    CURL *easy;
    struct curl_slist *recipients;
    size_t expected, supplied, delivered, offset, length;
    uint8_t chunk[FLINT_MAIL_CHUNK];
    uint64_t activity;
    unsigned multiline;
    unsigned expected_reply;
    unsigned final_reply;
    bool added, paused, done, bad_reply, data_started;
    bool credentials, require_tls, tls_wire, ehlo, advertises_auth, auth_required, awaiting_data;
    bool size_refused;
    flint_mail_completion completion;
};

static pthread_once_t startup = PTHREAD_ONCE_INIT;
static int availability = MAIL_UNAVAILABLE;

static void initialize(void)
{
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK)
        return;
    const curl_version_info_data *version = curl_version_info(CURLVERSION_NOW);
    availability = MAIL_UNSUPPORTED;
    if (version && version->protocols && (version->features & CURL_VERSION_SSL))
        for (const char *const *name = version->protocols; *name; ++name)
            if (strcmp(*name, "smtp") == 0) {
                availability = MAIL_OK;
                break;
            }
    if (availability != MAIL_OK) {
        curl_global_cleanup();
    } else if (atexit(curl_global_cleanup)) {
        curl_global_cleanup();
        availability = MAIL_UNAVAILABLE;
    }
}

int flint_mail_available(void)
{
    return pthread_once(&startup, initialize) ? MAIL_UNAVAILABLE : availability;
}

static uint64_t clock_ms(void)
{
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value))
        return 0;
    return (uint64_t)value.tv_sec * 1000 + (uint64_t)value.tv_nsec / 1000000;
}

static bool safe_span(flint_mail_span text, size_t limit, bool empty)
{
    if (!text.length)
        return empty;
    if (!text.data || text.length > limit)
        return false;
    for (size_t i = 0; i < text.length; ++i) {
        const unsigned char item = (unsigned char)text.data[i];
        if (item < ' ' || item == 0x7f)
            return false;
    }
    return true;
}

static bool starts(flint_mail_span text, const char *prefix)
{
    const size_t length = strlen(prefix);
    return text.length >= length && memcmp(text.data, prefix, length) == 0;
}

static bool numeric_loopback(flint_mail_span url)
{
    const char ipv4[] = "smtp://127.0.0.1";
    const char ipv6[] = "smtp://[::1]";
    const size_t end = starts(url, ipv4) ? sizeof(ipv4) - 1 : starts(url, ipv6) ? sizeof(ipv6) - 1 : 0;
    if (!end)
        return false;
    if (url.length == end)
        return true;
    if (url.data[end] != ':' || end + 1 == url.length)
        return false;
    for (size_t i = end + 1; i < url.length; ++i)
        if (url.data[i] < '0' || url.data[i] > '9')
            return false;
    return true;
}

static bool options_valid(const flint_mail_options *options)
{
    if (!options || options->require_tls > 1 || !safe_span(options->endpoint, 1024, false)
        || !safe_span(options->username, 512, true) || !safe_span(options->password, 1024, true)
        || !safe_span(options->ca_bundle, 4096, true)
        || (!options->username.length != !options->password.length))
        return false;
    if (!starts(options->endpoint, "smtp://") && !starts(options->endpoint, "smtps://"))
        return false;
    return options->require_tls || (!options->username.length && numeric_loopback(options->endpoint));
}

static void terminate(char *out, flint_mail_span text)
{
    if (text.length)
        memcpy(out, text.data, text.length);
    out[text.length] = 0;
}

static bool add_recipient(flint_mail_transfer *job, flint_mail_span recipient)
{
    char address[257];
    if (!safe_span(recipient, 254, false))
        return false;
    address[0] = '<';
    memcpy(address + 1, recipient.data, recipient.length);
    address[recipient.length + 1] = '>';
    address[recipient.length + 2] = 0;
    struct curl_slist *added = curl_slist_append(job->recipients, address);
    if (!added)
        return false;
    job->recipients = added;
    return true;
}

static size_t upload(char *out, size_t size, size_t count, void *context)
{
    flint_mail_transfer *job = context;
    if (size && count > SIZE_MAX / size)
        return CURL_READFUNC_ABORT;
    const size_t capacity = size * count;
    if (job->offset == job->length) {
        if (job->delivered == job->expected)
            return 0;
        job->paused = true;
        return CURL_READFUNC_PAUSE;
    }
    const size_t queued = job->length - job->offset;
    const size_t taken = capacity < queued ? capacity : queued;
    memcpy(out, job->chunk + job->offset, taken);
    job->offset += taken;
    job->delivered += taken;
    job->activity = clock_ms();
    return taken;
}

static bool digit(char value)
{
    return value >= '0' && value <= '9';
}

static void receipt(flint_mail_transfer *job, const char *line, size_t length)
{
    while (length && (line[length - 1] == '\r' || line[length - 1] == '\n'))
        --length;
    const char marker[] = "queued as ";
    for (size_t i = 0; i + sizeof(marker) - 1 < length; ++i)
        if (memcmp(line + i, marker, sizeof(marker) - 1) == 0) {
            const size_t advance = i + sizeof(marker) - 1;
            line += advance;
            length -= advance;
            break;
        }
    if (length > sizeof(job->completion.receipt))
        return;
    for (size_t i = 0; i < length; ++i)
        if ((unsigned char)line[i] < ' ' || (unsigned char)line[i] >= 0x7f)
            return;
    memcpy(job->completion.receipt, line, length);
    job->completion.receipt_length = length;
}

static bool fits_limit(size_t expected, const char *text, size_t length)
{
    if (length < 6 || strncasecmp(text, "SIZE ", 5) != 0)
        return true;
    size_t limit = 0;
    for (size_t i = 5; i < length; ++i) {
        if (!digit(text[i]))
            return true;
        if (limit < expected)
            limit = limit * 10 + (size_t)(text[i] - '0');
    }
    return !limit || limit >= expected;
}

static bool expected_reply(const flint_mail_transfer *job, unsigned code)
{
    return code >= 400 || code == job->expected_reply
        || (job->expected_reply == 235 && code == 334) || (job->expected_reply == 251 && code == 250);
}

static bool line_received(flint_mail_transfer *job, const char *line, size_t length)
{
    if (length < 5 || length > 512 || line[length - 2] != '\r' || line[length - 1] != '\n'
        || !digit(line[0]) || !digit(line[1]) || !digit(line[2])) {
        job->bad_reply = true;
        return false;
    }
    const unsigned code = (unsigned)(line[0] - '0') * 100 + (unsigned)(line[1] - '0') * 10 + line[2] - '0';
    if (code < 200 || code > 599 || !expected_reply(job, code)
        || (job->multiline && code != job->multiline)) {
        job->bad_reply = true;
        return false;
    }
    if (job->ehlo && code == 250 && length >= 11) {
        if (strncasecmp(line + 4, "AUTH ", 5) == 0)
            job->advertises_auth = true;
        if ((job->tls_wire || !job->require_tls) && !fits_limit(job->expected, line + 4, length - 6)) {
            job->size_refused = true;
            return false;
        }
    }
    if (line[3] == '-') {
        job->multiline = code;
        return true;
    }
    if (line[3] != ' ' && line[3] != '\r') {
        job->bad_reply = true;
        return false;
    }
    job->multiline = 0;
    if (job->ehlo) {
        job->ehlo = false;
        if (code == 250 && job->tls_wire && job->credentials && !job->advertises_auth) {
            job->auth_required = true;
            return false;
        }
    }
    if (job->data_started && !job->final_reply && job->delivered == job->expected) {
        job->final_reply = code;
        if (code == 250 && length > 4)
            receipt(job, line + 4, length - 4);
    }
    if (job->awaiting_data) {
        job->awaiting_data = false;
        if (code == 354) {
            job->data_started = true;
            job->expected_reply = 250;
        }
    }
    return true;
}

static size_t headers(char *text, size_t size, size_t count, void *context)
{
    flint_mail_transfer *job = context;
    if (size && count > SIZE_MAX / size)
        return 0;
    const size_t length = size * count;
    job->activity = clock_ms();
    return line_received(job, text, length) ? length : 0;
}

static int observe(CURL *easy, curl_infotype kind, char *text, size_t length, void *data)
{
    (void)easy;
    flint_mail_transfer *job = data;
    if (kind == CURLINFO_SSL_DATA_IN || kind == CURLINFO_SSL_DATA_OUT)
        job->tls_wire = true;
    if (kind == CURLINFO_HEADER_OUT) {
        job->activity = clock_ms();
        const flint_mail_span command = {text, length};
        if (starts(command, "DATA\r\n")) {
            job->awaiting_data = true;
            job->expected_reply = 354;
        } else if (starts(command, "EHLO ")) {
            job->ehlo = true;
            job->advertises_auth = false;
            job->expected_reply = 250;
        } else if (starts(command, "HELO ") || starts(command, "MAIL FROM:")) {
            job->expected_reply = 250;
        } else if (starts(command, "RCPT TO:")) {
            job->expected_reply = 251;
        } else if (starts(command, "STARTTLS\r\n")) {
            job->expected_reply = 220;
        } else if (starts(command, "AUTH ")) {
            job->expected_reply = 235;
        } else if (starts(command, "QUIT\r\n")) {
            job->expected_reply = 221;
        }
    }
    /* Ignore command contents and disable all provider debug output. */
    return 0;
}

static int bind_transfer(flint_mail_transfer *job, const flint_mail_options *options, flint_mail_span from)
{
    char endpoint[1025], sender[255], ca[4097], username[513], password[1025];
    terminate(endpoint, options->endpoint);
    terminate(sender, from);
    terminate(ca, options->ca_bundle);
    terminate(username, options->username);
    terminate(password, options->password);
    CURL *easy = job->easy;
    job->credentials = options->username.length != 0;
    job->require_tls = options->require_tls != 0;
    job->tls_wire = starts(options->endpoint, "smtps://");
    const bool bound =
        curl_easy_setopt(easy, CURLOPT_URL, endpoint) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "smtp,smtps") == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_PROXY, "") == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, 10000L) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_SERVER_RESPONSE_TIMEOUT_MS, 10000L) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_USE_SSL, options->require_tls ? CURLUSESSL_ALL : CURLUSESSL_NONE) == CURLE_OK
        && (!options->ca_bundle.length || curl_easy_setopt(easy, CURLOPT_CAINFO, ca) == CURLE_OK)
        && (!options->username.length || (curl_easy_setopt(easy, CURLOPT_USERNAME, username) == CURLE_OK
            && curl_easy_setopt(easy, CURLOPT_PASSWORD, password) == CURLE_OK))
        && curl_easy_setopt(easy, CURLOPT_MAIL_FROM, sender) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_MAIL_RCPT, job->recipients) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_UPLOAD, 1L) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_UPLOAD_BUFFERSIZE, (long)FLINT_MAIL_CHUNK) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_INFILESIZE_LARGE, (curl_off_t)job->expected) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_READFUNCTION, upload) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_READDATA, job) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, headers) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_HEADERDATA, job) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_VERBOSE, 1L) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_DEBUGFUNCTION, observe) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_DEBUGDATA, job) == CURLE_OK;
    volatile char *scrub = password;
    for (size_t i = 0; i < sizeof(password); ++i)
        scrub[i] = 0;
    return bound ? MAIL_OK : MAIL_IO;
}

int flint_mail_begin(const flint_mail_options *options, flint_mail_span from, const flint_mail_span *recipients,
                     size_t recipient_count, size_t mime_size, flint_mail_transfer **output)
{
    if (!output)
        return MAIL_ARGUMENT;
    *output = NULL;
    if (!options_valid(options) || !safe_span(from, 254, false) || !recipients || recipient_count == 0
        || recipient_count > 100 || mime_size == 0 || mime_size > 64 * 1024 * 1024)
        return MAIL_ARGUMENT;
    const int available = flint_mail_available();
    if (available)
        return available;
    flint_mail_transfer *job = calloc(1, sizeof(*job));
    if (!job)
        return MAIL_MEMORY;
    int status = MAIL_MEMORY;
    job->easy = curl_easy_init();
    job->multi = curl_multi_init();
    job->activity = clock_ms();
    job->expected = mime_size;
    job->expected_reply = 220;
    if (!job->easy || !job->multi)
        goto failure;
    for (size_t i = 0; i < recipient_count; ++i) {
        if (!add_recipient(job, recipients[i])) {
            status = MAIL_ARGUMENT;
            goto failure;
        }
    }
    status = bind_transfer(job, options, from);
    if (status)
        goto failure;
    if (curl_multi_add_handle(job->multi, job->easy) != CURLM_OK) {
        status = MAIL_IO;
        goto failure;
    }
    job->added = true;
    *output = job;
    return MAIL_OK;

failure:
    flint_mail_release(job);
    return status;
}

int flint_mail_push(flint_mail_transfer *job, const uint8_t *data, size_t length)
{
    if (!job || !data || !length || length > sizeof(job->chunk) || length > job->expected - job->supplied)
        return MAIL_ARGUMENT;
    if (job->done)
        return MAIL_CONFLICT;
    if (job->offset < job->length)
        return FLINT_MAIL_WAIT;
    memcpy(job->chunk, data, length);
    job->length = length;
    job->offset = 0;
    job->supplied += length;
    if (job->paused) {
        job->paused = false;
        if (curl_easy_pause(job->easy, CURLPAUSE_CONT) != CURLE_OK)
            return MAIL_IO;
    }
    return MAIL_OK;
}

static bool tls_failure(CURLcode result)
{
    return result == CURLE_USE_SSL_FAILED || result == CURLE_SSL_CONNECT_ERROR
        || result == CURLE_PEER_FAILED_VERIFICATION || result == CURLE_SSL_CACERT_BADFILE
        || result == CURLE_LOGIN_DENIED;
}

static void finished(flint_mail_transfer *job, CURLcode result)
{
    long response = 0;
    curl_easy_getinfo(job->easy, CURLINFO_RESPONSE_CODE, &response);
    const unsigned reply = job->final_reply ? job->final_reply : response > 0 ? (unsigned)response : 0;
    job->done = true;
    job->completion.reply = reply;
    if (job->auth_required) {
        job->completion.status = MAIL_DENIED;
    } else if (job->size_refused || reply == 552) {
        job->completion.status = MAIL_EXHAUSTED;
    } else if (job->final_reply == 250) {
        job->completion.status = MAIL_OK;
    } else if (job->data_started && job->delivered == job->expected && !job->final_reply) {
        job->completion.status = MAIL_UNAVAILABLE;
        job->completion.ambiguous = 1;
    } else if (job->bad_reply) {
        job->completion.status = MAIL_IO;
    } else if (tls_failure(result) || reply >= 500) {
        job->completion.status = MAIL_DENIED;
    } else if (reply >= 400) {
        job->completion.status = MAIL_UNAVAILABLE;
        job->completion.retryable = 1;
    } else if (result == CURLE_OPERATION_TIMEDOUT) {
        job->completion.status = MAIL_TIMEOUT;
    } else if (result == CURLE_COULDNT_CONNECT || result == CURLE_SEND_ERROR || result == CURLE_RECV_ERROR) {
        job->completion.status = MAIL_UNAVAILABLE;
        job->completion.retryable = 1;
    } else {
        job->completion.status = MAIL_IO;
    }
}

int flint_mail_step(flint_mail_transfer *job)
{
    if (!job)
        return MAIL_ARGUMENT;
    if (job->done)
        return MAIL_OK;
    int running = 0;
    if (curl_multi_perform(job->multi, &running) != CURLM_OK)
        return MAIL_IO;
    int pending;
    CURLMsg *message;
    while ((message = curl_multi_info_read(job->multi, &pending)) != NULL)
        if (message->msg == CURLMSG_DONE)
            finished(job, message->data.result);
    if (!job->done && job->bad_reply)
        finished(job, CURLE_WEIRD_SERVER_REPLY);
    if (!job->done && clock_ms() - job->activity >= 10000)
        finished(job, CURLE_OPERATION_TIMEDOUT);
    return job->done ? MAIL_OK : FLINT_MAIL_WAIT;
}

int flint_mail_poll(flint_mail_transfer *job, unsigned milliseconds)
{
    if (!job || milliseconds > 10)
        return MAIL_ARGUMENT;
    int events;
    return curl_multi_poll(job->multi, NULL, 0, (int)milliseconds, &events) == CURLM_OK ? MAIL_OK : MAIL_IO;
}

int flint_mail_result(flint_mail_transfer *job, flint_mail_completion *output)
{
    if (!job || !output)
        return MAIL_ARGUMENT;
    *output = job->completion;
    if (!job->done) {
        if (job->final_reply == 250)
            return MAIL_OK;
        if (job->data_started && job->delivered == job->expected && !job->final_reply)
            output->ambiguous = 1;
        return FLINT_MAIL_WAIT;
    }
    return MAIL_OK;
}

void flint_mail_release(flint_mail_transfer *job)
{
    if (!job)
        return;
    if (job->added)
        curl_multi_remove_handle(job->multi, job->easy);
    if (job->easy)
        curl_easy_cleanup(job->easy);
    if (job->multi)
        curl_multi_cleanup(job->multi);
    curl_slist_free_all(job->recipients);
    free(job);
}

#endif
