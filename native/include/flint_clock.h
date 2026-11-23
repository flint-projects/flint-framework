#ifndef FLINT_CLOCK_H
#define FLINT_CLOCK_H

#include <time.h>

/* The clock D's MonoTime reads, so a deadline passed across the boundary means the same instant on
   both sides. Linux: CLOCK_MONOTONIC. Darwin: mach_absolute_time, which CLOCK_UPTIME_RAW reports;
   Darwin's CLOCK_MONOTONIC also counts time asleep and runs ahead of it (ADR-024). */
#if defined(__APPLE__) && defined(CLOCK_UPTIME_RAW)
#define FLINT_DEADLINE_CLOCK CLOCK_UPTIME_RAW
#elif defined(__APPLE__)
/* <time.h> hides the name under a strict POSIX request; 8 is CLOCK_UPTIME_RAW there. */
#define FLINT_DEADLINE_CLOCK ((clockid_t) 8)
#else
#define FLINT_DEADLINE_CLOCK CLOCK_MONOTONIC
#endif

#endif
