# golden-wasm-app

This is a concrete application for the specified Flint API. It is typechecked against the declaration-only contract during handoff preparation. Linking and running require the actual package implementations from the milestone plan; this is not a fake service implementation.

After `tools/bootstrap.py` creates a repo, this template lives at `examples/golden-wasm-app` and dependency paths point at the implementation root. Run `dub build --compiler=dmd` for native examples or the supplied WASM build command for the browser example. Run from this directory so example configuration files resolve predictably.

Application source uses the same public API contracts as the per-package specifications. Changes to the contracts require updating and recompiling this example with DMD and LDC.

## Build and run after Milestone 4

```sh
python3 build.py --ldc ldc2 --profile Oz
python3 -m http.server 8000 --bind 127.0.0.1
```

Open the local server's index page. The D module owns a persistent signal graph and command buffer backed by fixed static arrays. The only raw pointer export is confined to the documented `flint_demo.sys.exports` boundary. JavaScript queues at most 1024 clicks per frame, calls D once per visible animation frame, and applies the validated batch. Hidden pages pause rendering. The input/mutation path carries no arbitrary JavaScript or HTML.

`driver.mjs` validates all headers, lengths, padding, handles, attributes and opcodes before applying a batch. Its DOM baseline supports create/text/attribute/append/remove. Canvas supports a bounded fill rectangle; WebGPU supports a bounded clear pass when a host device is supplied. These are the v1 commands specified in the bridge spec, not a complete WebGPU API.

From the archive root, the independently runnable verification probe is `python3 tools/verify_wasm.py --ldc /path/to/ldc2 --node /path/to/node`. In a bootstrapped repository, use `python3 handoff/tools/verify_wasm.py` with the same compiler options; it links a small real WASM module and executes malformed-frame tests in Node. Passing that probe verifies the ABI decoder and toolchain seam only. It does not replace the still-to-be-implemented signal graph or bridge encoder's own tests.
