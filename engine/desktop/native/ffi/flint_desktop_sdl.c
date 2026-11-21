#include "flint_desktop.h"

#if FLINT_HAS_SDL3 && defined(__linux__)
#include <SDL3/SDL.h>
#include <stdlib.h>
#include <string.h>

enum {
    CLOSE = 0, RESIZE = 1, KEY = 2, POINTER = 3,
    CLEAR = 1, RECTANGLE, GLYPHS, IMAGE, CLIP, UNCLIP,
    COORDINATE_LIMIT = 16384
};

struct flint_window {
    SDL_Window *window;
    SDL_Renderer *renderer;
    SDL_Texture *tile;
    SDL_WindowID id;
    flint_window_event pending[FLINT_DESKTOP_EVENTS];
    size_t first;
    size_t count;
    int closing;
    int overflow;
};

static flint_window *windows[FLINT_DESKTOP_WINDOWS];

static size_t vacant(void) {
    for (size_t i = 0; i < FLINT_DESKTOP_WINDOWS; ++i)
        if (!windows[i]) return i;
    return FLINT_DESKTOP_WINDOWS;
}

flint_window *flint_window_new(const char *title, uint32_t width, uint32_t height, uint32_t flags) {
    if (!flint_desktop_main_thread() || !title || !width || !height ||
        width > COORDINATE_LIMIT || height > COORDINATE_LIMIT || (flags & ~1u)) return NULL;
    const size_t slot = vacant();
    if (slot == FLINT_DESKTOP_WINDOWS || !SDL_InitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) return NULL;
    flint_window *view = calloc(1, sizeof(*view));
    if (!view) {
        SDL_QuitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS);
        return NULL;
    }
    const SDL_WindowFlags windows_flags = flags ? SDL_WINDOW_RESIZABLE : 0;
    if (!SDL_CreateWindowAndRenderer(title, (int)width, (int)height, windows_flags,
                                    &view->window, &view->renderer)) {
        flint_window_free(view);
        return NULL;
    }
    view->id = SDL_GetWindowID(view->window);
    view->tile = SDL_CreateTexture(view->renderer, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, 1, 1);
    const uint8_t white[4] = {255, 255, 255, 255};
    if (!view->id || !view->tile || !SDL_UpdateTexture(view->tile, NULL, white, sizeof(white)) ||
        !SDL_SetTextureBlendMode(view->tile, SDL_BLENDMODE_BLEND) ||
        !SDL_SetRenderDrawBlendMode(view->renderer, SDL_BLENDMODE_BLEND)) {
        flint_window_free(view);
        return NULL;
    }
    windows[slot] = view;
    return view;
}

static flint_window *by_id(SDL_WindowID id) {
    for (size_t i = 0; i < FLINT_DESKTOP_WINDOWS; ++i)
        if (windows[i] && windows[i]->id == id) return windows[i];
    return NULL;
}

static void enqueue(flint_window *view, flint_window_event event) {
    if (!view) return;
    if (event.kind == CLOSE) {
        view->closing = 1;
        return;
    }
    if (view->count && event.kind == POINTER && !event.key_code) {
        flint_window_event *latest = &view->pending[
            (view->first + view->count - 1) % FLINT_DESKTOP_EVENTS];
        if (latest->kind == POINTER && !latest->key_code) {
            *latest = event;
            return;
        }
    }
    if (view->count == FLINT_DESKTOP_EVENTS) {
        if (event.kind != POINTER || event.key_code) view->overflow = 1;
        return;
    }
    view->pending[(view->first + view->count) % FLINT_DESKTOP_EVENTS] = event;
    ++view->count;
}

static int32_t coordinate(float value) {
    if (!(value >= -COORDINATE_LIMIT)) return -COORDINATE_LIMIT;
    if (value > COORDINATE_LIMIT) return COORDINATE_LIMIT;
    return (int32_t)value;
}

static void route(const SDL_Event *event) {
    switch (event->type) {
    case SDL_EVENT_QUIT:
        for (size_t i = 0; i < FLINT_DESKTOP_WINDOWS; ++i)
            enqueue(windows[i], (flint_window_event){CLOSE, 0, 0, 0});
        break;
    case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
        enqueue(by_id(event->window.windowID), (flint_window_event){CLOSE, 0, 0, 0});
        break;
    case SDL_EVENT_WINDOW_RESIZED:
        enqueue(by_id(event->window.windowID),
                (flint_window_event){RESIZE, event->window.data1, event->window.data2, 0});
        break;
    case SDL_EVENT_KEY_DOWN:
        enqueue(by_id(event->key.windowID), (flint_window_event){KEY, 0, 0, event->key.key});
        break;
    case SDL_EVENT_MOUSE_MOTION:
        enqueue(by_id(event->motion.windowID),
                (flint_window_event){POINTER, coordinate(event->motion.x), coordinate(event->motion.y), 0});
        break;
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP:
        enqueue(by_id(event->button.windowID),
                (flint_window_event){POINTER, coordinate(event->button.x), coordinate(event->button.y),
                                     event->button.button});
        break;
    default:
        break;
    }
}

int flint_window_poll(flint_window *view, flint_window_event *event) {
    if (!flint_desktop_main_thread()) return -FLINT_DESKTOP_DENIED;
    if (!view || !event) return -FLINT_DESKTOP_INVALID;
    SDL_Event next;
    for (size_t i = 0; i < FLINT_DESKTOP_EVENTS && SDL_PollEvent(&next); ++i)
        route(&next);
    if (view->closing) {
        view->closing = 0;
        *event = (flint_window_event){CLOSE, 0, 0, 0};
        return 1;
    }
    if (view->overflow) {
        view->overflow = 0;
        return -FLINT_DESKTOP_LIMIT;
    }
    if (!view->count) return 0;
    *event = view->pending[view->first];
    view->first = (view->first + 1) % FLINT_DESKTOP_EVENTS;
    --view->count;
    return 1;
}

static uint32_t u16(const uint8_t *data) {
    return (uint32_t)data[0] | (uint32_t)data[1] << 8;
}

static int32_t s32(const uint8_t *data) {
    return (int32_t)(u16(data) | u16(data + 2) << 16);
}

static int allowed_position(const uint8_t *data) {
    const int32_t x = s32(data), y = s32(data + 4);
    return x >= -COORDINATE_LIMIT && x <= COORDINATE_LIMIT &&
           y >= -COORDINATE_LIMIT && y <= COORDINATE_LIMIT;
}

static int allowed_area(const uint8_t *data) {
    const int32_t width = s32(data + 8), height = s32(data + 12);
    return allowed_position(data) && width >= 0 && width <= COORDINATE_LIMIT &&
           height >= 0 && height <= COORDINATE_LIMIT;
}

static int allowed_glyphs(const uint8_t *data, size_t length) {
    if (length < 16 || length > 1040 || u16(data + 8) != 1 ||
        u16(data + 10) != length - 16 || length == 16 || !allowed_position(data)) return 0;
    for (size_t i = 16; i < length; ++i)
        if (data[i] < 0x20 || data[i] > 0x7e) return 0;
    return 1;
}

static int check_record(unsigned operation, const uint8_t *data, size_t length, size_t *depth) {
    switch (operation) {
    case CLEAR: return length == 4;
    case RECTANGLE: return length == 20 && allowed_area(data);
    case GLYPHS: return allowed_glyphs(data, length);
    case IMAGE: return length == 24 && allowed_area(data) && u16(data + 16) == 1 && u16(data + 18) == 0;
    case CLIP:
        if (length != 16 || *depth == FLINT_DESKTOP_CLIPS || !allowed_area(data)) return 0;
        ++*depth;
        return 1;
    case UNCLIP:
        if (length || !*depth) return 0;
        --*depth;
        return 1;
    default: return 0;
    }
}

static int valid_draw(const uint8_t *bytes, size_t length) {
    if (!bytes || length < 8 || length > FLINT_DESKTOP_CHUNK || memcmp(bytes, "FDL\x01", 4) ||
        u16(bytes + 6)) return 0;
    const uint32_t records = u16(bytes + 4);
    if (records > 1024) return 0;
    size_t offset = 8, depth = 0;
    for (uint32_t i = 0; i < records; ++i) {
        if (length - offset < 4 || bytes[offset + 1]) return 0;
        const size_t size = u16(bytes + offset + 2);
        if (size > length - offset - 4 ||
            !check_record(bytes[offset], bytes + offset + 4, size, &depth)) return 0;
        offset += 4 + size;
    }
    return offset == length && depth == 0;
}

static bool color(SDL_Renderer *renderer, const uint8_t *rgba) {
    return SDL_SetRenderDrawColor(renderer, rgba[0], rgba[1], rgba[2], rgba[3]);
}

static SDL_FRect area(const uint8_t *bytes) {
    return (SDL_FRect){(float)s32(bytes), (float)s32(bytes + 4),
                       (float)s32(bytes + 8), (float)s32(bytes + 12)};
}

static bool draw_image(flint_window *view, const uint8_t *bytes) {
    const SDL_FRect region = area(bytes);
    return SDL_SetTextureColorMod(view->tile, bytes[20], bytes[21], bytes[22]) &&
           SDL_SetTextureAlphaMod(view->tile, bytes[23]) &&
           SDL_RenderTexture(view->renderer, view->tile, NULL, &region);
}

static bool draw_glyphs(SDL_Renderer *renderer, const uint8_t *bytes) {
    char text[1025];
    const size_t count = u16(bytes + 10);
    memcpy(text, bytes + 16, count);
    text[count] = '\0';
    return color(renderer, bytes + 12) &&
           SDL_RenderDebugText(renderer, (float)s32(bytes), (float)s32(bytes + 4), text);
}

static bool draw_primitive(flint_window *view, unsigned operation, const uint8_t *bytes) {
    SDL_Renderer *renderer = view->renderer;
    switch (operation) {
    case CLEAR: return color(renderer, bytes) && SDL_RenderClear(renderer);
    case RECTANGLE: {
        const SDL_FRect region = area(bytes);
        return color(renderer, bytes + 16) && SDL_RenderFillRect(renderer, &region);
    }
    case GLYPHS: return draw_glyphs(renderer, bytes);
    case IMAGE: return draw_image(view, bytes);
    default: return false;
    }
}

static bool draw_clip(SDL_Renderer *renderer, unsigned operation, const uint8_t *bytes,
                      SDL_Rect *stack, size_t *depth) {
    if (operation == CLIP) {
        SDL_Rect clip = {s32(bytes), s32(bytes + 4), s32(bytes + 8), s32(bytes + 12)};
        SDL_Rect intersection = {0, 0, 0, 0};
        if (*depth && !SDL_GetRectIntersection(&stack[*depth - 1], &clip, &intersection))
            clip = (SDL_Rect){0, 0, 0, 0};
        else if (*depth)
            clip = intersection;
        stack[(*depth)++] = clip;
    } else {
        --*depth;
    }
    return SDL_SetRenderClipRect(renderer, *depth ? &stack[*depth - 1] : NULL);
}

int flint_window_submit(flint_window *view, const uint8_t *commands, size_t size) {
    if (!flint_desktop_main_thread()) return FLINT_DESKTOP_DENIED;
    if (!view || !valid_draw(commands, size)) return FLINT_DESKTOP_INVALID;
    SDL_Rect clip[FLINT_DESKTOP_CLIPS];
    size_t depth = 0;
    if (!SDL_SetRenderClipRect(view->renderer, NULL)) return FLINT_DESKTOP_IO;
    for (size_t offset = 8; offset < size;) {
        const unsigned operation = commands[offset];
        const size_t length = u16(commands + offset + 2);
        const uint8_t *data = commands + offset + 4;
        const bool rendered = operation == CLIP || operation == UNCLIP
            ? draw_clip(view->renderer, operation, data, clip, &depth)
            : draw_primitive(view, operation, data);
        if (!rendered) return FLINT_DESKTOP_IO;
        offset += 4 + length;
    }
    return SDL_RenderPresent(view->renderer) ? FLINT_DESKTOP_OK : FLINT_DESKTOP_IO;
}

void flint_window_free(flint_window *view) {
    if (!view || !flint_desktop_main_thread()) return;
    for (size_t i = 0; i < FLINT_DESKTOP_WINDOWS; ++i)
        if (windows[i] == view) windows[i] = NULL;
    if (view->tile) SDL_DestroyTexture(view->tile);
    if (view->renderer) SDL_DestroyRenderer(view->renderer);
    if (view->window) SDL_DestroyWindow(view->window);
    free(view);
    SDL_QuitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS);
}
#endif
