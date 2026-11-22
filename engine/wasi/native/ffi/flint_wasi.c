#define _GNU_SOURCE
#include "flint_wasi.h"
#include "flint_clock.h"

#if (defined(__linux__) || defined(__APPLE__)) && defined(FLINT_HAS_WASMTIME)

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wasmtime.h>

#ifdef FLINT_HAS_WASMTIME_EXTENSIONS
#include <flint_wasmtime_extensions.h>
_Static_assert(FLINT_WASMTIME_EXTENSIONS_ABI == 1, "incompatible Flint Wasmtime extension");
#endif

_Static_assert(sizeof(flint_wasi_limits) == 40 && offsetof(flint_wasi_limits, wall_nanos) == 32,
               "incompatible native guest limits layout");

enum {
    MAX_GUEST_BYTES = 16 * 1024 * 1024,
    MAX_MEMORY_BYTES = 1024 * 1024 * 1024,
    MAX_OUTPUT_BYTES = 16 * 1024 * 1024,
    MAX_PREOPENS = 32,
    MAX_ENV = 64,
    MAX_ENV_BYTES = 64 * 1024,
    MAX_PATH_BYTES = 4096,
    MAX_NAME_BYTES = 1024,
    MAX_ARGUMENTS = 64,
    SLOT_BITS = 7,
    SLOT_COUNT = 1 << SLOT_BITS,
};

struct flint_wasi_compiled {
    wasm_engine_t *engine;
    unsigned abi;
    union {
        wasmtime_module_t *core;
        wasmtime_component_t *component;
    } module;
};

typedef struct captured_output captured_output;

typedef struct plugin {
    wasm_engine_t *engine;
    wasmtime_store_t *store;
    wasmtime_context_t *context;
    flint_wasi_limits limits;
    unsigned abi;
    union {
        wasmtime_instance_t core;
        wasmtime_component_instance_t component;
    } instance;
    captured_output *capture;
    uint8_t *output;
    size_t output_length, output_capacity;
    int output_error;
    int64_t deadline;
    atomic_int stop;
    bool active, closing, abandoned;
} plugin;

struct captured_output {
    plugin *owner;
    atomic_uint references;
};

typedef struct slot {
    plugin *owner;
    uint64_t generation;
} slot;

static pthread_mutex_t scheduler_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t scheduler_wake;
static pthread_once_t scheduler_once = PTHREAD_ONCE_INIT;
static pthread_t scheduler_thread;
static slot slots[SLOT_COUNT];
static bool scheduler_ready, scheduler_stop;
static int64_t next_wake = INT64_MAX;

static int64_t now_ns(void)
{
    struct timespec time;
    if (clock_gettime(FLINT_DEADLINE_CLOCK, &time))
        return 0;
    return (int64_t)time.tv_sec * INT64_C(1000000000) + time.tv_nsec;
}

static void abort_call(plugin *owner, int result)
{
    int pending = FLINT_WASI_OK;
    if (atomic_compare_exchange_strong_explicit(&owner->stop, &pending, result,
                                                memory_order_relaxed, memory_order_relaxed))
        wasmtime_engine_increment_epoch(owner->engine);
}

static void *watch_deadlines(void *unused)
{
    (void)unused;
    pthread_mutex_lock(&scheduler_lock);
    while (!scheduler_stop) {
        const int64_t now = now_ns();
        next_wake = INT64_MAX;
        for (unsigned i = 0; i < SLOT_COUNT; ++i) {
            plugin *owner = slots[i].owner;
            if (!owner || !owner->active || atomic_load_explicit(&owner->stop, memory_order_relaxed))
                continue;
            if (now >= owner->deadline)
                abort_call(owner, FLINT_WASI_TIMEOUT);
            else if (owner->deadline < next_wake)
                next_wake = owner->deadline;
        }
        if (next_wake == INT64_MAX) {
            pthread_cond_wait(&scheduler_wake, &scheduler_lock);
        } else {
#if defined(__APPLE__)
            /* Darwin has no pthread_condattr_setclock: wait for the remaining time instead (ADR-024). */
            const int64_t remaining = next_wake > now ? next_wake - now : 0;
            const struct timespec limit = {
                .tv_sec = remaining / INT64_C(1000000000), .tv_nsec = remaining % INT64_C(1000000000)
            };
            pthread_cond_timedwait_relative_np(&scheduler_wake, &scheduler_lock, &limit);
#else
            const struct timespec until = {
                .tv_sec = next_wake / INT64_C(1000000000), .tv_nsec = next_wake % INT64_C(1000000000)
            };
            pthread_cond_timedwait(&scheduler_wake, &scheduler_lock, &until);
#endif
        }
    }
    pthread_mutex_unlock(&scheduler_lock);
    return NULL;
}

static void stop_watchdog(void)
{
    pthread_mutex_lock(&scheduler_lock);
    scheduler_stop = true;
    pthread_cond_broadcast(&scheduler_wake);
    pthread_mutex_unlock(&scheduler_lock);
    pthread_join(scheduler_thread, NULL);
}

static void start_watchdog(void)
{
    pthread_condattr_t attributes;
    if (pthread_condattr_init(&attributes))
        return;
#if defined(__APPLE__)
    const int result = pthread_cond_init(&scheduler_wake, &attributes);
#else
    const int result = pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC)
        || pthread_cond_init(&scheduler_wake, &attributes);
#endif
    pthread_condattr_destroy(&attributes);
    if (result)
        return;
    if (pthread_create(&scheduler_thread, NULL, watch_deadlines, NULL))
        return;
    if (atexit(stop_watchdog)) {
        stop_watchdog();
        return;
    }
    scheduler_ready = true;
}

static plugin *lookup(uint64_t id)
{
    if (!id)
        return NULL;
    const slot *entry = &slots[id & (SLOT_COUNT - 1)];
    return entry->generation == (id >> SLOT_BITS) ? entry->owner : NULL;
}

static uint64_t register_plugin(plugin *owner)
{
    pthread_mutex_lock(&scheduler_lock);
    uint64_t id = 0;
    for (unsigned i = 0; i < SLOT_COUNT; ++i) {
        slot *entry = &slots[i];
        if (!entry->owner && entry->generation < (UINT64_MAX >> SLOT_BITS)) {
            entry->owner = owner;
            id = (++entry->generation << SLOT_BITS) | i;
            break;
        }
    }
    pthread_mutex_unlock(&scheduler_lock);
    return id;
}

static void begin_call(plugin *owner)
{
    owner->active = true;
    owner->output_length = 0;
    owner->output_error = FLINT_WASI_OK;
    atomic_store_explicit(&owner->stop, FLINT_WASI_OK, memory_order_relaxed);
    const int64_t now = now_ns();
    owner->deadline = now > INT64_MAX - owner->limits.wall_nanos ? INT64_MAX : now + owner->limits.wall_nanos;
    if (owner->deadline < next_wake)
        pthread_cond_broadcast(&scheduler_wake);
}

static int stop_reason(plugin *owner)
{
    const int stopped = atomic_load_explicit(&owner->stop, memory_order_relaxed);
    if (stopped)
        return stopped;
    return now_ns() >= owner->deadline ? FLINT_WASI_TIMEOUT : FLINT_WASI_OK;
}

static int end_call(plugin *owner, int result)
{
    pthread_mutex_lock(&scheduler_lock);
    const int stopped = stop_reason(owner);
    if (stopped)
        result = stopped;
    else if (owner->output_error)
        result = owner->output_error;
    owner->active = false;
    if (owner->closing)
        pthread_cond_broadcast(&scheduler_wake);
    pthread_mutex_unlock(&scheduler_lock);
    return result;
}

static wasmtime_error_t *check_epoch(const wasmtime_context_t *context, void *data, uint64_t *delta,
                                     wasmtime_update_deadline_kind_t *kind)
{
    (void)context;
    plugin *owner = data;
    if (stop_reason(owner))
        return wasmtime_error_new("guest execution interrupted");
    /* Other stores may share this engine. Only an expired or cancelled store stops. */
    *delta = 1;
    *kind = WASMTIME_UPDATE_DEADLINE_CONTINUE;
    return NULL;
}

static bool span_valid(flint_wasi_span span, size_t limit, bool empty)
{
    return span.length <= limit && (!span.length ? empty : span.data && !memchr(span.data, 0, span.length));
}

static bool span_equal(flint_wasi_span left, flint_wasi_span right)
{
    return left.length == right.length && (!left.length || memcmp(left.data, right.data, left.length) == 0);
}

static bool dot_component(const char *name, size_t length)
{
    return (length == 1 && name[0] == '.') || (length == 2 && name[0] == '.' && name[1] == '.');
}

static bool guest_path_valid(flint_wasi_span path)
{
    if (!span_valid(path, MAX_PATH_BYTES, false))
        return false;
    if (path.length == 1 && (path.data[0] == '.' || path.data[0] == '/'))
        return true;
    size_t start = path.data[0] == '/';
    for (size_t i = start; i <= path.length; ++i) {
        if (i < path.length && path.data[i] != '/')
            continue;
        if (i == start || dot_component(path.data + start, i - start))
            return false;
        start = i + 1;
    }
    return true;
}

#if defined(__APPLE__)
/* Darwin has no O_PATH: each component is opened for reading. */
#define FLINT_DIRECTORY_ACCESS O_RDONLY
#else
#define FLINT_DIRECTORY_ACCESS O_PATH
#endif

static int open_host_directory(flint_wasi_span path)
{
    if (!span_valid(path, MAX_PATH_BYTES, false))
        return -1;
    int directory = open(path.data[0] == '/' ? "/" : ".", O_CLOEXEC | FLINT_DIRECTORY_ACCESS | O_DIRECTORY);
    if (directory < 0)
        return -1;
    size_t start = 0;
    for (size_t i = 0; i <= path.length; ++i) {
        if (i < path.length && path.data[i] != '/')
            continue;
        const size_t length = i - start;
        const char *part = path.data + start;
        start = i + 1;
        if (!length || (length == 1 && part[0] == '.'))
            continue;
        if (length > NAME_MAX || dot_component(part, length)) {
            close(directory);
            return -1;
        }
        char name[NAME_MAX + 1];
        memcpy(name, part, length);
        name[length] = 0;
        const int next = openat(directory, name, O_CLOEXEC | O_NOFOLLOW | FLINT_DIRECTORY_ACCESS | O_DIRECTORY);
        close(directory);
        if (next < 0)
            return -1;
        directory = next;
    }
    return directory;
}

#if defined(__APPLE__)
#include <sys/param.h>
#include <sys/stat.h>

static bool same_directory(int first, int second)
{
    struct stat one, two;
    return fstat(first, &one) == 0 && fstat(second, &two) == 0 && one.st_dev == two.st_dev
        && one.st_ino == two.st_ino;
}

/* Wasmtime opens a preopen by path. Linux hands it /proc/self/fd/N, which reopens the directory the
   symlink-free walk verified. Darwin's /dev/fd/N cannot be opened as a directory, so the verified
   directory's own path (F_GETPATH) goes to Wasmtime, and a second symlink-free walk afterwards must
   reach the same directory. A rename racing between the two walks can still go unnoticed; a
   descriptor-based preopen in the Wasmtime C API would close that window (ADR-024). */
static bool apply_preopen(wasi_config_t *config, const flint_wasi_preopen *entry)
{
    const int directory = open_host_directory(entry->host);
    if (directory < 0)
        return false;
    char host[MAXPATHLEN], guest[MAX_PATH_BYTES + 1];
    bool applied = fcntl(directory, F_GETPATH, host) == 0 && strlen(host) <= MAX_PATH_BYTES;
    memcpy(guest, entry->guest.data, entry->guest.length);
    guest[entry->guest.length] = 0;
    if (applied)
        applied = wasi_config_preopen_dir(config, host, guest, entry->writable != 0);
    if (applied) {
        const flint_wasi_span canonical = { host, strlen(host) };
        const int again = open_host_directory(canonical);
        applied = again >= 0 && same_directory(directory, again);
        if (again >= 0)
            close(again);
    }
    close(directory);
    return applied;
}
#else
static bool apply_preopen(wasi_config_t *config, const flint_wasi_preopen *entry)
{
    const int directory = open_host_directory(entry->host);
    if (directory < 0)
        return false;
    char host[64], guest[MAX_PATH_BYTES + 1];
    const int formatted = snprintf(host, sizeof(host), "/proc/self/fd/%d", directory);
    memcpy(guest, entry->guest.data, entry->guest.length);
    guest[entry->guest.length] = 0;
    const bool applied = formatted > 0 && (size_t)formatted < sizeof(host)
        && wasi_config_preopen_dir(config, host, guest, entry->writable != 0);
    close(directory);
    return applied;
}
#endif

static bool env_name_valid(flint_wasi_span name)
{
    if (!span_valid(name, 128, false))
        return false;
    for (size_t i = 0; i < name.length; ++i) {
        const char ch = name.data[i];
        if (!(ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
              || (i && ch >= '0' && ch <= '9')))
            return false;
    }
    return true;
}

static bool capabilities_valid(const flint_wasi_preopen *paths, size_t path_count,
                               const flint_wasi_environment *env, size_t env_count)
{
    if (path_count > MAX_PREOPENS || (path_count && !paths) || env_count > MAX_ENV || (env_count && !env))
        return false;
    for (size_t i = 0; i < path_count; ++i) {
        if (paths[i].writable > 1 || !span_valid(paths[i].host, MAX_PATH_BYTES, false)
            || !guest_path_valid(paths[i].guest))
            return false;
        for (size_t j = 0; j < i; ++j)
            if (span_equal(paths[i].guest, paths[j].guest))
                return false;
    }
    size_t total = 0;
    for (size_t i = 0; i < env_count; ++i) {
        if (!env_name_valid(env[i].name) || !span_valid(env[i].value, MAX_PATH_BYTES, true))
            return false;
        total += env[i].name.length + env[i].value.length;
        if (total > MAX_ENV_BYTES)
            return false;
        for (size_t j = 0; j < i; ++j)
            if (span_equal(env[i].name, env[j].name))
                return false;
    }
    return true;
}

static bool apply_environment(wasi_config_t *config, const flint_wasi_environment *env)
{
    char name[129], value[MAX_PATH_BYTES + 1];
    memcpy(name, env->name.data, env->name.length);
    name[env->name.length] = 0;
    if (env->value.length)
        memcpy(value, env->value.data, env->value.length);
    value[env->value.length] = 0;
    const char *names[] = {name}, *values[] = {value};
    return wasi_config_set_env(config, 1, names, values);
}

static ssize_t append_output(plugin *owner, const uint8_t *bytes, size_t length)
{
    const size_t available = owner->limits.output_bytes - owner->output_length;
    const size_t kept = length <= available ? length : available;
    const size_t required = owner->output_length + kept;
    if (required > owner->output_capacity) {
        size_t capacity = owner->output_capacity ? owner->output_capacity * 2 : 256;
        if (capacity < required)
            capacity = required;
        if (capacity > owner->limits.output_bytes)
            capacity = owner->limits.output_bytes;
        void *grown = realloc(owner->output, capacity);
        if (!grown) {
            owner->output_error = FLINT_WASI_MEMORY;
            return -ENOMEM;
        }
        owner->output = grown;
        owner->output_capacity = capacity;
    }
    if (kept) {
        memcpy(owner->output + owner->output_length, bytes, kept);
        owner->output_length += kept;
    }
    if (kept < length) {
        owner->output_error = FLINT_WASI_EXHAUSTED;
        return -ENOSPC;
    }
    return (ssize_t)length;
}

static ssize_t capture_output(void *data, const uint8_t *bytes, size_t length)
{
    captured_output *capture = data;
    pthread_mutex_lock(&scheduler_lock);
    plugin *owner = capture->owner;
    const ssize_t written = owner && owner->active && !stop_reason(owner)
        ? append_output(owner, bytes, length) : -ECANCELED;
    pthread_mutex_unlock(&scheduler_lock);
    return written;
}

static void release_output(void *data)
{
    captured_output *capture = data;
    if (atomic_fetch_sub_explicit(&capture->references, 1, memory_order_acq_rel) == 1)
        free(capture);
}

static void drop_plugin(plugin *owner)
{
    captured_output *capture = owner->capture;
    if (capture) {
        pthread_mutex_lock(&scheduler_lock);
        capture->owner = NULL;
        pthread_mutex_unlock(&scheduler_lock);
    }
    wasmtime_store_delete(owner->store);
    wasm_engine_delete(owner->engine);
    if (capture)
        release_output(capture);
    free(owner->output);
    free(owner);
}

static int install_context(plugin *owner, const flint_wasi_preopen *paths, size_t path_count,
                           const flint_wasi_environment *env, size_t env_count, unsigned network)
{
    captured_output *capture = malloc(sizeof(*capture));
    if (!capture)
        return FLINT_WASI_MEMORY;
    capture->owner = owner;
    atomic_init(&capture->references, 3);
    owner->capture = capture;
    wasi_config_t *config = wasi_config_new();
    wasi_config_set_stdout_custom(config, capture_output, capture, release_output);
    wasi_config_set_stderr_custom(config, capture_output, capture, release_output);
#ifdef FLINT_HAS_WASMTIME_EXTENSIONS
    flint_wasmtime_capabilities(config, network != 0);
#else
    if (network) {
        wasi_config_inherit_network(config);
        wasi_config_allow_ip_name_lookup(config, true);
    }
#endif
    int status = FLINT_WASI_DENIED;
    for (size_t i = 0; i < path_count; ++i)
        if (!apply_preopen(config, &paths[i]))
            goto release;
    status = FLINT_WASI_ARGUMENT;
    for (size_t i = 0; i < env_count; ++i)
        if (!apply_environment(config, &env[i]))
            goto release;

    /* Wasmtime consumes this config on both success and failure. */
    wasmtime_error_t *error = wasmtime_context_set_wasi(owner->context, config);
    if (!error)
        return FLINT_WASI_OK;
    wasmtime_error_delete(error);
    return FLINT_WASI_IO;

release:
    wasi_config_delete(config);
    return status;
}

static bool check_imports(wasmtime_module_t *module, unsigned abi)
{
    wasm_importtype_vec_t imports;
    wasmtime_module_imports(module, &imports);
    bool accepted = true;
    const char preview[] = "wasi_snapshot_preview1";
    for (size_t i = 0; i < imports.size; ++i) {
        const wasm_name_t *name = wasm_importtype_module(imports.data[i]);
        const wasm_externtype_t *type = wasm_importtype_type(imports.data[i]);
        if (abi != FLINT_WASI_PREVIEW1 || name->size != sizeof(preview) - 1
            || memcmp(name->data, preview, sizeof(preview) - 1) != 0 || wasm_externtype_kind(type) != WASM_EXTERN_FUNC) {
            accepted = false;
            break;
        }
    }
    wasm_importtype_vec_delete(&imports);
    return accepted;
}

static wasm_engine_t *create_engine(unsigned abi)
{
    wasm_config_t *config = wasm_config_new();
    if (!config)
        return NULL;
    wasmtime_config_consume_fuel_set(config, true);
    wasmtime_config_epoch_interruption_set(config, true);
    wasmtime_config_wasm_memory64_set(config, false);
    wasmtime_config_wasm_multi_memory_set(config, false);
    wasmtime_config_memory_reservation_set(config, 16 * 1024 * 1024);
    wasmtime_config_memory_reservation_for_growth_set(config, 16 * 1024 * 1024);
    wasmtime_config_wasm_component_model_set(config, abi >= FLINT_WASI_02);
    wasmtime_config_wasm_component_model_async_set(config, abi == FLINT_WASI_03);
    return wasm_engine_new_with_config(config);
}

static int compile_guest(flint_wasi_compiled *compiled, const uint8_t *bytes, size_t length)
{
    wasmtime_error_t *error;
    if (compiled->abi >= FLINT_WASI_02) {
        error = wasmtime_component_new(compiled->engine, bytes, length, &compiled->module.component);
    } else {
        error = wasmtime_module_new(compiled->engine, bytes, length, &compiled->module.core);
        if (!error && !check_imports(compiled->module.core, compiled->abi))
            return FLINT_WASI_ARGUMENT;
    }
    if (!error)
        return FLINT_WASI_OK;
    wasmtime_error_delete(error);
    return FLINT_WASI_ARGUMENT;
}

int flint_wasi_compile(unsigned abi, const uint8_t *bytes, size_t length, flint_wasi_compiled **out)
{
    if (!out)
        return FLINT_WASI_ARGUMENT;
    *out = NULL;
    if (!bytes || length < 8 || length > MAX_GUEST_BYTES || abi > FLINT_WASI_03)
        return FLINT_WASI_ARGUMENT;
    if (memcmp(bytes, "\0asm", 4) != 0)
        return FLINT_WASI_ARGUMENT;
#ifndef FLINT_HAS_WASMTIME_EXTENSIONS
    if (abi != FLINT_WASI_CORE)
        return FLINT_WASI_UNSUPPORTED;
#else
    if (abi != FLINT_WASI_CORE && !flint_wasmtime_host_ready())
        return FLINT_WASI_UNAVAILABLE;
#endif
    flint_wasi_compiled *compiled = calloc(1, sizeof(*compiled));
    if (!compiled)
        return FLINT_WASI_MEMORY;
    compiled->abi = abi;
    compiled->engine = create_engine(abi);
    if (!compiled->engine) {
        free(compiled);
        return FLINT_WASI_UNAVAILABLE;
    }
    const int status = compile_guest(compiled, bytes, length);
    if (status) {
        flint_wasi_compiled_release(compiled);
        return status;
    }
    *out = compiled;
    return FLINT_WASI_OK;
}

void flint_wasi_compiled_release(flint_wasi_compiled *compiled)
{
    if (!compiled)
        return;
    if (compiled->abi >= FLINT_WASI_02) {
        if (compiled->module.component)
            wasmtime_component_delete(compiled->module.component);
    } else if (compiled->module.core) {
        wasmtime_module_delete(compiled->module.core);
    }
    wasm_engine_delete(compiled->engine);
    free(compiled);
}

static int fail_trap(wasmtime_error_t *error, wasm_trap_t *trap, int other)
{
    bool depleted = false;
    if (error) {
#ifdef FLINT_HAS_WASMTIME_EXTENSIONS
        depleted = flint_wasmtime_error_exhausted(error);
#else
        wasmtime_error_delete(error);
#endif
    }
    if (!trap)
        return depleted ? FLINT_WASI_EXHAUSTED : other;
    wasmtime_trap_code_t code;
    const bool identified = wasmtime_trap_code(trap, &code);
    wasm_trap_delete(trap);
    if (identified && (code == WASMTIME_TRAP_CODE_OUT_OF_FUEL || code == WASMTIME_TRAP_CODE_HOSTCALL_FUEL_EXHAUSTED))
        return FLINT_WASI_EXHAUSTED;
    return FLINT_WASI_IO;
}

static int init_execution(plugin *owner)
{
    wasmtime_context_set_epoch_deadline(owner->context, 1);
    wasmtime_error_t *error = wasmtime_context_set_fuel(owner->context, owner->limits.fuel);
    return error ? fail_trap(error, NULL, FLINT_WASI_UNAVAILABLE) : FLINT_WASI_OK;
}

#ifdef FLINT_HAS_WASMTIME_EXTENSIONS
static int wait_future(plugin *owner, wasmtime_call_future_t *future)
{
    int status = stop_reason(owner);
    while (!status && !flint_wasmtime_poll(future)) {
        const struct timespec pause = {.tv_nsec = 1000000};
        nanosleep(&pause, NULL);
        status = stop_reason(owner);
    }
    wasmtime_call_future_delete(future);
    /* Pending host I/O was cancelled and any started native work owns its own data. */
    if (status)
        owner->abandoned = true;
    return status;
}

static int instantiate_wasi(plugin *owner, const flint_wasi_compiled *compiled)
{
    wasmtime_error_t *error = NULL;
    int status;
    if (owner->abi == FLINT_WASI_PREVIEW1) {
        wasmtime_linker_t *linker = wasmtime_linker_new(owner->engine);
        wasm_trap_t *trap = NULL;
        error = flint_wasmtime_wasip1_async(linker);
        if (error) {
            wasmtime_linker_delete(linker);
            return fail_trap(error, NULL, FLINT_WASI_UNAVAILABLE);
        }
        wasmtime_call_future_t *future = wasmtime_linker_instantiate_async(
            linker, owner->context, compiled->module.core, &owner->instance.core, &trap, &error);
        status = wait_future(owner, future);
        wasmtime_linker_delete(linker);
        return (error || trap) ? fail_trap(error, trap, FLINT_WASI_ARGUMENT) : status;
    }

    wasmtime_component_linker_t *linker = wasmtime_component_linker_new(owner->engine);
    error = owner->abi == FLINT_WASI_02 ? wasmtime_component_linker_add_wasip2_async(linker)
                                       : flint_wasmtime_wasip3(linker);
    if (error) {
        wasmtime_component_linker_delete(linker);
        return fail_trap(error, NULL, FLINT_WASI_UNAVAILABLE);
    }
    wasmtime_call_future_t *future = wasmtime_component_linker_instantiate_async(
        linker, owner->context, compiled->module.component, &owner->instance.component, &error);
    status = wait_future(owner, future);
    wasmtime_component_linker_delete(linker);
    return error ? fail_trap(error, NULL, FLINT_WASI_ARGUMENT) : status;
}
#endif

static int instantiate_guest(plugin *owner, const flint_wasi_compiled *compiled)
{
    const int initialized = init_execution(owner);
    if (initialized)
        return initialized;
    if (owner->abi == FLINT_WASI_CORE) {
        wasm_trap_t *trap = NULL;
        wasmtime_error_t *error = wasmtime_instance_new(owner->context, compiled->module.core, NULL, 0,
                                                       &owner->instance.core, &trap);
        return error || trap ? fail_trap(error, trap, FLINT_WASI_ARGUMENT) : FLINT_WASI_OK;
    }
#ifdef FLINT_HAS_WASMTIME_EXTENSIONS
    return instantiate_wasi(owner, compiled);
#else
    return FLINT_WASI_UNSUPPORTED;
#endif
}

static bool limits_valid(const flint_wasi_limits *limits)
{
    return limits && limits->fuel && limits->wall_nanos > 0 && limits->instances > 0 && limits->instances <= 1024
        && limits->memory_bytes <= MAX_MEMORY_BYTES && limits->output_bytes <= MAX_OUTPUT_BYTES;
}

int flint_wasi_instantiate(const flint_wasi_compiled *compiled, const flint_wasi_limits *limits,
                          const flint_wasi_preopen *paths, size_t path_count,
                          const flint_wasi_environment *env, size_t env_count, unsigned network, uint64_t *out)
{
    if (!out)
        return FLINT_WASI_ARGUMENT;
    *out = 0;
    if (!compiled || !limits_valid(limits) || network > 1
        || !capabilities_valid(paths, path_count, env, env_count))
        return FLINT_WASI_ARGUMENT;
    if (compiled->abi == FLINT_WASI_CORE && (path_count || env_count || network))
        return FLINT_WASI_ARGUMENT;
    if (pthread_once(&scheduler_once, start_watchdog) || !scheduler_ready)
        return FLINT_WASI_UNAVAILABLE;
    plugin *owner = calloc(1, sizeof(*owner));
    if (!owner)
        return FLINT_WASI_MEMORY;
    owner->limits = *limits;
    owner->abi = compiled->abi;
    owner->engine = wasmtime_engine_clone(compiled->engine);
    owner->store = wasmtime_store_new(owner->engine, owner, NULL);
    owner->context = wasmtime_store_context(owner->store);
    atomic_init(&owner->stop, FLINT_WASI_OK);
    wasmtime_store_limiter(owner->store, limits->memory_bytes, limits->table_elements, limits->instances, 1, 1);
    wasmtime_store_epoch_deadline_callback(owner->store, check_epoch, owner, NULL);

    int status = owner->abi == FLINT_WASI_CORE ? FLINT_WASI_OK
        : install_context(owner, paths, path_count, env, env_count, network);
    if (!status) {
        const uint64_t id = register_plugin(owner);
        if (id) {
            pthread_mutex_lock(&scheduler_lock);
            begin_call(owner);
            pthread_mutex_unlock(&scheduler_lock);
            status = end_call(owner, instantiate_guest(owner, compiled));
            if (status) {
                flint_wasi_release(id);
            } else {
                *out = id;
            }
            return status;
        }
        status = FLINT_WASI_EXHAUSTED;
    }
    drop_plugin(owner);
    return status;
}

static bool core_signature(const wasm_functype_t *type, size_t count)
{
    const wasm_valtype_vec_t *params = wasm_functype_params(type);
    const wasm_valtype_vec_t *results = wasm_functype_results(type);
    if (params->size != count || results->size != 1 || wasm_valtype_kind(results->data[0]) != WASM_I32)
        return false;
    for (size_t i = 0; i < count; ++i)
        if (wasm_valtype_kind(params->data[i]) != WASM_I32)
            return false;
    return true;
}

static int call_core(plugin *owner, flint_wasi_span name, const int32_t *args, size_t count, int32_t *out)
{
    wasmtime_extern_t symbol;
    if (!wasmtime_instance_export_get(owner->context, &owner->instance.core, name.data, name.length, &symbol))
        return FLINT_WASI_NOT_FOUND;
    if (symbol.kind != WASMTIME_EXTERN_FUNC) {
        wasmtime_extern_delete(&symbol);
        return FLINT_WASI_ARGUMENT;
    }
    const wasmtime_func_t function = symbol.of.func;
    wasmtime_extern_delete(&symbol);
    wasm_functype_t *type = wasmtime_func_type(owner->context, &function);
    const bool valid = core_signature(type, count);
    wasm_functype_delete(type);
    if (!valid)
        return FLINT_WASI_ARGUMENT;

    wasmtime_val_t values[MAX_ARGUMENTS];
    for (size_t i = 0; i < count; ++i) {
        values[i].kind = WASMTIME_I32;
        values[i].of.i32 = args[i];
    }
    wasmtime_val_t result;
    wasm_trap_t *trap = NULL;
    wasmtime_error_t *error = NULL;
#ifdef FLINT_HAS_WASMTIME_EXTENSIONS
    if (owner->abi == FLINT_WASI_PREVIEW1) {
        wasmtime_call_future_t *future = wasmtime_func_call_async(owner->context, &function, values, count,
                                                                 &result, 1, &trap, &error);
        const int status = wait_future(owner, future);
        if (status)
            return fail_trap(error, trap, status);
    } else
#endif
    {
        error = wasmtime_func_call(owner->context, &function, values, count, &result, 1, &trap);
    }
    if (error || trap)
        return fail_trap(error, trap, FLINT_WASI_IO);
    *out = result.of.i32;
    return FLINT_WASI_OK;
}

#ifdef FLINT_HAS_WASMTIME_EXTENSIONS
static bool component_signature(const wasmtime_component_func_type_t *type, size_t count)
{
    if (wasmtime_component_func_type_param_count(type) != count)
        return false;
    wasmtime_component_valtype_t result;
    if (!wasmtime_component_func_type_result(type, &result))
        return false;
    const bool result_i32 = result.kind == WASMTIME_COMPONENT_VALTYPE_S32;
    wasmtime_component_valtype_delete(&result);
    if (!result_i32)
        return false;
    for (size_t i = 0; i < count; ++i) {
        wasmtime_component_valtype_t parameter;
        const char *name;
        size_t length;
        if (!wasmtime_component_func_type_param_nth(type, i, &name, &length, &parameter))
            return false;
        const bool i32 = parameter.kind == WASMTIME_COMPONENT_VALTYPE_S32;
        wasmtime_component_valtype_delete(&parameter);
        if (!i32)
            return false;
    }
    return true;
}

static int call_component(plugin *owner, flint_wasi_span name, const int32_t *args, size_t count, int32_t *out)
{
    wasmtime_component_export_index_t *index = wasmtime_component_instance_get_export_index(
        &owner->instance.component, owner->context, NULL, name.data, name.length);
    if (!index)
        return FLINT_WASI_NOT_FOUND;
    wasmtime_component_func_t function;
    const bool found = wasmtime_component_instance_get_func(&owner->instance.component, owner->context, index, &function);
    wasmtime_component_export_index_delete(index);
    if (!found)
        return FLINT_WASI_ARGUMENT;
    wasmtime_component_func_type_t *type = wasmtime_component_func_type(&function, owner->context);
    const bool checked = component_signature(type, count);
    wasmtime_component_func_type_delete(type);
    if (!checked)
        return FLINT_WASI_ARGUMENT;

    wasmtime_component_val_t values[MAX_ARGUMENTS];
    for (size_t i = 0; i < count; ++i) {
        values[i].kind = WASMTIME_COMPONENT_S32;
        values[i].of.s32 = args[i];
    }
    /* The pinned C API replaces an initialized Rust-owned value. */
    wasmtime_component_val_t result = {.kind = WASMTIME_COMPONENT_S32, .of.s32 = 0};
    wasmtime_error_t *error = NULL;
    wasmtime_call_future_t *future = wasmtime_component_func_call_async(
        &function, owner->context, values, count, &result, 1, &error);
    const int status = wait_future(owner, future);
    if (error)
        return fail_trap(error, NULL, FLINT_WASI_IO);
    if (status)
        return status;
    if (result.kind != WASMTIME_COMPONENT_S32) {
        wasmtime_component_val_delete(&result);
        return FLINT_WASI_IO;
    }
    *out = result.of.s32;
    return FLINT_WASI_OK;
}
#endif

int flint_wasi_call_i32(uint64_t id, flint_wasi_span name, const int32_t *args, size_t count, int32_t *out)
{
    if (!out)
        return FLINT_WASI_ARGUMENT;
    *out = 0;
    if (!span_valid(name, MAX_NAME_BYTES, false) || count > MAX_ARGUMENTS || (count && !args))
        return FLINT_WASI_ARGUMENT;

    pthread_mutex_lock(&scheduler_lock);
    plugin *owner = lookup(id);
    if (!owner || owner->closing || owner->active || owner->abandoned) {
        const int status = !owner ? FLINT_WASI_NOT_FOUND : FLINT_WASI_CONFLICT;
        pthread_mutex_unlock(&scheduler_lock);
        return status;
    }
    begin_call(owner);
    pthread_mutex_unlock(&scheduler_lock);

    int32_t value = 0;
    int status = init_execution(owner);
    if (!status) {
#ifdef FLINT_HAS_WASMTIME_EXTENSIONS
        if (owner->abi >= FLINT_WASI_02)
            status = call_component(owner, name, args, count, &value);
        else
#endif
            status = call_core(owner, name, args, count, &value);
    }
    status = end_call(owner, status);
    if (!status)
        *out = value;
    return status;
}

int flint_wasi_interrupt(uint64_t id)
{
    pthread_mutex_lock(&scheduler_lock);
    plugin *owner = lookup(id);
    int status = FLINT_WASI_NOT_FOUND;
    if (owner) {
        status = FLINT_WASI_OK;
        if (owner->active)
            abort_call(owner, FLINT_WASI_CANCELLED);
    }
    pthread_mutex_unlock(&scheduler_lock);
    return status;
}

int flint_wasi_copy_output(uint64_t id, uint8_t **out, size_t *length)
{
    if (!out || !length)
        return FLINT_WASI_ARGUMENT;
    *out = NULL;
    *length = 0;

    pthread_mutex_lock(&scheduler_lock);
    plugin *owner = lookup(id);
    int status = FLINT_WASI_NOT_FOUND;
    if (owner) {
        status = owner->active || owner->closing ? FLINT_WASI_CONFLICT : FLINT_WASI_OK;
        if (!status && owner->output_length) {
            *out = malloc(owner->output_length);
            if (*out) {
                memcpy(*out, owner->output, owner->output_length);
                *length = owner->output_length;
            } else {
                status = FLINT_WASI_MEMORY;
            }
        }
    }
    pthread_mutex_unlock(&scheduler_lock);
    return status;
}

void flint_wasi_output_free(uint8_t *output)
{
    free(output);
}

int flint_wasi_release(uint64_t id)
{
    pthread_mutex_lock(&scheduler_lock);
    plugin *owner = lookup(id);
    if (!owner || owner->closing) {
        const int status = !owner ? FLINT_WASI_NOT_FOUND : FLINT_WASI_CONFLICT;
        pthread_mutex_unlock(&scheduler_lock);
        return status;
    }
    owner->closing = true;
    if (owner->active)
        abort_call(owner, FLINT_WASI_CANCELLED);
    while (owner->active)
        pthread_cond_wait(&scheduler_wake, &scheduler_lock);
    slots[id & (SLOT_COUNT - 1)].owner = NULL;
    pthread_mutex_unlock(&scheduler_lock);
    drop_plugin(owner);
    return FLINT_WASI_OK;
}

#endif
