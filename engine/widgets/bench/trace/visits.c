#include <stdint.h>
#include <stdio.h>

static uint64_t visited;
uint32_t __real_flint_scalar_properties(uint32_t scalar);

uint32_t __wrap_flint_scalar_properties(uint32_t scalar)
{
    ++visited;
    return __real_flint_scalar_properties(scalar);
}

__attribute__((destructor)) static void report(void)
{
    fprintf(stderr, "style_scalar_visits=%llu\n", (unsigned long long)visited);
}
