#define _XOPEN_SOURCE 700
#include "flint_codec.h"

#if FLINT_HAS_LIBARCHIVE
#include <archive.h>
#include <archive_entry.h>
#include <locale.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#endif

enum {
    ZIP = 0, TAR = 1,
    PATH_LIMIT = 4096, ENTRY_LIMIT = 10000, INPUT_CHUNK = 32768,
    ZIP_INPUT_LIMIT = 128 * 1024 * 1024
};

struct flint_archive {
    struct archive *native;
    locale_t utf8;
    locale_t caller_locale;
    flint_archive_read_cb read;
    flint_archive_write_cb write;
    void *user;
    uint64_t max_output;
    uint64_t decoded;
    uint64_t remaining;
    size_t max_path;
    uint32_t max_entries;
    uint32_t entries;
    uint8_t incoming[INPUT_CHUNK];
    uint8_t *zip;
    size_t zip_size;
    int format;
    int ready;
    int body;
    int failed;
    int discard;
    int sink_failed;
};

/* Apply a private UTF-8 locale only during provider calls. The source and sink
 * still see the application's own thread locale. No process-global state is touched. */
static void enter(flint_archive *state) {
    if (state->utf8) state->caller_locale = uselocale(state->utf8);
}

static void leave(flint_archive *state) {
    if (!state->caller_locale) return;
    uselocale(state->caller_locale);
    state->caller_locale = (locale_t)0;
}

static int read_source(flint_archive *state, uint8_t *bytes, size_t size, size_t *written) {
    const locale_t provider_locale = state->caller_locale ? uselocale(state->caller_locale) : (locale_t)0;
    const int result = state->read(state->user, bytes, size, written);
    if (provider_locale) uselocale(provider_locale);
    return result;
}

static int valid_path(const uint8_t *path, size_t length) {
    if (!length || path[0] == '/') return 0;
    size_t component = 0;
    for (size_t i = 0; i < length; ++i) {
        const uint8_t byte = path[i];
        if (byte < 0x20 || byte == 0x7f || byte == '\\' || byte == ':') return 0;
        if (byte != '/') continue;
        if (i == component || (i - component == 2 && path[component] == '.' && path[i - 1] == '.'))
            return 0;
        component = i + 1;
    }
    return length - component != 2 || path[component] != '.' || path[length - 1] != '.';
}

static int utf8_path(const uint8_t *text, size_t length) {
    for (size_t i = 0; i < length;) {
        const uint8_t lead = text[i++];
        if (lead < 0x80) continue;
        if (lead < 0xc2 || lead > 0xf4) return 0;
        const size_t trailing = lead < 0xe0 ? 1u : lead < 0xf0 ? 2u : 3u;
        if (trailing > length - i) return 0;
        const uint8_t first = text[i];
        if ((lead == 0xe0 && first < 0xa0) || (lead == 0xed && first >= 0xa0) ||
            (lead == 0xf0 && first < 0x90) || (lead == 0xf4 && first >= 0x90)) return 0;
        for (size_t k = 0; k < trailing; ++k)
            if ((text[i++] & 0xc0) != 0x80) return 0;
    }
    return 1;
}

static la_ssize_t read_tar(struct archive *provider, void *context, const void **buffer) {
    (void)provider;
    flint_archive *state = context;
    size_t count = 0;
    *buffer = state->incoming;
    if (read_source(state, state->incoming, sizeof(state->incoming), &count) != 0 ||
        count > sizeof(state->incoming)) return -1;
    return (la_ssize_t)count;
}

static la_ssize_t write_bytes(struct archive *provider, void *context, const void *bytes, size_t length) {
    (void)provider;
    flint_archive *state = context;
    if (state->discard) return (la_ssize_t)length;
    const locale_t provider_locale = state->caller_locale ? uselocale(state->caller_locale) : (locale_t)0;
    const int result = state->write(state->user, bytes, length);
    if (provider_locale) uselocale(provider_locale);
    if (result != 0) {
        /* Entering libarchive's fatal state would prevent ZIP from finalizing
         * its active compressor. Retain the sink error and discard all output. */
        state->sink_failed = state->discard = 1;
    }
    return (la_ssize_t)length;
}

static uint16_t le16(const uint8_t *bytes) {
    return (uint16_t)((uint16_t)bytes[0] | (uint16_t)bytes[1] << 8);
}

static uint32_t le32(const uint8_t *bytes) {
    return (uint32_t)le16(bytes) | (uint32_t)le16(bytes + 2) << 16;
}

static int checked_zip_path(const flint_archive *state, const uint8_t *bytes, size_t count) {
    if (count > state->max_path) return FLINT_CODEC_LIMIT;
    return valid_path(bytes, count) ? FLINT_CODEC_OK : FLINT_CODEC_INVALID;
}

static int zip_local_path(const flint_archive *state, size_t offset, size_t boundary) {
    if (offset > boundary || boundary - offset < 30) return FLINT_CODEC_INVALID;
    const uint8_t *local = state->zip + offset;
    if (le32(local) != UINT32_C(0x04034b50)) return FLINT_CODEC_INVALID;
    const size_t name = le16(local + 26);
    const size_t extras = le16(local + 28);
    if (name + extras > boundary - offset - 30) return FLINT_CODEC_INVALID;
    return checked_zip_path(state, local + 30, name);
}

/*
 * Validate the length-delimited filenames and declared types before libarchive
 * converts or normalizes them. The seekable libarchive reader owns parsing,
 * decompression, CRC checking and all exposed entry metadata.
 */
static int zip_directory(const flint_archive *state, size_t offset, size_t boundary, size_t entries) {
    size_t at = offset;
    for (size_t index = 0; index < entries; ++index) {
        if (boundary - at < 46) return FLINT_CODEC_INVALID;
        const uint8_t *entry = state->zip + at;
        if (le32(entry) != UINT32_C(0x02014b50) || le16(entry + 34) != 0) return FLINT_CODEC_INVALID;
        const size_t name = le16(entry + 28);
        const size_t size = 46 + name + le16(entry + 30) + le16(entry + 32);
        if (size > boundary - at) return FLINT_CODEC_INVALID;

        const unsigned origin = entry[5];
        const unsigned type = le16(entry + 40) & AE_IFMT;
        if ((origin == 3 || origin == 19) && type != 0 && type != AE_IFDIR && type != AE_IFREG)
            return FLINT_CODEC_INVALID;
        const int status = checked_zip_path(state, entry + 46, name);
        if (status != FLINT_CODEC_OK) return status;
        const int local = zip_local_path(state, le32(entry + 42), offset);
        if (local != FLINT_CODEC_OK) return local;
        at += size;
    }
    return at == boundary ? FLINT_CODEC_OK : FLINT_CODEC_INVALID;
}

static int zip_envelope(const flint_archive *state) {
    if (state->zip_size < 22) return FLINT_CODEC_INVALID;
    const size_t end = state->zip_size - 22;
    const size_t last = end > UINT16_MAX ? end - UINT16_MAX : 0;
    for (size_t index = end;; --index) {
        const uint8_t *trailer = state->zip + index;
        if (le32(trailer) == UINT32_C(0x06054b50) && le16(trailer + 20) == end - index) {
            const size_t entries = le16(trailer + 10);
            const size_t length = le32(trailer + 12);
            const size_t offset = le32(trailer + 16);
            if (entries > state->max_entries) return FLINT_CODEC_LIMIT;
            if (le32(trailer + 4) != 0 || le16(trailer + 8) != entries ||
                offset > index || length != index - offset) return FLINT_CODEC_INVALID;
            return zip_directory(state, offset, index, entries);
        }
        if (index == last) return FLINT_CODEC_INVALID;
    }
}

static int buffer_zip(flint_archive *state) {
    size_t capacity = 0;
    for (;;) {
        size_t written = 0;
        if (read_source(state, state->incoming, sizeof(state->incoming), &written) != 0 ||
            written > sizeof(state->incoming)) return FLINT_CODEC_INVALID;
        if (!written) return zip_envelope(state);
        if (written > ZIP_INPUT_LIMIT - state->zip_size) return FLINT_CODEC_LIMIT;
        const size_t needed = state->zip_size + written;
        if (needed > capacity) {
            capacity = capacity ? 2 * capacity : INPUT_CHUNK;
            uint8_t *grown = realloc(state->zip, capacity);
            if (!grown) return FLINT_CODEC_NOMEM;
            state->zip = grown;
        }
        memcpy(state->zip + state->zip_size, state->incoming, written);
        state->zip_size = needed;
    }
}

static int prepare_reader(flint_archive *state) {
    if (state->ready) return FLINT_CODEC_OK;
    int status;
    if (state->format == ZIP) {
        status = buffer_zip(state);
        if (status != FLINT_CODEC_OK) return status;
        status = archive_read_open_memory(state->native, state->zip, state->zip_size);
    } else {
        status = archive_read_open(state->native, state, NULL, read_tar, NULL);
    }
    if (status != ARCHIVE_OK) return FLINT_CODEC_INVALID;
    state->ready = 1;
    return FLINT_CODEC_OK;
}

int flint_archive_available(void) {
    return 1;
}

static flint_archive *allocate(int format, void *user) {
    if (format != ZIP && format != TAR) return NULL;
    flint_archive *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    state->user = user;
    state->utf8 = newlocale(LC_CTYPE_MASK, "C.UTF-8", (locale_t)0);
    state->format = format;
    state->max_path = PATH_LIMIT;
    state->max_entries = ENTRY_LIMIT;
    return state;
}

flint_archive *flint_archive_reader_new(int format, flint_archive_read_cb read,
                                        void *user, uint64_t max_output_bytes) {
    if (!read || !max_output_bytes) return NULL;
    flint_archive *state = allocate(format, user);
    if (!state) return NULL;
    state->read = read;
    state->max_output = max_output_bytes;
    state->native = archive_read_new();
    if (state->native) {
        const int result = format == ZIP
            ? archive_read_support_format_zip_seekable(state->native)
            : archive_read_support_format_tar(state->native);
        if (result == ARCHIVE_OK) return state;
    }
    flint_archive_abort(state);
    return NULL;
}

#if defined(__APPLE__)
/* libarchive converts UTF-8 header names to NFC on Linux but to NFD on Darwin (archive_string.c).
   Recompose here so a reader sees the same bytes on both (ADR-024). Returns 0 on success. */
static int compose_path(const char *name, char *composed, size_t capacity)
{
    CFMutableStringRef text = CFStringCreateMutable(kCFAllocatorDefault, 0);
    if (!text)
        return -1;
    CFStringAppendCString(text, name, kCFStringEncodingUTF8);
    const int empty = name[0] != 0 && CFStringGetLength(text) == 0;
    CFStringNormalize(text, kCFStringNormalizationFormC);
    const Boolean converted = !empty && CFStringGetCString(text, composed, (CFIndex) capacity, kCFStringEncodingUTF8);
    CFRelease(text);
    return converted ? 0 : -1;
}
#endif

int flint_archive_reader_limits(flint_archive *state, size_t max_path_bytes, uint32_t max_entries) {
    if (!state || !state->read || state->ready || !max_path_bytes || max_path_bytes > PATH_LIMIT ||
        !max_entries || max_entries > ENTRY_LIMIT) return FLINT_CODEC_INVALID;
    state->max_path = max_path_bytes;
    state->max_entries = max_entries;
    return FLINT_CODEC_OK;
}

flint_archive *flint_archive_writer_new(int format, flint_archive_write_cb write, void *user) {
    if (!write) return NULL;
    flint_archive *state = allocate(format, user);
    if (!state) return NULL;
    state->write = write;
    state->max_output = 1024ULL * 1024 * 1024;
    state->native = archive_write_new();
    if (state->native) {
        const int setup = format == ZIP ? archive_write_set_format_zip(state->native)
            : archive_write_set_format_pax_restricted(state->native);
        if (setup == ARCHIVE_OK && archive_write_set_bytes_in_last_block(state->native, 1) == ARCHIVE_OK) {
            enter(state);
            const int opened = archive_write_open(state->native, state, NULL, write_bytes, NULL);
            leave(state);
            if (opened == ARCHIVE_OK) {
                state->ready = 1;
                if (!state->sink_failed) return state;
            }
        }
    }
    flint_archive_abort(state);
    return NULL;
}

static int next_entry(flint_archive *state, uint8_t *path, size_t capacity, size_t *length,
                       uint64_t *size, int *directory) {
    if (!state || !state->read || state->failed || state->body || !path || !length || !size || !directory)
        return FLINT_CODEC_INVALID;
    const int prepared = prepare_reader(state);
    if (prepared != FLINT_CODEC_OK) return prepared;

    struct archive_entry *entry;
    const int result = archive_read_next_header(state->native, &entry);
    if (result == ARCHIVE_EOF) return FLINT_CODEC_FINISHED;
    if (result != ARCHIVE_OK) return FLINT_CODEC_INVALID;
    if (state->entries == state->max_entries) return FLINT_CODEC_LIMIT;

    const unsigned type = archive_entry_filetype(entry);
    if ((type != AE_IFREG && type != AE_IFDIR) || archive_entry_hardlink_is_set(entry) ||
        archive_entry_symlink(entry) || archive_entry_is_encrypted(entry)) return FLINT_CODEC_INVALID;
    const char *name = archive_entry_pathname_utf8(entry);
    if (!name) name = archive_entry_pathname(entry);
    if (!name) return FLINT_CODEC_INVALID;
#if defined(__APPLE__)
    char composed[PATH_LIMIT + 2];
    if (compose_path(name, composed, sizeof(composed)))
        return strlen(name) > PATH_LIMIT ? FLINT_CODEC_LIMIT : FLINT_CODEC_INVALID;
    name = composed;
#endif
    size_t count = 0;
    while (count <= state->max_path && name[count]) ++count;
    if (count > state->max_path || count > capacity) return FLINT_CODEC_LIMIT;
    if (!valid_path((const uint8_t *)name, count) || !utf8_path((const uint8_t *)name, count))
        return FLINT_CODEC_INVALID;

    const la_int64_t declared = archive_entry_size(entry);
    if (!archive_entry_size_is_set(entry) || declared < 0 || (type == AE_IFDIR && declared != 0))
        return FLINT_CODEC_INVALID;
    if ((uint64_t)declared > state->max_output - state->decoded) return FLINT_CODEC_LIMIT;

    memcpy(path, name, count);
    *length = count;
    *size = (uint64_t)declared;
    *directory = type == AE_IFDIR;
    state->remaining = (uint64_t)declared;
    state->entries++;
    state->body = 1;
    return FLINT_CODEC_OK;
}

int flint_archive_next(flint_archive *state, uint8_t *path, size_t capacity, size_t *length,
                       uint64_t *size, int *directory) {
    if (!state) return FLINT_CODEC_INVALID;
    enter(state);
    const int result = next_entry(state, path, capacity, length, size, directory);
    leave(state);
    if (result < 0 && !state->body) state->failed = 1;
    return result;
}

int flint_archive_read(flint_archive *state, uint8_t *output, size_t capacity, size_t *written) {
    if (!state || !state->read || state->failed || !state->body || !written || !output || !capacity)
        return FLINT_CODEC_INVALID;
    *written = 0;
    if (!state->remaining) {
        uint8_t probe;
        enter(state);
        const la_ssize_t trailing = archive_read_data(state->native, &probe, 1);
        leave(state);
        if (trailing != 0) return trailing > 0 && state->decoded == state->max_output
            ? FLINT_CODEC_LIMIT : FLINT_CODEC_INVALID;
        state->body = 0;
        return FLINT_CODEC_FINISHED;
    }
    if (capacity > state->remaining) capacity = (size_t)state->remaining;
    enter(state);
    const la_ssize_t got = archive_read_data(state->native, output, capacity);
    leave(state);
    if (got <= 0 || (size_t)got > capacity) return FLINT_CODEC_INVALID;
    state->remaining -= (uint64_t)got;
    state->decoded += (uint64_t)got;
    *written = (size_t)got;
    return FLINT_CODEC_OK;
}

int flint_archive_entry(flint_archive *state, const char *path, uint64_t size, int directory) {
    if (!state || !state->write || state->failed || state->remaining || !path ||
        (directory && size != 0)) return FLINT_CODEC_INVALID;
    size_t length = 0;
    while (length <= PATH_LIMIT && path[length]) ++length;
    if (length > PATH_LIMIT || state->entries == ENTRY_LIMIT ||
        size > state->max_output - state->decoded) return FLINT_CODEC_LIMIT;
    if (!valid_path((const uint8_t *)path, length) || !utf8_path((const uint8_t *)path, length) ||
        (!directory && path[length - 1] == '/'))
        return FLINT_CODEC_INVALID;

    struct archive_entry *entry = archive_entry_new();
    if (!entry) return FLINT_CODEC_NOMEM;
    archive_entry_set_pathname_utf8(entry, path);
    archive_entry_set_filetype(entry, directory ? AE_IFDIR : AE_IFREG);
    archive_entry_set_perm(entry, directory ? 0755 : 0644);
    archive_entry_set_mtime(entry, 0, 0);
    archive_entry_set_size(entry, (la_int64_t)size);
    enter(state);
    const int result = archive_write_header(state->native, entry);
    leave(state);
    archive_entry_free(entry);
    if (result != ARCHIVE_OK || state->sink_failed) {
        state->failed = 1;
        return FLINT_CODEC_INVALID;
    }
    state->remaining = size;
    state->entries++;
    return FLINT_CODEC_OK;
}

int flint_archive_write(flint_archive *state, const uint8_t *input, size_t length) {
    if (!state || !state->write || state->failed || !state->entries ||
        length > state->remaining || (length && !input)) return FLINT_CODEC_INVALID;
    size_t sent = 0;
    while (sent < length) {
        enter(state);
        const la_ssize_t wrote = archive_write_data(state->native, input + sent, length - sent);
        leave(state);
        if (wrote <= 0 || (size_t)wrote > length - sent || state->sink_failed) {
            state->failed = 1;
            return FLINT_CODEC_INVALID;
        }
        sent += (size_t)wrote;
    }
    state->remaining -= length;
    state->decoded += length;
    return FLINT_CODEC_OK;
}

void flint_archive_abort(flint_archive *state) {
    if (!state) return;
    if (state->native) {
        if (state->write) {
            state->discard = 1;
            if (state->ready && state->format == ZIP) {
                /* Finish only the compressor. A TAR finish may pad a short
                 * entry up to its declared size. Never call the sink here. */
                archive_write_finish_entry(state->native);
            }
            archive_write_fail(state->native);
            archive_write_free(state->native);
        } else {
            archive_read_free(state->native);
        }
    }
    if (state->utf8) freelocale(state->utf8);
    free(state->zip);
    free(state);
}

int flint_archive_close(flint_archive *state) {
    if (!state) return FLINT_CODEC_OK;
    int result = FLINT_CODEC_OK;
    if (state->write && (state->remaining || state->failed)) {
        flint_archive_abort(state);
        return FLINT_CODEC_INVALID;
    }
    if (state->write) {
        enter(state);
        const int close_result = archive_write_close(state->native);
        leave(state);
        const int free_result = archive_write_free(state->native);
        if (close_result != ARCHIVE_OK || free_result != ARCHIVE_OK || state->sink_failed)
            result = FLINT_CODEC_INVALID;
    } else if (archive_read_free(state->native) != ARCHIVE_OK) {
        result = FLINT_CODEC_INVALID;
    }
    if (state->utf8) freelocale(state->utf8);
    free(state->zip);
    free(state);
    return result;
}

#else
int flint_archive_available(void) { return 0; }
#endif
