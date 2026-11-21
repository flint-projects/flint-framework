#define _GNU_SOURCE
#include "flint_desktop.h"

#if defined(__linux__)
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

typedef struct packet {
    uint32_t kind;
    uint32_t length;
    uint8_t bytes[FLINT_DESKTOP_CHUNK];
} packet;

typedef struct desktop_queue {
    uint64_t generation;
    uint32_t first;
    uint32_t count;
    int accepts_draw;
    packet entries[FLINT_DESKTOP_EVENTS];
} desktop_queue;

static pthread_mutex_t registry_lock = PTHREAD_MUTEX_INITIALIZER;
static desktop_queue *registry[FLINT_DESKTOP_WINDOWS];

int flint_desktop_main_thread(void) {
    return syscall(SYS_gettid) == getpid();
}

static desktop_queue *find(uint32_t slot, uint64_t generation) {
    if (slot >= FLINT_DESKTOP_WINDOWS || generation == 0) return NULL;
    desktop_queue *queue = registry[slot];
    return queue && queue->generation == generation ? queue : NULL;
}

int flint_desktop_queue_open(uint32_t slot, uint64_t generation, int accepts_draw) {
    if (!flint_desktop_main_thread()) return FLINT_DESKTOP_DENIED;
    if (slot >= FLINT_DESKTOP_WINDOWS || !generation) return FLINT_DESKTOP_INVALID;
    desktop_queue *queue = calloc(1, sizeof(*queue));
    if (!queue) return FLINT_DESKTOP_MEMORY;
    queue->generation = generation;
    queue->accepts_draw = !!accepts_draw;
    pthread_mutex_lock(&registry_lock);
    if (registry[slot]) {
        pthread_mutex_unlock(&registry_lock);
        free(queue);
        return FLINT_DESKTOP_CONFLICT;
    }
    registry[slot] = queue;
    pthread_mutex_unlock(&registry_lock);
    return FLINT_DESKTOP_OK;
}

int flint_desktop_queue_post(uint32_t slot, uint64_t generation, uint32_t kind,
                            const uint8_t *bytes, size_t length) {
    if (length > FLINT_DESKTOP_CHUNK) return FLINT_DESKTOP_LIMIT;
    if ((kind != FLINT_DESKTOP_DRAW && kind != FLINT_DESKTOP_MESSAGE) || (length && !bytes))
        return FLINT_DESKTOP_INVALID;
    pthread_mutex_lock(&registry_lock);
    desktop_queue *queue = find(slot, generation);
    int result = FLINT_DESKTOP_INVALID;
    if (queue && kind == FLINT_DESKTOP_DRAW && !queue->accepts_draw)
        result = FLINT_DESKTOP_UNSUPPORTED;
    else if (queue) {
        result = FLINT_DESKTOP_LIMIT;
        if (queue->count < FLINT_DESKTOP_EVENTS) {
            packet *item = &queue->entries[(queue->first + queue->count) % FLINT_DESKTOP_EVENTS];
            item->kind = kind;
            item->length = (uint32_t)length;
            if (length) memcpy(item->bytes, bytes, length);
            ++queue->count;
            result = FLINT_DESKTOP_OK;
        }
    }
    pthread_mutex_unlock(&registry_lock);
    return result;
}

int flint_desktop_queue_pop(uint32_t slot, uint64_t generation, uint32_t *kind,
                           uint8_t *bytes, size_t capacity, size_t *length) {
    if (!flint_desktop_main_thread()) return FLINT_DESKTOP_DENIED;
    if (!kind || !length || (capacity && !bytes)) return FLINT_DESKTOP_INVALID;
    pthread_mutex_lock(&registry_lock);
    desktop_queue *queue = find(slot, generation);
    int result = FLINT_DESKTOP_INVALID;
    if (queue) {
        result = FLINT_DESKTOP_EMPTY;
        if (queue->count) {
            const packet *item = &queue->entries[queue->first];
            result = FLINT_DESKTOP_LIMIT;
            if (item->length <= capacity) {
                if (item->length) memcpy(bytes, item->bytes, item->length);
                *kind = item->kind;
                *length = item->length;
                queue->first = (queue->first + 1) % FLINT_DESKTOP_EVENTS;
                --queue->count;
                result = FLINT_DESKTOP_OK;
            }
        }
    }
    pthread_mutex_unlock(&registry_lock);
    return result;
}

void flint_desktop_queue_close(uint32_t slot, uint64_t generation) {
    if (!flint_desktop_main_thread()) return;
    pthread_mutex_lock(&registry_lock);
    desktop_queue *queue = find(slot, generation);
    if (queue) registry[slot] = NULL;
    pthread_mutex_unlock(&registry_lock);
    free(queue);
}
#endif
