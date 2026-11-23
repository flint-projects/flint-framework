/// Native WebAssembly sandbox policies and capability values.
module flint.engine.wasi.types;

@safe:

/// Native execution backend.
enum Engine : ubyte
{
    wasmtime,
    wamr
}

/// Expected guest import and export model.
enum GuestAbi : ubyte
{
    core,
    wasiPreview1,
    wasi02Component,
    wasi03Component
}

/// An operator-selected directory and its guest-relative mount name.
struct Preopen
{
    /// Host directory, resolved at instantiation without following symbolic links.
    string hostPath;
    /// Guest path used to identify this directory.
    string guestPath;
    /// Permit directory mutation and writes within this capability.
    bool writable;
}

/// One explicit environment entry supplied to a WASI guest.
struct GuestEnvironment
{
    /// ASCII identifier containing letters, digits or underscores.
    string name;
    /// UTF-8 value without embedded NUL bytes.
    string value;
}

/// Per-store and per-operation ceilings for a guest.
struct Limits
{
    /// Fresh instruction budget for instantiation and each invocation.
    ulong fuel = 10_000_000;
    /// Maximum linear memory allocated by the store.
    ulong maxMemoryBytes = 16_777_216;
    /// Maximum elements in the store's table.
    uint maxTableElements = 1024;
    /// Maximum instances in the store.
    uint maxInstances = 1;
    /// Combined stdout and stderr bytes retained per operation.
    uint maxOutputBytes = 1_048_576;
    /// Monotonic wall time for instantiation and each call.
    long wallTimeNanos = 1_000_000_000;
}

/// Execution and explicit capability settings copied during instantiation.
struct PluginOptions
{
    /// Pinned engine selection.
    Engine engine = Engine.wasmtime;
    /// Guest import and export model.
    GuestAbi abi = GuestAbi.core;
    /// Per-store and invocation ceilings.
    Limits limits;
    /// Directories explicitly available to the guest.
    Preopen[] preopens;
    /// A true value requires an explicit environment list.
    bool inheritEnvironment = false;
    /// Grant host network access through WASI socket interfaces.
    bool allowNetwork = false;
    /// Explicit guest environment. The server's ambient environment is never copied.
    GuestEnvironment[] environment;
}
