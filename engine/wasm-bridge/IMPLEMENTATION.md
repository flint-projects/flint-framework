# flint:engine-wasm-bridge

Construct a command buffer with exclusive caller-owned storage and the host's
nonzero session epoch. The guest encodes little-endian FLNT v1 records and
uses `clear` once at the start of each frame. `visit` borrows precisely the
initialized bytes. Bounds errors leave the existing frame unchanged.

The browser driver validates each complete frame against an independent
shadow registry before changing the DOM. It checks sequence arithmetic,
generations, subtree depth, UTF-8, attribute names, padding and drawing bounds.
Text uses the text content API. A new host epoch requires an explicit reset
and a newly initialized guest command buffer.

The retained fixture compares identical native and wasm32 bytes, exercises
memory growth, and measures 1, 100 and 4,096 commands. The Chromium fixture
verifies literal markup, a real Canvas pixel at the surface boundary, rejection
before mutation, and the compiled golden counter. It uses an isolated browser
profile and a loopback-only server.
