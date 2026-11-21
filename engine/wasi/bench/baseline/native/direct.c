/* Direct provider workload for the four fixed Flint fixture modules. */
#define _POSIX_C_SOURCE 200809L
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <wasmtime.h>
#include <flint_wasmtime_extensions.h>

typedef struct reference_code {
    unsigned abi;
    wasm_engine_t *engine;
    wasmtime_module_t *module;
    wasmtime_component_t *component;
} reference_code;

typedef struct reference_guest {
    unsigned abi;
    wasmtime_store_t *store;
    wasmtime_context_t *context;
    wasmtime_func_t core;
    wasmtime_component_func_t component;
} reference_guest;

void reference_wasi_release(reference_code *code)
{
    if (!code)
        return;
    if (code->module)
        wasmtime_module_delete(code->module);
    if (code->component)
        wasmtime_component_delete(code->component);
    wasm_engine_delete(code->engine);
    free(code);
}

reference_code *reference_wasi_compile(const uint8_t *bytes, size_t length, unsigned abi)
{
    if (abi && !flint_wasmtime_host_ready())
        return NULL;
    reference_code *code = calloc(1, sizeof(*code));
    if (!code)
        return NULL;
    code->abi = abi;
    wasm_config_t *config = wasm_config_new();
    wasmtime_config_consume_fuel_set(config, true);
    wasmtime_config_epoch_interruption_set(config, true);
    wasmtime_config_wasm_memory64_set(config, false);
    wasmtime_config_wasm_multi_memory_set(config, false);
    wasmtime_config_memory_reservation_set(config, 16 * 1024 * 1024);
    wasmtime_config_memory_reservation_for_growth_set(config, 16 * 1024 * 1024);
    wasmtime_config_wasm_component_model_set(config, abi >= 2);
    wasmtime_config_wasm_component_model_async_set(config, abi == 3);
    code->engine = wasm_engine_new_with_config(config);
    if (!code->engine) {
        free(code);
        return NULL;
    }
    wasmtime_error_t *error = abi < 2
        ? wasmtime_module_new(code->engine, bytes, length, &code->module)
        : wasmtime_component_new(code->engine, bytes, length, &code->component);
    if (error) {
        wasmtime_error_delete(error);
        reference_wasi_release(code);
        return NULL;
    }
    return code;
}

void reference_wasi_close(reference_guest *guest)
{
    if (guest) {
        wasmtime_store_delete(guest->store);
        free(guest);
    }
}

static void wait_for_provider(wasmtime_call_future_t *future)
{
    while (!flint_wasmtime_poll(future)) {
        const struct timespec pause = {.tv_nsec = 1000000};
        nanosleep(&pause, NULL);
    }
    wasmtime_call_future_delete(future);
}

static ptrdiff_t discard(void *data, const uint8_t *bytes, size_t length)
{
    (void)data;
    (void)bytes;
    return (ptrdiff_t)length;
}

static bool reset_budget(reference_guest *guest)
{
    wasmtime_context_set_epoch_deadline(guest->context, 1);
    wasmtime_error_t *error = wasmtime_context_set_fuel(guest->context, 10000000);
    if (!error)
        return true;
    wasmtime_error_delete(error);
    return false;
}

static bool prepare_core(reference_guest *guest, reference_code *code)
{
    wasmtime_instance_t instance;
    wasm_trap_t *trap = NULL;
    wasmtime_error_t *error = NULL;
    if (code->abi == 0) {
        error = wasmtime_instance_new(guest->context, code->module, NULL, 0, &instance, &trap);
    } else {
        wasmtime_linker_t *linker = wasmtime_linker_new(code->engine);
        error = flint_wasmtime_wasip1_async(linker);
        if (!error)
            wait_for_provider(wasmtime_linker_instantiate_async(linker, guest->context, code->module,
                                                               &instance, &trap, &error));
        wasmtime_linker_delete(linker);
    }
    if (error)
        wasmtime_error_delete(error);
    if (trap)
        wasm_trap_delete(trap);
    if (error || trap)
        return false;
    wasmtime_extern_t result;
    if (!wasmtime_instance_export_get(guest->context, &instance, "answer", 6, &result))
        return false;
    guest->core = result.of.func;
    wasmtime_extern_delete(&result);
    return true;
}

static bool prepare_component(reference_guest *guest, reference_code *code)
{
    wasmtime_component_instance_t instance;
    wasmtime_component_linker_t *linker = wasmtime_component_linker_new(code->engine);
    wasmtime_error_t *error = code->abi == 2 ? wasmtime_component_linker_add_wasip2_async(linker)
                                             : flint_wasmtime_wasip3(linker);
    if (!error)
        wait_for_provider(wasmtime_component_linker_instantiate_async(linker, guest->context, code->component,
                                                                     &instance, &error));
    wasmtime_component_linker_delete(linker);
    if (error) {
        wasmtime_error_delete(error);
        return false;
    }
    wasmtime_component_export_index_t *index =
        wasmtime_component_instance_get_export_index(&instance, guest->context, NULL, "answer", 6);
    if (!index)
        return false;
    const bool found = wasmtime_component_instance_get_func(&instance, guest->context, index, &guest->component);
    wasmtime_component_export_index_delete(index);
    return found;
}

reference_guest *reference_wasi_instantiate(reference_code *code)
{
    reference_guest *guest = calloc(1, sizeof(*guest));
    if (!guest)
        return NULL;
    guest->abi = code->abi;
    guest->store = wasmtime_store_new(code->engine, NULL, NULL);
    guest->context = wasmtime_store_context(guest->store);
    wasmtime_store_limiter(guest->store, 16777216, 1024, 4, 1, 1);
    if (code->abi) {
        wasi_config_t *config = wasi_config_new();
        wasi_config_set_stdout_custom(config, discard, NULL, NULL);
        wasi_config_set_stderr_custom(config, discard, NULL, NULL);
        flint_wasmtime_capabilities(config, false);
        wasmtime_error_t *error = wasmtime_context_set_wasi(guest->context, config);
        if (error) {
            wasmtime_error_delete(error);
            reference_wasi_close(guest);
            return NULL;
        }
    }
    const bool ready = reset_budget(guest)
        && (code->abi < 2 ? prepare_core(guest, code) : prepare_component(guest, code));
    if (!ready) {
        reference_wasi_close(guest);
        return NULL;
    }
    return guest;
}

int reference_wasi_answer(reference_guest *guest)
{
    if (!reset_budget(guest))
        return INT_MIN;
    wasmtime_error_t *error = NULL;
    if (guest->abi >= 2) {
        wasmtime_component_val_t result = {.kind = WASMTIME_COMPONENT_S32, .of.s32 = 0};
        wait_for_provider(wasmtime_component_func_call_async(&guest->component, guest->context, NULL, 0,
                                                            &result, 1, &error));
        if (error) {
            wasmtime_error_delete(error);
            return INT_MIN;
        }
        if (result.kind != WASMTIME_COMPONENT_S32) {
            wasmtime_component_val_delete(&result);
            return INT_MIN;
        }
        return result.of.s32;
    }
    wasmtime_val_t result;
    wasm_trap_t *trap = NULL;
    if (guest->abi) {
        wait_for_provider(wasmtime_func_call_async(guest->context, &guest->core, NULL, 0, &result, 1, &trap, &error));
    } else {
        error = wasmtime_func_call(guest->context, &guest->core, NULL, 0, &result, 1, &trap);
    }
    if (error)
        wasmtime_error_delete(error);
    if (trap)
        wasm_trap_delete(trap);
    return error || trap ? INT_MIN : result.of.i32;
}
