#ifndef FLINT_WASMTIME_EXTENSIONS_H
#define FLINT_WASMTIME_EXTENSIONS_H

#include <wasi.h>
#include <wasmtime.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FLINT_WASMTIME_EXTENSIONS_ABI 1

bool flint_wasmtime_host_ready(void);
bool flint_wasmtime_poll(wasmtime_call_future_t *future);
wasmtime_error_t *flint_wasmtime_wasip1_async(wasmtime_linker_t *linker);
wasmtime_error_t *flint_wasmtime_wasip3(wasmtime_component_linker_t *linker);
void flint_wasmtime_capabilities(wasi_config_t *config, bool enabled);
/* Takes ownership of the provider error. */
bool flint_wasmtime_error_exhausted(wasmtime_error_t *owned);

#ifdef __cplusplus
}
#endif
#endif
