/* Direct pinned upstream reference for the same TLS SMTP workload. */
#include <curl/curl.h>
#include <stdint.h>
#include <string.h>

typedef struct attachment {
    const uint8_t *data;
    size_t size;
    size_t consumed;
} attachment;

static size_t upload(char *output, size_t size, size_t count, void *opaque)
{
    attachment *input = opaque;
    if (size && count > SIZE_MAX / size)
        return CURL_READFUNC_ABORT;
    size_t bytes = size * count;
    if (bytes > input->size - input->consumed)
        bytes = input->size - input->consumed;
    memcpy(output, input->data + input->consumed, bytes);
    input->consumed += bytes;
    return bytes;
}

static int body_part(curl_mime *parts, const char *body, const char *type)
{
    curl_mimepart *part = curl_mime_addpart(parts);
    return part && curl_mime_data(part, body, CURL_ZERO_TERMINATED) == CURLE_OK
        && curl_mime_type(part, type) == CURLE_OK && curl_mime_encoder(part, "base64") == CURLE_OK;
}

int flint_mail_probe_control(const char *endpoint, const char *ca, const uint8_t *data, size_t length)
{
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK)
        return 1;
    CURL *connection = curl_easy_init();
    curl_mime *parts = connection ? curl_mime_init(connection) : NULL;
    curl_mime *alternative = connection ? curl_mime_init(connection) : NULL;
    struct curl_slist *recipients = curl_slist_append(NULL, "<visible@example.test>");
    struct curl_slist *headers = NULL;
    const char *const lines[] = {"From: <sender@example.test>", "To: <visible@example.test>",
        "Subject: SMTP attachment size fixture", "MIME-Version: 1.0"};
    int worked = 1;
    attachment input = {data, length, 0};
    if (!connection || !parts || !alternative || !recipients)
        goto finish;
    for (size_t i = 0; i < sizeof(lines) / sizeof(*lines); ++i) {
        struct curl_slist *extended = curl_slist_append(headers, lines[i]);
        if (!extended)
            goto finish;
        headers = extended;
    }
    curl_mimepart *body = curl_mime_addpart(parts);
    curl_mimepart *file = curl_mime_addpart(parts);
    if (!body || !file || !body_part(alternative, "benchmark", "text/plain; charset=UTF-8")
        || !body_part(alternative, "<p>benchmark</p>", "text/html; charset=UTF-8")
        || curl_mime_subparts(body, alternative) != CURLE_OK)
        goto finish;
    alternative = NULL;
    if (curl_mime_type(body, "multipart/alternative") != CURLE_OK
        || curl_mime_filename(file, "attachment.bin") != CURLE_OK
        || curl_mime_type(file, "application/octet-stream") != CURLE_OK
        || curl_mime_data_cb(file, (curl_off_t) length, upload, NULL, NULL, &input) != CURLE_OK
        || curl_mime_encoder(file, "base64") != CURLE_OK)
        goto finish;
#define OPTION(key, value) if (curl_easy_setopt(connection, key, value) != CURLE_OK) goto finish
    OPTION(CURLOPT_URL, endpoint);
    OPTION(CURLOPT_PROTOCOLS_STR, "smtp");
    OPTION(CURLOPT_PROXY, "");
    OPTION(CURLOPT_USE_SSL, (long) CURLUSESSL_ALL);
    OPTION(CURLOPT_SSL_VERIFYPEER, 1L);
    OPTION(CURLOPT_SSL_VERIFYHOST, 2L);
    OPTION(CURLOPT_CAINFO, ca);
    OPTION(CURLOPT_USERNAME, "test-user");
    OPTION(CURLOPT_PASSWORD, "fixture-only");
    OPTION(CURLOPT_MAIL_FROM, "<sender@example.test>");
    OPTION(CURLOPT_MAIL_RCPT, recipients);
    OPTION(CURLOPT_HTTPHEADER, headers);
    OPTION(CURLOPT_MIMEPOST, parts);
    OPTION(CURLOPT_UPLOAD_BUFFERSIZE, 16L * 1024L);
    OPTION(CURLOPT_TIMEOUT_MS, 10000L);
    OPTION(CURLOPT_NOSIGNAL, 1L);
#undef OPTION
    long reply = 0;
    if (curl_easy_perform(connection) == CURLE_OK
        && curl_easy_getinfo(connection, CURLINFO_RESPONSE_CODE, &reply) == CURLE_OK
        && (reply == 250 || reply == 221) && input.consumed == length)
        worked = 0;

finish:
    curl_easy_cleanup(connection);
    curl_mime_free(alternative);
    curl_mime_free(parts);
    curl_slist_free_all(headers);
    curl_slist_free_all(recipients);
    curl_global_cleanup();
    return worked;
}
