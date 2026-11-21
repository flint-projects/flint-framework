/* Test the bytes at the freeing boundary, independent of the allocator. */
#include "../native/secret.c"

#undef NDEBUG
#include <assert.h>

static volatile size_t wipe_expected;
static volatile unsigned count_wiped;

void __real_free(void *pointer);
void __wrap_free(void *pointer)
{
    if (wipe_expected) {
        const unsigned char *bytes = pointer;
        for (size_t index = 0; index < wipe_expected; ++index)
            assert(bytes[index] == 0);
        wipe_expected = 0;
        ++count_wiped;
    }
    __real_free(pointer);
}

int main(void)
{
    const size_t sizes[] = {0, 1, 255, 256, 1023, 1024, 1025, 1048575, 1048576, 1048577};
    assert(!flint_prompt_secret_new(SIZE_MAX));
    for (size_t index = 0; index < sizeof(sizes) / sizeof(sizes[0]); ++index) {
        const size_t capacity = sizes[index];
        flint_prompt_secret *secret = flint_prompt_secret_new(capacity);
        assert(secret);
        memset(secret->bytes, 0x91, capacity);
        secret->length = capacity;
        if (capacity) {
            flint_prompt_secret_trim(secret, capacity - 1);
            assert(secret->bytes[capacity - 1] == 0);
        }
        size_t length = 0;
        const void *pointer = flint_prompt_secret_borrow(secret, &length);
        assert(pointer == secret->bytes);
        wipe_expected = sizeof(*secret) + capacity;
        flint_prompt_secret_close(secret);
        assert(wipe_expected != 0);
        assert(!flint_prompt_secret_borrow(secret, &length));
        flint_prompt_secret_release(secret);
        assert(wipe_expected == 0);
    }
    assert(count_wiped == sizeof(sizes) / sizeof(sizes[0]));
    return 0;
}
