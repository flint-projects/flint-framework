#ifndef FLINT_PORT_H
#define FLINT_PORT_H

/* The POSIX subset Flint's shims use, on Windows (ADR-026): pthread once, mutexes, condition variables and threads
   on Win32 primitives; clock_gettime and nanosleep; poll on Winsock's WSAPoll; strcasecmp. POSIX builds include the
   system headers directly and see nothing here. */

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <errno.h>
#include <process.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <io.h>

#define strcasecmp _stricmp
#define strncasecmp _strnicmp
#define strdup _strdup
#define access _access
#define R_OK 4

/* sysconf for the one value the shims ask: the online processor count. */
#define _SC_NPROCESSORS_ONLN 84

static inline long sysconf(int name)
{
    if (name != _SC_NPROCESSORS_ONLN)
        return -1;
    return (long) GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
}

/* Clocks. CLOCK_MONOTONIC reads QueryPerformanceCounter, as D's MonoTime does on Windows, so a deadline passed
   across the boundary means the same instant on both sides. */
typedef int clockid_t;
#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1

static inline int clock_gettime(clockid_t clock, struct timespec *now)
{
    if (clock == CLOCK_REALTIME)
        return timespec_get(now, TIME_UTC) == TIME_UTC ? 0 : -1;
    LARGE_INTEGER counter, frequency;
    if (!QueryPerformanceCounter(&counter) || !QueryPerformanceFrequency(&frequency))
        return -1;
    now->tv_sec = (time_t) (counter.QuadPart / frequency.QuadPart);
    now->tv_nsec = (long) ((counter.QuadPart % frequency.QuadPart) * 1000000000LL / frequency.QuadPart);
    return 0;
}

static inline int nanosleep(const struct timespec *duration, struct timespec *remaining)
{
    (void) remaining;
    const long long millis = (long long) duration->tv_sec * 1000 + (duration->tv_nsec + 999999) / 1000000;
    Sleep(millis <= 0 ? 0 : millis > 0x7fffffffLL ? 0x7fffffffUL : (DWORD) millis);
    return 0;
}

/* Winsock's poll; the descriptors are SOCKETs. */
#define poll(descriptors, count, millis) WSAPoll((descriptors), (ULONG) (count), (millis))

/* Once. */
typedef INIT_ONCE pthread_once_t;
#define PTHREAD_ONCE_INIT INIT_ONCE_STATIC_INIT

typedef struct flint_once_call {
    void (*routine)(void);
} flint_once_call;

static BOOL CALLBACK flint_once_trampoline(PINIT_ONCE once, PVOID parameter, PVOID *context)
{
    (void) once;
    (void) context;
    ((flint_once_call *) parameter)->routine();
    return TRUE;
}

static inline int pthread_once(pthread_once_t *once, void (*routine)(void))
{
    flint_once_call call = {routine};
    return InitOnceExecuteOnce(once, flint_once_trampoline, &call, NULL) ? 0 : EINVAL;
}

/* Mutexes: slim reader/writer locks, which need no destruction. */
typedef SRWLOCK pthread_mutex_t;
typedef int pthread_mutexattr_t;
#define PTHREAD_MUTEX_INITIALIZER SRWLOCK_INIT

static inline int pthread_mutex_init(pthread_mutex_t *mutex, const pthread_mutexattr_t *attributes)
{
    (void) attributes;
    InitializeSRWLock(mutex);
    return 0;
}

static inline int pthread_mutex_destroy(pthread_mutex_t *mutex)
{
    (void) mutex;
    return 0;
}

static inline int pthread_mutex_lock(pthread_mutex_t *mutex)
{
    AcquireSRWLockExclusive(mutex);
    return 0;
}

static inline int pthread_mutex_unlock(pthread_mutex_t *mutex)
{
    ReleaseSRWLockExclusive(mutex);
    return 0;
}

/* Condition variables, with the clock a timed wait's absolute deadline is measured on. */
typedef struct pthread_condattr_t {
    clockid_t clock;
} pthread_condattr_t;

typedef struct pthread_cond_t {
    CONDITION_VARIABLE variable;
    clockid_t clock;
} pthread_cond_t;

#define PTHREAD_COND_INITIALIZER {CONDITION_VARIABLE_INIT, CLOCK_REALTIME}

static inline int pthread_condattr_init(pthread_condattr_t *attributes)
{
    attributes->clock = CLOCK_REALTIME;
    return 0;
}

static inline int pthread_condattr_destroy(pthread_condattr_t *attributes)
{
    (void) attributes;
    return 0;
}

static inline int pthread_condattr_setclock(pthread_condattr_t *attributes, clockid_t clock)
{
    attributes->clock = clock;
    return 0;
}

static inline int pthread_cond_init(pthread_cond_t *condition, const pthread_condattr_t *attributes)
{
    InitializeConditionVariable(&condition->variable);
    condition->clock = attributes ? attributes->clock : CLOCK_REALTIME;
    return 0;
}

static inline int pthread_cond_destroy(pthread_cond_t *condition)
{
    (void) condition;
    return 0;
}

static inline int pthread_cond_wait(pthread_cond_t *condition, pthread_mutex_t *mutex)
{
    return SleepConditionVariableSRW(&condition->variable, mutex, INFINITE, 0) ? 0 : EINVAL;
}

static inline int pthread_cond_timedwait(pthread_cond_t *condition, pthread_mutex_t *mutex,
    const struct timespec *deadline)
{
    struct timespec now;
    if (clock_gettime(condition->clock, &now) != 0)
        return EINVAL;
    long long remaining = ((long long) deadline->tv_sec - (long long) now.tv_sec) * 1000
        + ((long long) deadline->tv_nsec - (long long) now.tv_nsec + 999999) / 1000000;
    if (remaining < 0)
        remaining = 0;
    const DWORD millis = remaining >= (long long) INFINITE ? INFINITE - 1 : (DWORD) remaining;
    if (SleepConditionVariableSRW(&condition->variable, mutex, millis, 0))
        return 0;
    return GetLastError() == ERROR_TIMEOUT ? ETIMEDOUT : EINVAL;
}

static inline int pthread_cond_signal(pthread_cond_t *condition)
{
    WakeConditionVariable(&condition->variable);
    return 0;
}

static inline int pthread_cond_broadcast(pthread_cond_t *condition)
{
    WakeAllConditionVariable(&condition->variable);
    return 0;
}

/* Threads. A pthread_t is the thread's handle (null for pthread_self) and its identifier. */
typedef struct pthread_t {
    HANDLE handle;
    DWORD id;
} pthread_t;

typedef struct pthread_attr_t {
    size_t stack;
    int detached;
} pthread_attr_t;

#define PTHREAD_CREATE_JOINABLE 0
#define PTHREAD_CREATE_DETACHED 1

typedef struct flint_thread_start {
    void *(*routine)(void *);
    void *argument;
} flint_thread_start;

static unsigned __stdcall flint_thread_trampoline(void *parameter)
{
    flint_thread_start start = *(flint_thread_start *) parameter;
    free(parameter);
    start.routine(start.argument);
    return 0;
}

static inline int pthread_attr_init(pthread_attr_t *attributes)
{
    attributes->stack = 0;
    attributes->detached = PTHREAD_CREATE_JOINABLE;
    return 0;
}

static inline int pthread_attr_destroy(pthread_attr_t *attributes)
{
    (void) attributes;
    return 0;
}

static inline int pthread_attr_setstacksize(pthread_attr_t *attributes, size_t stack)
{
    attributes->stack = stack;
    return 0;
}

static inline int pthread_attr_setdetachstate(pthread_attr_t *attributes, int state)
{
    attributes->detached = state;
    return 0;
}

static inline int pthread_create(pthread_t *thread, const pthread_attr_t *attributes, void *(*routine)(void *),
    void *argument)
{
    flint_thread_start *start = malloc(sizeof *start);
    if (!start)
        return EAGAIN;
    start->routine = routine;
    start->argument = argument;
    unsigned id = 0;
    const uintptr_t handle = _beginthreadex(NULL, attributes ? (unsigned) attributes->stack : 0,
        flint_thread_trampoline, start, 0, &id);
    if (!handle) {
        free(start);
        return EAGAIN;
    }
    thread->id = id;
    if (attributes && attributes->detached == PTHREAD_CREATE_DETACHED) {
        CloseHandle((HANDLE) handle);
        thread->handle = NULL;
    } else
        thread->handle = (HANDLE) handle;
    return 0;
}

static inline int pthread_join(pthread_t thread, void **result)
{
    if (result)
        *result = NULL;
    if (!thread.handle || WaitForSingleObject(thread.handle, INFINITE) != WAIT_OBJECT_0)
        return EINVAL;
    CloseHandle(thread.handle);
    return 0;
}

static inline pthread_t pthread_self(void)
{
    pthread_t self = {NULL, GetCurrentThreadId()};
    return self;
}

static inline int pthread_equal(pthread_t first, pthread_t second)
{
    return first.id == second.id;
}

#endif

#endif
