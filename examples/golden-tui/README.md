# golden-tui

This is a concrete application for the specified Flint API. It is typechecked against the declaration-only contract during handoff preparation. Linking and running require the actual package implementations from the milestone plan; this is not a fake service implementation.

After `tools/bootstrap.py` creates a repo, this template lives at `examples/golden-tui` and dependency paths point at the implementation root. Run `dub build --compiler=dmd` for native examples or the supplied WASM build command for the browser example. Run from this directory so example configuration files resolve predictably.

Application source uses the same public API contracts as the per-package specifications. Changes to the contracts require updating and recompiling this example with DMD and LDC.
