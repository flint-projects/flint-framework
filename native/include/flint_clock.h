#ifndef FLINT_CLOCK_H
#define FLINT_CLOCK_H

#include <time.h>

/* The clock D's MonoTime reads, so a deadline passed across the boundary means the same instant on
   both sides. Linux: CLOCK_MONOTONIC. Darwin: mach_absolute_time, which CLOCK_UPTIME_RAW reports;
   Darwin's CLOCK_MONOTONIC also counts time asleep and runs ahead of it (ADR-024). */
#if defined(__APPLE__)
#define FLINT_DEADLINE_CLOCK CLOCK_UPTIME_RAW
#else
#define FLINT_DEADLINE_CLOCK CLOCK_MONOTONIC
#endif

#endif
