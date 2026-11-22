#define _DEFAULT_SOURCE
#if defined(__APPLE__)
#define __STDC_WANT_LIB_EXT1__ 1
#endif
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
/* Darwin has no explicit_bzero. C11 Annex K memset_s may not be optimized away either. */
static void explicit_bzero(void *data, size_t size)
{
    if (size != 0)
        (void) memset_s(data, size, 0, size);
}
#endif

typedef struct {
    size_t capacity;
    size_t length;
    size_t readers;
    int closed;
    unsigned char bytes[];
} flint_prompt_secret;

static void erase(flint_prompt_secret *secret)
{
    const size_t bytes = sizeof(*secret) + secret->capacity;
    explicit_bzero(secret, bytes);
    free(secret);
}

flint_prompt_secret *flint_prompt_secret_new(size_t capacity)
{
    if (capacity > SIZE_MAX - sizeof(flint_prompt_secret))
        return NULL;
    flint_prompt_secret *secret = calloc(1, sizeof(*secret) + capacity);
    if (secret)
        secret->capacity = capacity;
    return secret;
}

size_t flint_prompt_secret_count(const flint_prompt_secret *secret)
{
    return secret && !secret->closed ? secret->length : 0;
}

int flint_prompt_secret_append(flint_prompt_secret *secret, const void *data, size_t bytes)
{
    if (!secret || secret->closed || secret->readers || bytes > secret->capacity - secret->length)
        return 0;
    if (bytes)
        memcpy(secret->bytes + secret->length, data, bytes);
    secret->length += bytes;
    return 1;
}

void flint_prompt_secret_trim(flint_prompt_secret *secret, size_t length)
{
    if (!secret || secret->closed || secret->readers || length >= secret->length)
        return;
    explicit_bzero(secret->bytes + length, secret->length - length);
    secret->length = length;
}

const unsigned char *flint_prompt_secret_borrow(const flint_prompt_secret *owner, size_t *length)
{
    if (!owner || owner->closed || owner->readers == SIZE_MAX)
        return NULL;
    /* A const handle borrows mutable allocation bookkeeping without changing its payload. */
    flint_prompt_secret *secret = (flint_prompt_secret *)owner;
    ++secret->readers;
    *length = secret->length;
    return secret->bytes;
}

void flint_prompt_secret_release(const flint_prompt_secret *owner)
{
    flint_prompt_secret *secret = (flint_prompt_secret *)owner;
    if (!--secret->readers && secret->closed)
        erase(secret);
}

void flint_prompt_secret_close(flint_prompt_secret *secret)
{
    if (!secret)
        return;
    secret->closed = 1;
    if (!secret->readers)
        erase(secret);
}

void flint_prompt_wipe(void *data, size_t size)
{
    if (size)
        explicit_bzero(data, size);
}
