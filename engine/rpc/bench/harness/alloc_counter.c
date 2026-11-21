#include <stddef.h>
#include <stdint.h>

void *__real_malloc(size_t size);
void *__real_calloc(size_t count, size_t size);
void *__real_realloc(void *value, size_t size);

static _Thread_local uint64_t calls;
static _Thread_local int active;

void flint_rpc_begin_count(void) {
    calls = 0;
    active = 1;
}

uint64_t flint_rpc_end_count(void) {
    active = 0;
    return calls;
}

void *__wrap_malloc(size_t size) {
    calls += active;
    return __real_malloc(size);
}

void *__wrap_calloc(size_t count, size_t size) {
    calls += active;
    return __real_calloc(count, size);
}

void *__wrap_realloc(void *value, size_t size) {
    calls += active;
    return __real_realloc(value, size);
}
