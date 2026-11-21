// Included as a child module of the pinned Wasmtime C-API's wasi module.
use crate::{
    handle_result, wasmtime_call_future_poll, wasmtime_call_future_t,
    wasmtime_component_linker_t, wasmtime_error_t, wasmtime_linker_t,
};
use std::num::NonZeroUsize;
use std::sync::OnceLock;
use tokio::runtime::{Builder, Runtime};

static HOST: OnceLock<Option<Runtime>> = OnceLock::new();

fn host_runtime() -> Option<&'static Runtime> {
    HOST.get_or_init(|| {
        Builder::new_multi_thread()
            .worker_threads(2)
            .max_blocking_threads(8)
            .enable_all()
            .build()
            .ok()
    })
    .as_ref()
}

#[unsafe(no_mangle)]
pub extern "C" fn flint_wasmtime_host_ready() -> bool {
    host_runtime().is_some()
}

#[unsafe(no_mangle)]
pub extern "C" fn flint_wasmtime_poll(future: &mut wasmtime_call_future_t<'_>) -> bool {
    // The embedding checks flint_wasmtime_host_ready at startup before using this API.
    if let Some(runtime) = host_runtime() {
        let _guard = runtime.enter();
        wasmtime_call_future_poll(future)
    } else {
        false
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn flint_wasmtime_wasip1_async(
    linker: &mut wasmtime_linker_t,
) -> Option<Box<wasmtime_error_t>> {
    handle_result(
        wasmtime_wasi::p1::add_to_linker_async(&mut linker.linker, |data| {
            data.wasi.as_mut().expect("Flint installs WASI before linking")
        }),
        |_| (),
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn flint_wasmtime_wasip3(
    linker: &mut wasmtime_component_linker_t,
) -> Option<Box<wasmtime_error_t>> {
    handle_result(wasmtime_wasi::p3::add_to_linker(&mut linker.linker), |_| ())
}

#[unsafe(no_mangle)]
pub extern "C" fn flint_wasmtime_capabilities(config: &mut super::wasi_config_t, enabled: bool) {
    config.builder.allow_blocking_current_thread(false);
    config.builder.max_io_size(NonZeroUsize::new(1_048_576).unwrap());
    config.builder.max_random_size(1_048_576);
    config.builder.allow_tcp(enabled);
    config.builder.allow_udp(enabled);
    config.builder.allow_ip_name_lookup(enabled);
    if enabled {
        config.builder.inherit_network();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn flint_wasmtime_error_exhausted(owned: Box<wasmtime_error_t>) -> bool {
    let error: wasmtime::Error = (*owned).into();
    matches!(
        error.downcast_ref::<wasmtime::Trap>(),
        Some(wasmtime::Trap::OutOfFuel | wasmtime::Trap::HostcallFuelExhausted | wasmtime::Trap::AllocationTooLarge)
    )
}
