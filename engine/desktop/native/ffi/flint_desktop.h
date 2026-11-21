/* Versioned Flint shim contract; implementations must wrap pinned upstream libraries. */
#ifndef FLINT_DESKTOP_ABI_H
#define FLINT_DESKTOP_ABI_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
enum flint_desktop_status {
    FLINT_DESKTOP_OK = 0, FLINT_DESKTOP_INVALID = 1, FLINT_DESKTOP_MEMORY = 2,
    FLINT_DESKTOP_CANCELLED = 3, FLINT_DESKTOP_EMPTY = 5, FLINT_DESKTOP_CONFLICT = 6,
    FLINT_DESKTOP_IO = 7, FLINT_DESKTOP_UNAVAILABLE = 8, FLINT_DESKTOP_UNSUPPORTED = 9,
    FLINT_DESKTOP_DENIED = 10, FLINT_DESKTOP_LIMIT = 11
};

enum {
    FLINT_DESKTOP_WINDOWS = 16, FLINT_DESKTOP_EVENTS = 256,
    FLINT_DESKTOP_CHUNK = 16384, FLINT_DESKTOP_CLIPS = 32
};

enum flint_desktop_packet { FLINT_DESKTOP_DRAW = 1, FLINT_DESKTOP_MESSAGE = 2 };
int flint_desktop_main_thread(void);
int flint_desktop_queue_open(uint32_t slot, uint64_t generation, int accepts_draw);
int flint_desktop_queue_post(uint32_t slot, uint64_t generation, uint32_t kind,
                            const uint8_t *bytes, size_t length);
int flint_desktop_queue_pop(uint32_t slot, uint64_t generation, uint32_t *kind,
                           uint8_t *bytes, size_t capacity, size_t *length);
void flint_desktop_queue_close(uint32_t slot, uint64_t generation);

typedef struct flint_window flint_window;
typedef struct flint_window_event {
    uint32_t kind; int32_t x; int32_t y; uint32_t key_code;
} flint_window_event;
flint_window *flint_window_new(const char *title, uint32_t width,
                               uint32_t height, uint32_t flags);
int flint_window_poll(flint_window *window, flint_window_event *event);
int flint_window_submit(flint_window *window, const uint8_t *commands,
                        size_t command_bytes);
void flint_window_free(flint_window *window);

typedef struct flint_webkit_window flint_webkit_window;
flint_webkit_window *flint_webkit_window_new(const char *title, uint32_t width,
    uint32_t height, uint32_t flags, uint32_t slot, uint64_t generation,
    const char *asset, const uint8_t *html, size_t html_length, const char *https_origin);
int flint_webkit_window_poll(flint_webkit_window *window, flint_window_event *event);
void flint_webkit_window_free(flint_webkit_window *window);
#ifdef __cplusplus
}
#endif
#endif
