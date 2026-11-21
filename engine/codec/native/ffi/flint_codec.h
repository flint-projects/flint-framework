/* Versioned Flint shim contract; implementations must wrap pinned upstream libraries. */
#ifndef FLINT_CODEC_ABI_H
#define FLINT_CODEC_ABI_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct flint_codec_state flint_codec_state;
enum flint_codec_status {
    FLINT_CODEC_OK = 0, FLINT_CODEC_FINISHED = 1, FLINT_CODEC_NEED_INPUT = 2,
    FLINT_CODEC_INVALID = -1, FLINT_CODEC_NOMEM = -2, FLINT_CODEC_DICTIONARY = -3,
    FLINT_CODEC_LIMIT = -4, FLINT_CODEC_UNSUPPORTED = -5
};
int flint_codec_available(int codec);
int flint_codec_level_valid(int codec, int level);
typedef struct flint_codec_allocations {
    size_t calls;
    size_t live_bytes;
    size_t peak_bytes;
} flint_codec_allocations;
flint_codec_allocations flint_codec_get_allocations(const flint_codec_state *state);
flint_codec_state *flint_codec_new(int codec, int encode, int level);
int flint_codec_step(flint_codec_state *state, const uint8_t *input,
                     size_t input_length, size_t *consumed,
                     uint8_t *output, size_t output_capacity,
                     size_t *produced, int finish);
void flint_codec_free(flint_codec_state *state);
typedef struct flint_archive flint_archive;
int flint_archive_available(void);
int flint_archive_reader_limits(flint_archive *archive, size_t max_path_bytes, uint32_t max_entries);
void flint_archive_abort(flint_archive *archive);
typedef int (*flint_archive_read_cb)(void *user, uint8_t *output,
                                     size_t capacity, size_t *written);
typedef int (*flint_archive_write_cb)(void *user, const uint8_t *input,
                                      size_t length);
flint_archive *flint_archive_reader_new(int format, flint_archive_read_cb read,
                                        void *user, uint64_t max_output_bytes);
flint_archive *flint_archive_writer_new(int format, flint_archive_write_cb write,
                                        void *user);
int flint_archive_next(flint_archive *archive, uint8_t *path,
                        size_t path_capacity, size_t *path_length,
                        uint64_t *size, int *directory);
int flint_archive_read(flint_archive *archive, uint8_t *output,
                        size_t capacity, size_t *written);
int flint_archive_entry(flint_archive *archive, const char *path,
                         uint64_t size, int directory);
int flint_archive_write(flint_archive *archive, const uint8_t *input, size_t length);
int flint_archive_close(flint_archive *archive);
#ifdef __cplusplus
}
#endif
#endif
